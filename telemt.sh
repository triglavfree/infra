#!/bin/bash
#===============================================================================
# Прямая установка Telemt MTProto Proxy на Ubuntu Server
# Без Docker/Podman, напрямую через systemd
#===============================================================================
set -euo pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Переменные
TELEMT_PORT="${1:-8443}"
TELEMT_SECRET=""
TELEMT_DOMAIN=""
TLS_MASK="www.microsoft.com"
CONFIG_DIR="/etc/telemt"

# Функции вывода
log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }

# Проверка прав root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Запустите скрипт от root (sudo)"
        exit 1
    fi
    log_ok "Права root получены"
}

# Получение внешнего IP
get_ip() {
    local ip
    ip=$(curl -s --max-time 5 -4 ifconfig.me 2>/dev/null || echo "")
    if [[ -z "$ip" ]]; then
        ip=$(curl -s --max-time 5 -4 icanhazip.com 2>/dev/null || echo "127.0.0.1")
    fi
    echo "$ip"
}

# Генерация секрета
gen_secret() {
    openssl rand -hex 16
}

# Проверка порта
check_port() {
    if ss -tlnp | grep -q ":${TELEMT_PORT} "; then
        log_error "Порт ${TELEMT_PORT} уже занят!"
        log_info "Процессы, использующие порт ${TELEMT_PORT}:"
        ss -tlnp | grep ":${TELEMT_PORT}" || true
        return 1
    fi
    log_ok "Порт ${TELEMT_PORT} свободен"
    return 0
}

# Установка зависимостей
install_deps() {
    log_info "Установка необходимых пакетов..."
    apt-get update -qq
    apt-get install -y -qq curl wget openssl ca-certificates xxd netcat-openbsd
    log_ok "Зависимости установлены"
}

# Скачивание и установка Telemt
download_telemt() {
    log_info "Скачивание последней версии Telemt..."
    
    # Определяем архитектуру
    local arch
    arch=$(uname -m)
    case $arch in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *) log_error "Неподдерживаемая архитектура: $arch"; exit 1 ;;
    esac
    
    # Определяем тип libc
    local libc="gnu"
    if ldd --version 2>&1 | grep -iq musl; then
        libc="musl"
    fi
    
    # Формируем URL и скачиваем
    local url="https://github.com/telemt/telemt/releases/latest/download/telemt-${arch}-linux-${libc}.tar.gz"
    log_info "Загрузка: $url"
    
    if ! wget -qO- "$url" | tar -xz; then
        log_error "Не удалось скачать Telemt"
        exit 1
    fi
    
    # Перемещаем бинарник
    mv telemt /usr/local/bin/
    chmod +x /usr/local/bin/telemt
    
    log_ok "Telemt установлен в /usr/local/bin/telemt"
}

# Создание конфигурации
create_config() {
    log_info "Создание конфигурации для порта ${TELEMT_PORT}..."
    
    mkdir -p "${CONFIG_DIR}"
    
    cat > "${CONFIG_DIR}/telemt.toml" << EOF
# Telemt MTProto Proxy Configuration
# Автоматически сгенерировано установщиком

[general]
log_level = "normal"

[general.modes]
classic = false
secure = false
tls = true

[[server.listeners]]
ip = "0.0.0.0"
port = ${TELEMT_PORT}
announce_ip = "${TELEMT_DOMAIN}"

[censorship]
tls_domain = "${TLS_MASK}"
mask = true

[access.users]
"user" = "${TELEMT_SECRET}"
EOF

    # Создаем директорию для кэша
    mkdir -p "${CONFIG_DIR}/cache"
    chmod 755 "${CONFIG_DIR}" "${CONFIG_DIR}/cache"
    
    log_ok "Конфигурация создана в ${CONFIG_DIR}/telemt.toml"
}

# Создание systemd сервиса
create_service() {
    log_info "Создание systemd сервиса..."
    
    cat > /etc/systemd/system/telemt.service << EOF
[Unit]
Description=Telemt MTProto Proxy
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/telemt /etc/telemt/telemt.toml
WorkingDirectory=/tmp
Restart=on-failure
RestartSec=10
User=nobody
Group=nogroup
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=/etc/telemt/cache
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
MemoryDenyWriteExecute=yes
LimitNOFILE=65536
LimitNPROC=64

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    log_ok "Systemd сервис создан"
}

