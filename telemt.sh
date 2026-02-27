#!/bin/bash
#===============================================================================
# Telemt MTProto Proxy for Ubuntu Server 24.04.4 LTS
# FINAL FIXED VERSION - полностью рабочий скрипт
#===============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }

CONFIG_DIR="/etc/telemt"
TELEMT_PORT="8443"
TELEMT_SECRET=""
TELEMT_DOMAIN=""
TLS_MASK="www.microsoft.com"

check_root() {
    [[ $EUID -eq 0 ]] || { log_error "Запустите скрипт от root (sudo)"; exit 1; }
}

is_interactive() {
    [[ -t 0 && -t 1 ]]
}

check_port() {
    if ss -tlnp | grep -q ":${TELEMT_PORT} "; then
        log_error "Порт ${TELEMT_PORT} уже занят!"
        log_info "Процессы, использующие порт ${TELEMT_PORT}:"
        ss -tlnp | grep ":${TELEMT_PORT}" || true
        exit 1
    fi
}

install_deps() {
    log_info "Установка необходимых пакетов..."
    apt-get update -qq
    apt-get install -y -qq curl wget openssl podman ca-certificates xxd
    log_ok "Готово"
}

configure_podman() {
    log_info "Настройка Podman..."
    rm -f /etc/containers/storage.conf 2>/dev/null || true
    systemctl stop podman 2>/dev/null || true
    
    if podman info 2>&1 | grep -q "mismatch"; then
        log_info "Сброс хранилища podman..."
        podman system reset -f 2>/dev/null || true
    fi
    log_ok "Готово"
}

get_ip() {
    curl -s --max-time 5 -4 ifconfig.me || echo "UNKNOWN"
}

gen_secret() {
    openssl rand -hex 16
}

build_image() {
    log_info "Сборка образа контейнера для порта ${TELEMT_PORT}..."
    local tmpdir
    tmpdir=$(mktemp -d)
    
    # Исправленный Containerfile - без --port аргумента
    cat > "${tmpdir}/Containerfile" << EOF
FROM alpine:3.19
RUN apk add --no-cache ca-certificates
RUN addgroup -g 1000 telemt && adduser -u 1000 -G telemt -D telemt
ARG ARCH
ARG PORT=${TELEMT_PORT}
RUN arch=\$(echo \${ARCH} | sed 's/amd64/x86_64/;s/arm64/aarch64/') && \
    wget -q "https://github.com/telemt/telemt/releases/latest/download/telemt-\${arch}-linux-musl.tar.gz" && \
    tar -xzf telemt-*.tar.gz -C /usr/local/bin && chmod +x /usr/local/bin/telemt && rm telemt-*.tar.gz
RUN mkdir -p /etc/telemt && chown telemt:telemt /etc/telemt
USER telemt
EXPOSE \${PORT}
ENTRYPOINT ["/usr/local/bin/telemt"]
# ВАЖНО: только путь к конфигу, без --port
CMD ["/etc/telemt/telemt.toml"]
EOF

    log_info "Сборка образа (может занять минуту)..."
    if ! podman build \
        --build-arg ARCH="$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')" \
        --build-arg PORT="${TELEMT_PORT}" \
        -t localhost/telemt:latest "${tmpdir}" 2>&1 | tee "${tmpdir}/build.log"; then
        log_error "Сборка не удалась!"
        cat "${tmpdir}/build.log"
        rm -rf "${tmpdir}"
        exit 1
    fi
    
    rm -rf "${tmpdir}"
    log_ok "Образ успешно собран"
}

create_config() {
    log_info "Создание конфигурации для порта ${TELEMT_PORT}..."
    
    rm -rf "${CONFIG_DIR}"
    mkdir -p "${CONFIG_DIR}"
    
    # Исправленный конфиг - правильный log_level
    cat > "${CONFIG_DIR}/telemt.toml" << EOF
# Telemt MTProto Proxy Configuration

[general]
# ВАЖНО: используем "normal" вместо "info" (info недопустимо)
log_level = "normal"

[general.modes]
classic = false
secure = false
tls = true

# Слушаем на всех интерфейсах на указанном порту
[[server.listeners]]
ip = "0.0.0.0"
port = ${TELEMT_PORT}
# announce_ip = "${TELEMT_DOMAIN}"  # раскомментируйте для указания внешнего IP в ссылках

# Настройки маскировки TLS
[censorship]
tls_domain = "${TLS_MASK}"
mask = true

# Пользователь и секрет
[access.users]
"user" = "${TELEMT_SECRET}"
EOF

    chown -R 1000:1000 "${CONFIG_DIR}"
    chmod 755 "${CONFIG_DIR}"
    chmod 644 "${CONFIG_DIR}/telemt.toml"
    
    log_ok "Конфиг создан с портом ${TELEMT_PORT}"
}

