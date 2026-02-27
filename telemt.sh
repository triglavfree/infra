#!/bin/bash
#===============================================================================
# Telemt MTProto Proxy - БЕЗОПАСНАЯ УСТАНОВКА
# Версия: 3.0.15 (стабильная LTS)
# ССЫЛКИ НЕ СОХРАНЯЮТСЯ - ПОКАЗЫВАЮТСЯ ОДИН РАЗ
#===============================================================================
set -euo pipefail

#═══════════════════════════════════════════════════════════════════════════════
# ЦВЕТА И СТИЛИ
#═══════════════════════════════════════════════════════════════════════════════
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
WHITE='\033[1;37m'; NC='\033[0m'

# Символы для рамок
TOP_LEFT='╔'; TOP_RIGHT='╗'; BOTTOM_LEFT='╚'; BOTTOM_RIGHT='╝'
HORIZONTAL='═'; VERTICAL='║'; CROSS_LEFT='╠'; CROSS_RIGHT='╣'

#═══════════════════════════════════════════════════════════════════════════════
# ПЕРЕМЕННЫЕ
#═══════════════════════════════════════════════════════════════════════════════
TELEMT_PORT="${1:-8443}"
TELEMT_SECRET=""
TELEMT_DOMAIN=""
TLS_MASK="www.microsoft.com"
CONFIG_DIR="/etc/telemt"