# Запуск сервиса
start_service() {
    log_info "Запуск Telemt сервиса..."
    
    systemctl start telemt
    sleep 3
    
    if systemctl is-active --quiet telemt; then
        log_ok "Сервис запущен"
    else
        log_error "Сервис не запустился!"
        journalctl -u telemt -n 20 --no-pager
        exit 1
    fi
    
    systemctl enable telemt &>/dev/null || true
}

# Проверка работы
verify_installation() {
    log_info "Проверка установки..."
    
    # Проверка процесса
    if ! pgrep -f telemt >/dev/null; then
        log_error "Процесс Telemt не найден"
        return 1
    fi
    log_ok "Процесс Telemt запущен"
    
    # Проверка порта
    if ! ss -tlnp | grep -q ":${TELEMT_PORT} "; then
        log_error "Порт ${TELEMT_PORT} не слушается!"
        return 1
    fi
    log_ok "Порт ${TELEMT_PORT} слушается"
    
    # Проверка на каком IP слушает
    local listening_ip
    listening_ip=$(ss -tlnp | grep ":${TELEMT_PORT}" | awk '{print $4}' | cut -d: -f1)
    if [[ "$listening_ip" == "0.0.0.0" ]]; then
        log_ok "Слушает на всех интерфейсах (0.0.0.0:${TELEMT_PORT})"
    else
        log_warn "Слушает только на ${listening_ip}:${TELEMT_PORT}"
    fi
    
    return 0
}

# Настройка firewall
setup_firewall() {
    if command -v ufw &>/dev/null; then
        log_info "Настройка UFW..."
        ufw allow "${TELEMT_PORT}/tcp" comment "Telemt" 2>/dev/null || true
        log_ok "Порт ${TELEMT_PORT} открыт в UFW"
    fi
}

# Создание ссылок для Telegram
create_links() {
    local tls_hex
    tls_hex=$(echo -n "${TLS_MASK}" | xxd -p)
    local tls_secret="ee${TELEMT_SECRET}${tls_hex}"
    
    local tg_link="tg://proxy?server=${TELEMT_DOMAIN}&port=${TELEMT_PORT}&secret=${tls_secret}"
    local web_link="https://t.me/proxy?server=${TELEMT_DOMAIN}&port=${TELEMT_PORT}&secret=${tls_secret}"
    
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}║           TELEMT УСТАНОВЛЕН УСПЕШНО!                      ║${NC}"
    echo -e "${GREEN}╠═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}Сервер:${NC}     ${YELLOW}${TELEMT_DOMAIN}${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}Порт:${NC}       ${YELLOW}${TELEMT_PORT}${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}Секрет:${NC}    ${YELLOW}${TELEMT_SECRET}${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}TLS маска:${NC} ${YELLOW}${TLS_MASK}${NC}"
    echo -e "${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}                 ${CYAN}ССЫЛКИ ДЛЯ ПОДКЛЮЧЕНИЯ${NC}"
    echo -e "${GREEN}║${NC}"
    echo -e "  ${web_link}"
    echo ""
    echo -e "  ${tg_link}"
    echo ""
    echo -e "${GREEN}║${NC}  ${YELLOW}Полезные команды:${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}systemctl status telemt${NC}      - статус"
    echo -e "${GREEN}║${NC}  ${CYAN}journalctl -u telemt -f${NC}      - логи"
    echo -e "${GREEN}║${NC}  ${CYAN}systemctl stop telemt${NC}        - остановка"
    echo -e "${GREEN}║${NC}  ${CYAN}systemctl start telemt${NC}       - запуск"
    echo -e "${GREEN}║${NC}  ${CYAN}systemctl restart telemt${NC}     - перезапуск"
    echo -e "${GREEN}║${NC}  ${CYAN}cat /etc/telemt/telemt.toml${NC}  - конфиг"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Сохраняем ссылки в файл
    echo "${web_link}" > "${CONFIG_DIR}/connection-link.txt"
    echo "${tg_link}" >> "${CONFIG_DIR}/connection-link.txt"
    echo "" >> "${CONFIG_DIR}/connection-link.txt"
    echo "Сервер: ${TELEMT_DOMAIN}" >> "${CONFIG_DIR}/connection-link.txt"
    echo "Порт: ${TELEMT_PORT}" >> "${CONFIG_DIR}/connection-link.txt"
    echo "Секрет: ${TELEMT_SECRET}" >> "${CONFIG_DIR}/connection-link.txt"
    
    log_ok "Ссылки сохранены в ${CONFIG_DIR}/connection-link.txt"
}