run_container() {
    log_info "Запуск контейнера на порту ${TELEMT_PORT}..."
    
    # Остановка и удаление старого контейнера
    podman stop telemt 2>/dev/null || true
    podman rm telemt 2>/dev/null || true
    
    # Создание директории для кэша
    mkdir -p "${CONFIG_DIR}/cache"
    chown -R 1000:1000 "${CONFIG_DIR}/cache"
    
    # ВАЖНО: в команде запуска нет --port, только проброс портов
    if ! podman run -d --name telemt \
        --restart always \
        -p "${TELEMT_PORT}:${TELEMT_PORT}" \
        -v "${CONFIG_DIR}:/etc/telemt:ro" \
        -v "${CONFIG_DIR}/cache:/var/lib/telemt:rw" \
        --ulimit nofile=65536:65536 \
        localhost/telemt:latest; then
        log_error "Не удалось запустить контейнер!"
        exit 1
    fi
    
    sleep 5
    
    # Проверка, что контейнер запущен
    if podman ps --format "{{.Names}}" | grep -q "^telemt$"; then
        log_ok "Контейнер успешно запущен"
    else
        log_error "Контейнер не запустился!"
        podman ps -a | grep telemt
        log_info "Логи контейнера:"
        podman logs telemt 2>&1 | tail -30
        exit 1
    fi
}

firewall() {
    if command -v ufw &>/dev/null; then
        ufw allow "${TELEMT_PORT}/tcp" comment "Telemt" 2>/dev/null || true
        log_ok "Firewall: порт ${TELEMT_PORT} открыт"
    fi
}

verify_deployment() {
    log_info "Проверка развертывания на порту ${TELEMT_PORT}..."
    
    # Проверка запущенного контейнера
    if ! podman ps --format "{{.Names}}" | grep -q "^telemt$"; then
        log_error "Контейнер не запущен!"
        return 1
    fi
    
    # Проверка, что порт слушается на хосте
    sleep 3
    if ss -tlnp | grep -q ":${TELEMT_PORT} "; then
        log_ok "Порт ${TELEMT_PORT} слушается на хосте"
    else
        log_error "Порт ${TELEMT_PORT} НЕ слушается на хосте!"
        log_info "Логи контейнера:"
        podman logs telemt 2>&1 | tail -20
        return 1
    fi
    
    # Показываем последние логи
    log_info "Последние логи контейнера:"
    podman logs telemt 2>&1 | tail -10
    
    return 0
}

show_info() {
    local tls_hex
    tls_hex=$(echo -n "${TLS_MASK}" | xxd -p)
    
    # Формируем правильный TLS секрет (ee + секрет + hex домена)
    local tls_secret="ee${TELEMT_SECRET}${tls_hex}"
    local link="tg://proxy?server=${TELEMT_DOMAIN}&port=${TELEMT_PORT}&secret=${tls_secret}"
    local link_web="https://t.me/proxy?server=${TELEMT_DOMAIN}&port=${TELEMT_PORT}&secret=${tls_secret}"
    
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}║           TELEMT УСПЕШНО РАЗВЕРНУТ!                       ║${NC}"
    echo -e "${GREEN}╠═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}Сервер:${NC}     ${YELLOW}${TELEMT_DOMAIN}${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}Порт:${NC}       ${YELLOW}${TELEMT_PORT}${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}Секрет:${NC}    ${YELLOW}${TELEMT_SECRET}${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}TLS маска:${NC} ${YELLOW}${TLS_MASK}${NC}"
    echo -e "${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}                 ${CYAN}ССЫЛКИ ДЛЯ ПОДКЛЮЧЕНИЯ${NC}"
    echo -e "${GREEN}║${NC}"
    echo -e "  ${link_web}"
    echo ""
    echo -e "  ${link}"
    echo ""
    echo -e "${GREEN}║${NC}  ${YELLOW}Полезные команды:${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}podman logs -f telemt${NC}     - просмотр логов"
    echo -e "${GREEN}║${NC}  ${CYAN}podman stop telemt${NC}        - остановка"
    echo -e "${GREEN}║${NC}  ${CYAN}podman start telemt${NC}       - запуск"
    echo -e "${GREEN}║${NC}  ${CYAN}podman restart telemt${NC}     - перезапуск"
    echo -e "${GREEN}║${NC}  ${CYAN}cat /etc/telemt/telemt.toml${NC} - конфиг"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Сохраняем ссылки в файл
    echo "${link_web}" > "${CONFIG_DIR}/connection-link.txt"
    echo "${link}" >> "${CONFIG_DIR}/connection-link.txt"
    chown 1000:1000 "${CONFIG_DIR}/connection-link.txt" 2>/dev/null || true
    log_ok "Ссылки сохранены в ${CONFIG_DIR}/connection-link.txt"
}