#═══════════════════════════════════════════════════════════════════════════════
# ФУНКЦИИ ВЫВОДА
#═══════════════════════════════════════════════════════════════════════════════
print_header() {
    local title="$1"
    local width=70
    local title_len=${#title}
    local padding=$(( (width - title_len - 2) / 2 ))
    
    echo ""
    echo -e "${GREEN}${TOP_LEFT}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${TOP_RIGHT}${NC}"
    printf "${GREEN}${VERTICAL}${NC}%*s${GREEN}${VERTICAL}${NC}\n" $((width - 2)) ""
    printf "${GREEN}${VERTICAL}${NC}%*s%-*s%*s${GREEN}${VERTICAL}${NC}\n" $((padding)) "" $title_len "$title" $((width - 2 - title_len - padding)) ""
    printf "${GREEN}${VERTICAL}${NC}%*s${GREEN}${VERTICAL}${NC}\n" $((width - 2)) ""
    echo -e "${GREEN}${BOTTOM_LEFT}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${BOTTOM_RIGHT}${NC}"
    echo ""
}

print_section() {
    local title="$1"
    echo -e "${CYAN}${CROSS_LEFT}${HORIZONTAL}${HORIZONTAL} ${title} ${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${CROSS_RIGHT}${NC}"
}

print_info() { printf "${BLUE}  ▶${NC} %s\n" "$1"; }
print_ok() { printf "${GREEN}  ✓${NC} %s\n" "$1"; }
print_error() { printf "${RED}  ✗${NC} %s\n" "$1"; }
print_warn() { printf "${YELLOW}  ⚠${NC} %s\n" "$1"; }

print_value() {
    local label="$1"
    local value="$2"
    printf "  ${CYAN}%-15s${NC} ${YELLOW}%s${NC}\n" "$label:" "$value"
}

print_link() {
    local type="$1"
    local url="$2"
    printf "  ${MAGENTA}%-6s${NC} ${WHITE}%s${NC}\n" "$type:" "$url"
}

print_command() {
    printf "  ${GREEN}❯${NC} ${YELLOW}%s${NC}\n" "$1"
}

print_line() {
    echo -e "  ${BLUE}──────────────────────────────────────────────────────${NC}"
}

print_warning_box() {
    echo ""
    echo -e "${YELLOW}${TOP_LEFT}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${TOP_RIGHT}${NC}"
    echo -e "${YELLOW}${VERTICAL}${NC}  ⚠  ВНИМАНИЕ: ССЫЛКА БУДЕТ ПОКАЗАНА ТОЛЬКО ОДИН РАЗ  ${YELLOW}${VERTICAL}${NC}"
    echo -e "${YELLOW}${VERTICAL}${NC}  ⚠  СОХРАНИТЕ ЕЁ СЕЙЧАС! ФАЙЛЫ НЕ СОХРАНЯЮТСЯ     ${YELLOW}${VERTICAL}${NC}"
    echo -e "${YELLOW}${BOTTOM_LEFT}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${BOTTOM_RIGHT}${NC}"
    echo ""
}

#═══════════════════════════════════════════════════════════════════════════════
# ОСНОВНЫЕ ФУНКЦИИ
#═══════════════════════════════════════════════════════════════════════════════
check_root() {
    [[ $EUID -eq 0 ]] || { print_error "Запустите от root (sudo)"; exit 1; }
    print_ok "Права root получены"
}

get_ip() {
    curl -s --max-time 5 -4 ifconfig.me || echo "UNKNOWN"
}

gen_secret() {
    openssl rand -hex 16
}

check_port() {
    if ss -tlnp | grep -q ":${TELEMT_PORT} "; then
        print_error "Порт ${TELEMT_PORT} уже занят!"
        ss -tlnp | grep ":${TELEMT_PORT}" | head -3
        exit 1
    fi
    print_ok "Порт ${TELEMT_PORT} свободен"
}

cleanup() {
    # Безопасное удаление всех следов
    rm -f /tmp/telemt* 2>/dev/null || true
    rm -f /etc/telemt/connection-link.txt 2>/dev/null || true
    # Секрет хранится только в памяти, файл конфига остаётся для работы сервиса
}

install_deps() {
    print_section "УСТАНОВКА ЗАВИСИМОСТЕЙ"
    apt-get update -qq
    apt-get install -y -qq curl wget openssl ca-certificates xxd
    print_ok "Зависимости установлены"
}

download_telemt() {
    print_section "ЗАГРУЗКА TELEMT 3.0.15 (LTS)"
    
    cd /tmp
    rm -f telemt* 2>/dev/null || true
    
    print_info "Скачивание бинарного файла..."
    if ! wget -q https://github.com/telemt/telemt/releases/download/3.0.15/telemt-x86_64-linux-gnu.tar.gz; then
        print_error "Не удалось скачать Telemt"
        exit 1
    fi
    
    print_info "Распаковка архива..."
    tar -xzf telemt-x86_64-linux-gnu.tar.gz
    
    [[ -f "/bin/telemt" ]] && mv /bin/telemt /bin/telemt.bak 2>/dev/null || true
    
    mv telemt /bin/telemt
    chmod +x /bin/telemt
    
    print_ok "Telemt установлен в /bin/telemt"
}

create_config() {
    print_section "СОЗДАНИЕ КОНФИГУРАЦИИ"
    
    mkdir -p "${CONFIG_DIR}"
    
    cat > "${CONFIG_DIR}/telemt.toml" << EOF
# Telemt MTProto Proxy Configuration
# Версия 3.0.15 (LTS)

[general]
log_level = "normal"

[general.modes]
classic = false
secure = false
tls = true

[server]
port = ${TELEMT_PORT}
listen_addr_ipv4 = "0.0.0.0"
announce_ip = "${TELEMT_DOMAIN}"

[censorship]
tls_domain = "${TLS_MASK}"
mask = true

[access.users]
"user" = "${TELEMT_SECRET}"
EOF

    print_ok "Конфигурация создана в ${CONFIG_DIR}/telemt.toml"
}

create_service() {
    print_section "СОЗДАНИЕ SYSTEMD СЕРВИСА"
    
    cat > /etc/systemd/system/telemt.service << EOF
[Unit]
Description=Telemt MTProto Proxy (LTS 3.0.15)
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/bin/telemt /etc/telemt/telemt.toml
WorkingDirectory=/tmp
Restart=on-failure
RestartSec=5
User=nobody
Group=nogroup
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=/etc/telemt
PrivateTmp=yes
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    print_ok "Systemd сервис создан"
}

setup_firewall() {
    print_section "НАСТРОЙКА ФАЙРВОЛА"
    if command -v ufw &>/dev/null; then
        ufw allow "${TELEMT_PORT}/tcp" comment "Telemt" 2>/dev/null || true
        print_ok "Порт ${TELEMT_PORT} открыт в UFW"
    fi
}

start_service() {
    print_section "ЗАПУСК СЕРВИСА"
    
    systemctl stop telemt 2>/dev/null || true
    systemctl start telemt
    
    sleep 3
    
    if systemctl is-active --quiet telemt; then
        print_ok "Сервис запущен"
    else
        print_error "Сервис не запустился!"
        journalctl -u telemt -n 20 --no-pager
        exit 1
    fi
    
    systemctl enable telemt &>/dev/null || true
}

verify_installation() {
    print_section "ПРОВЕРКА УСТАНОВКИ"
    
    if ! pgrep -f telemt >/dev/null; then
        print_error "Процесс Telemt не найден"
        return 1
    fi
    print_ok "Процесс Telemt запущен"
    
    if ! ss -tlnp | grep -q ":${TELEMT_PORT} "; then
        print_error "Порт ${TELEMT_PORT} не слушается!"
        return 1
    fi
    print_ok "Порт ${TELEMT_PORT} слушается"
    
    local listening_ip
    listening_ip=$(ss -tlnp | grep ":${TELEMT_PORT}" | awk '{print $4}' | cut -d: -f1)
    if [[ "$listening_ip" == "0.0.0.0" ]]; then
        print_ok "Слушает на всех интерфейсах (0.0.0.0:${TELEMT_PORT})"
    fi
    
    return 0
}

show_secret_once() {
    print_warning_box
    
    local tls_hex
    tls_hex=$(echo -n "${TLS_MASK}" | xxd -p)
    local tls_secret="ee${TELEMT_SECRET}${tls_hex}"
    
    echo -e "${GREEN}${TOP_LEFT}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${TOP_RIGHT}${NC}"
    echo -e "${GREEN}${VERTICAL}${NC}                    ${WHITE}ДАННЫЕ ДЛЯ ПОДКЛЮЧЕНИЯ${NC}                    ${GREEN}${VERTICAL}${NC}"
    echo -e "${GREEN}${CROSS_LEFT}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${CROSS_RIGHT}${NC}"
    
    print_value "Сервер" "${TELEMT_DOMAIN}"
    print_value "Порт" "${TELEMT_PORT}"
    print_value "Секрет" "${TELEMT_SECRET}"
    print_value "TLS маска" "${TLS_MASK}"
    print_line
    print_link "ВЕБ" "https://t.me/proxy?server=${TELEMT_DOMAIN}&port=${TELEMT_PORT}&secret=${tls_secret}"
    print_link "TG" "tg://proxy?server=${TELEMT_DOMAIN}&port=${TELEMT_PORT}&secret=${tls_secret}"
    print_line
    print_info "⚠  ЭТО ЕДИНСТВЕННЫЙ РАЗ, КОГДА ССЫЛКА ПОКАЗАНА"
    print_info "⚠  СОХРАНИТЕ ЕЁ СЕЙЧАС В БЕЗОПАСНОМ МЕСТЕ"
    
    echo -e "${GREEN}${BOTTOM_LEFT}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${BOTTOM_RIGHT}${NC}"
    echo ""
    
    # Даём время скопировать ссылку
    print_warn "Ожидание 30 секунд для копирования ссылки..."
    for i in {30..1}; do
        printf "\r  ${YELLOW}Осталось ${i} секунд...${NC} "
        sleep 1
    done
    echo ""
}

show_commands() {
    echo ""
    echo -e "${GREEN}${TOP_LEFT}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${TOP_RIGHT}${NC}"
    echo -e "${GREEN}${VERTICAL}${NC}                    ${WHITE}КОМАНДЫ УПРАВЛЕНИЯ${NC}                      ${GREEN}${VERTICAL}${NC}"
    echo -e "${GREEN}${CROSS_LEFT}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${CROSS_RIGHT}${NC}"
    
    print_command "systemctl status telemt    # статус"
    print_command "journalctl -u telemt -f    # логи"
    print_command "systemctl restart telemt   # перезапуск"
    print_command "systemctl stop telemt      # остановка"
    print_command "systemctl start telemt     # запуск"
    
    echo -e "${GREEN}${BOTTOM_LEFT}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${BOTTOM_RIGHT}${NC}"
    echo ""
}

interactive_mode() {
    print_header "ИНТЕРАКТИВНАЯ УСТАНОВКА TELEMT LTS 3.0.15"
    
    local default_ip
    default_ip=$(get_ip)
    print_info "Определен внешний IP: ${YELLOW}${default_ip}${NC}"
    echo ""
    
    read -rp "  ${CYAN}Порт${NC} [8443]: " port_input
    TELEMT_PORT="${port_input:-8443}"
    
    while ss -tlnp | grep -q ":${TELEMT_PORT} "; do
        print_error "Порт ${TELEMT_PORT} занят!"
        read -rp "  ${CYAN}Введите другой порт${NC}: " TELEMT_PORT
    done
    
    read -rp "  ${CYAN}Домен или IP для ссылок${NC} [${default_ip}]: " domain_input
    TELEMT_DOMAIN="${domain_input:-${default_ip}}"
    
    local default_secret
    default_secret=$(gen_secret)
    read -rp "  ${CYAN}Секретный ключ${NC} [${default_secret}]: " secret_input
    TELEMT_SECRET="${secret_input:-${default_secret}}"
    
    read -rp "  ${CYAN}Домен TLS маскировки${NC} [${TLS_MASK}]: " mask_input
    TLS_MASK="${mask_input:-${TLS_MASK}}"
    
    echo ""
}

main() {
    # Устанавливаем обработчик для очистки при любом исходе
    trap cleanup EXIT
    
    print_header "TELEMT LTS 3.0.15 - БЕЗОПАСНАЯ УСТАНОВКА"
    
    check_root
    
    if [[ -t 0 && $# -eq 0 ]]; then
        interactive_mode
    else
        TELEMT_PORT="${1:-8443}"
        TELEMT_DOMAIN=$(get_ip)
        TELEMT_SECRET=$(gen_secret)
        print_info "Неинтерактивный режим"
        print_info "Порт: ${TELEMT_PORT}"
        print_info "IP: ${TELEMT_DOMAIN}"
        echo ""
    fi
    
    check_port
    install_deps
    download_telemt
    create_config
    create_service
    setup_firewall
    start_service
    
    if verify_installation; then
        show_secret_once
        show_commands
        print_ok "Установка успешно завершена!"
        print_info "Проверьте доступность порта: ${CYAN}https://portchecker.co/${NC}"
    else
        print_error "Установка не удалась!"
        exit 1
    fi
}

main "$@"