# Диагностика сети
network_diagnostic() {
    echo ""
    echo -e "${YELLOW}══════════════════ ДИАГНОСТИКА СЕТИ ══════════════════${NC}"
    
    # Проверка локального подключения
    echo -e "${CYAN}Локальная проверка:${NC}"
    if nc -z localhost "${TELEMT_PORT}" 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} localhost:${TELEMT_PORT} доступен"
    else
        echo -e "  ${RED}✗${NC} localhost:${TELEMT_PORT} НЕ доступен"
    fi
    
    # Проверка через публичный IP
    echo -e "${CYAN}Проверка через публичный IP:${NC}"
    if nc -z "${TELEMT_DOMAIN}" "${TELEMT_PORT}" 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} ${TELEMT_DOMAIN}:${TELEMT_PORT} доступен"
    else
        echo -e "  ${RED}✗${NC} ${TELEMT_DOMAIN}:${TELEMT_PORT} НЕ доступен"
    fi
    
    # Проверка iptables правил
    echo -e "${CYAN}Правила iptables для порта ${TELEMT_PORT}:${NC}"
    iptables -L INPUT -n -v | grep -E "dpt:${TELEMT_PORT}|policy" | sed 's/^/  /'
    
    # Проверка UFW
    if command -v ufw &>/dev/null; then
        echo -e "${CYAN}Статус UFW:${NC}"
        ufw status | grep -E "${TELEMT_PORT}|Status" | sed 's/^/  /'
    fi
    
    echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${BLUE}👉 Для проверки доступности порта из интернета используйте:${NC}"
    echo "   https://portchecker.co/"
    echo "   https://2ip.ru/check-port/"
    echo "   https://check-host.net/"
    echo ""
}

# Интерактивный режим
interactive_mode() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║        ИНТЕРАКТИВНАЯ УСТАНОВКА TELEMT               ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    local default_ip
    default_ip=$(get_ip)
    echo -e "Определен внешний IP: ${YELLOW}${default_ip}${NC}"
    echo ""
    
    read -rp "Введите порт [${TELEMT_PORT}]: " port_input
    TELEMT_PORT="${port_input:-${TELEMT_PORT}}"
    
    while ! check_port; do
        read -rp "Введите другой порт: " TELEMT_PORT
    done
    
    read -rp "Домен или IP для ссылок [${default_ip}]: " domain_input
    TELEMT_DOMAIN="${domain_input:-${default_ip}}"
    
    local default_secret
    default_secret=$(gen_secret)
    read -rp "Секретный ключ [${default_secret}]: " secret_input
    TELEMT_SECRET="${secret_input:-${default_secret}}"
    
    read -rp "Домен для TLS маскировки [${TLS_MASK}]: " mask_input
    TLS_MASK="${mask_input:-${TLS_MASK}}"
}

# Основная функция
main() {
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}║    Прямая установка Telemt MTProto Proxy     ║${NC}"
    echo -e "${GREEN}║           Ubuntu Server 24.04               ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════${NC}"
    echo ""
    
    check_root
    
    # Интерактивный режим, если запущено без аргументов и есть терминал
    if [[ -t 0 && $# -eq 0 ]]; then
        interactive_mode
    else
        TELEMT_PORT="${1:-8443}"
        TELEMT_DOMAIN=$(get_ip)
        TELEMT_SECRET=$(gen_secret)
        log_info "Неинтерактивный режим"
        log_info "Порт: ${TELEMT_PORT}"
        log_info "IP: ${TELEMT_DOMAIN}"
    fi
    
    # Проверка порта
    check_port || exit 1
    
    # Установка
    install_deps
    download_telemt
    create_config
    create_service
    setup_firewall
    start_service
    
    # Проверка
    if verify_installation; then
        create_links
        network_diagnostic
        log_ok "Установка успешно завершена!"
        log_info "Проверьте доступность порта через онлайн-сервисы."
    else
        log_error "Установка не удалась!"
        exit 1
    fi
}

# Запуск
main "$@"