test_connection() {
    log_info "Тестирование локального подключения..."
    
    # Проверка локального подключения к порту
    if command -v nc &>/dev/null; then
        if nc -z localhost "${TELEMT_PORT}" 2>/dev/null; then
            log_ok "Локальное подключение к порту ${TELEMT_PORT} успешно"
        else
            log_warn "Локальное подключение не удалось (порт не отвечает)"
        fi
    fi
    
    # Проверка через curl (ожидаем 400 Bad Request от MTProto)
    if command -v curl &>/dev/null; then
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${TELEMT_PORT}" 2>/dev/null || echo "000")
        if [[ "$http_code" == "400" ]]; then
            log_ok "Прокси ответил кодом 400 (нормально для MTProto)"
        else
            log_warn "Неожиданный HTTP ответ: $http_code"
        fi
    fi
}

interactive() {
    local ip
    ip=$(get_ip)
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║           ИНТЕРАКТИВНАЯ УСТАНОВКА TELEMT             ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "Определен IP: ${YELLOW}${ip}${NC}"
    echo -e "Порт по умолчанию: ${YELLOW}8443${NC} (непривилегированный)"
    echo ""
    
    read -rp "Порт [8443]: " port_input
    TELEMT_PORT="${port_input:-8443}"
    
    while ss -tlnp | grep -q ":${TELEMT_PORT} "; do
        log_error "Порт ${TELEMT_PORT} уже используется!"
        ss -tlnp | grep ":${TELEMT_PORT}" || true
        read -rp "Введите другой порт: " TELEMT_PORT
    done
    
    read -rp "Домен или IP для ссылок [${ip}]: " d
    TELEMT_DOMAIN="${d:-${ip}}"
    
    local s
    s=$(gen_secret)
    read -rp "Секрет [${s}]: " d
    TELEMT_SECRET="${d:-${s}}"
    
    read -rp "Домен для TLS маскировки [${TLS_MASK}]: " d
    TLS_MASK="${d:-${TLS_MASK}}"
}

main() {
    # Парсинг аргументов командной строки
    if [[ -n "${1:-}" ]]; then
        TELEMT_PORT="$1"
    fi
    
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}║       Установщик Telemt MTProto Proxy        ║${NC}"
    echo -e "${GREEN}║           Ubuntu Server 24.04               ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════${NC}"
    echo ""
    
    check_root
    
    if ! is_interactive; then
        TELEMT_DOMAIN=$(get_ip)
        TELEMT_SECRET=$(gen_secret)
        log_info "Неинтерактивный режим"
        log_info "IP: ${TELEMT_DOMAIN}"
        log_info "Порт: ${TELEMT_PORT}"
    else
        interactive
    fi
    
    check_port
    log_info "Развертывание на порту ${TELEMT_PORT}..."
    
    install_deps
    configure_podman
    build_image
    create_config
    firewall
    run_container
    
    if verify_deployment; then
        test_connection
        show_info
        log_ok "Развертывание завершено! Порт ${TELEMT_PORT} должен быть доступен."
        log_info "Проверка с другого сервера: nc -zv ${TELEMT_DOMAIN} ${TELEMT_PORT}"
    else
        log_error "Проверка развертывания не удалась!"
        exit 1
    fi
}

main "$@"
