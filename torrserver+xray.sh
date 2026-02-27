#!/bin/bash
#===============================================================================
# ИДЕМПОТЕНТНЫЙ СКРИПТ УСТАНОВКИ TorrServer + XRay
#===========================================================
# Автор: Auto-generated
# Версия: 2.0.0
# Описание: 
#   - Установка TorrServer через podman + quadlet с авторизацией
#   - Установка XRay-core с xhttp транспортом
#   - Проверка открытых портов
#   - Идемпотентность - можно запускать повторно без побочных эффектов
#===============================================================================

set -e

#=== КОНСТАНТЫ ================================================================
readonly SCRIPT_VERSION="2.0.0"
readonly TORRSERVER_PORT=8090
readonly XRAY_PORT=443
readonly TORRSERVER_IMAGE="ghcr.io/yourok/torrserver:latest"
readonly QUADLET_DIR="/etc/containers/systemd"
readonly TORRSERVER_DATA="/var/lib/torrserver"
readonly TORRSERVER_CONFIG="${TORRSERVER_DATA}/config"

# ANSI цвета
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[0;37m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly NC='\033[0m'

# Unicode символы
readonly CHECK="✓"
readonly CROSS="✗"
readonly ARROW="→"
readonly BULLET="•"

#=== ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ ====================================================
TORRSERVER_USER=""
TORRSERVER_PASS=""
XRAY_DOMAIN=""

#=== ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ==================================================

# Очистка экрана и показ заголовка
print_banner() {
    clear
    echo -e "${CYAN}"
    cat << 'BANNER'
╔══════════════════════════════════════════════════════════════════════════════╗
║                                                                              ║
║   ████████╗ █████╗ ██████╗ ██╗     ███████╗████████╗                        ║
║   ╚══██╔══╝██╔══██╗██╔══██╗██║     ██╔════╝╚══██╔══╝                        ║
║      ██║   ███████║██████╔╝██║     █████╗     ██║                           ║
║      ██║   ██╔══██║██╔══██╗██║     ██╔══╝     ██║                           ║
║      ██║   ██║  ██║██████╔╝███████╗███████╗   ██║                           ║
║      ╚═╝   ╚═╝  ╚═╝╚═════╝ ╚══════╝╚══════╝   ╚═╝                           ║
║                                                                              ║
║        ██████╗  █████╗ ██╗   ██╗███████╗                                     ║
║        ██╔══██╗██╔══██╗██║   ██║██╔════╝                                     ║
║        ██║  ██║███████║██║   ██║█████╗                                       ║
║        ██║  ██║██╔══██║╚██╗ ██╔╝██╔══╝                                       ║
║        ██████╔╝██║  ██║ ╚████╔╝ ███████╗                                     ║
║        ╚═════╝ ╚═╝  ╚═╝  ╚═══╝  ╚══════╝                                     ║
║                                                                              ║
╚══════════════════════════════════════════════════════════════════════════════╝
BANNER
    echo -e "${NC}"
    echo -e "${WHITE}${BOLD}   Идемпотентный установщик v${SCRIPT_VERSION}${NC}"
    echo -e "${DIM}   TorrServer (Podman + Quadlet) + XRay-core (XHTTP)${NC}"
    echo ""
}

# Печать секции
section() {
    local title="$1"
    echo ""
    echo -e "${MAGENTA}┌──────────────────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${MAGENTA}│${NC} ${WHITE}${BOLD}${title}${NC}"
    echo -e "${MAGENTA}└──────────────────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
}

# Статус с иконкой
status() {
    local type="$1"
    local msg="$2"
    local detail="${3:-}"
    
    case "$type" in
        ok|success|done)
            echo -e "  ${GREEN}${CHECK}${NC} ${msg}"
            ;;
        error|fail)
            echo -e "  ${RED}${CROSS}${NC} ${msg}"
            ;;
        warn|warning)
            echo -e "  ${YELLOW}!${NC} ${msg}"
            ;;
        info|progress)
            echo -e "  ${BLUE}${ARROW}${NC} ${msg}"
            ;;
        skip)
            echo -e "  ${DIM}○${NC} ${DIM}${msg}${NC}"
            ;;
        ask)
            echo -e "  ${CYAN}?${NC} ${msg}"
            ;;
    esac
    
    if [ -n "$detail" ]; then
        echo -e "      ${DIM}${detail}${NC}"
    fi
}

# Спиннер анимация
spinner() {
    local pid=$1
    local message="$2"
    local success_msg="${3:-Готово}"
    
    local spin=('⣾' '⣽' '⣻' '⢿' '⡿' '⣟' '⣯' '⣷')
    local i=0
    
    tput sc  # Save cursor
    
    while kill -0 $pid 2>/dev/null; do
        tput rc  # Restore cursor
        tput el  # Clear to end of line
        echo -ne "  ${CYAN}${spin[$((i % 8))]}${NC} ${message}"
        i=$((i + 1))
        sleep 0.08
    done
    
    wait $pid
    local exit_code=$?
    
    tput rc
    tput el
    
    if [ $exit_code -eq 0 ]; then
        echo -e "  ${GREEN}${CHECK}${NC} ${success_msg}"
        return 0
    else
        echo -e "  ${RED}${CROSS}${NC} ${message} - ошибка"
        return 1
    fi
}

# Прогресс-бар
progress() {
    local current=$1
    local total=$2
    local label="$3"
    
    local width=40
    local percent=$((current * 100 / total))
    local filled=$((current * width / total))
    local empty=$((width - filled))
    
    printf "\r  ${CYAN}["
    printf "%${filled}s" | tr ' ' '█'
    printf "%${empty}s" | tr ' ' '░'
    printf "]${NC} %3d%% %s" "$percent" "$label"
}

# Ввод пользователя
input() {
    local prompt="$1"
    local default="${2:-}"
    local password="${3:-false}"
    
    if [ -n "$default" ]; then
        echo -ne "  ${CYAN}?${NC} ${prompt} ${DIM}[${default}]${NC}: "
    else
        echo -ne "  ${CYAN}?${NC} ${prompt}: "
    fi
    
    if [ "$password" = "true" ]; then
        read -rs value
        echo ""
    else
        read -r value
    fi
    
    echo "${value:-$default}"
}

# Подтверждение
confirm() {
    local prompt="$1"
    local default="${2:-n}"
    
    local hint
    [ "$default" = "y" ] && hint="[Y/n]" || hint="[y/N]"
    
    echo -ne "  ${YELLOW}?${NC} ${prompt} ${DIM}${hint}${NC}: "
    read -r answer
    
    case "${answer:-$default}" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# Проверка root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}${BOLD}"
        echo "╔════════════════════════════════════════════════════════════════╗"
        echo "║  ОШИБКА: Скрипт должен запускаться от имени root (sudo)        ║"
        echo "╚════════════════════════════════════════════════════════════════╝"
        echo -e "${NC}"
        echo "  Используйте: sudo bash $0"
        exit 1
    fi
}

# Проверка и установка пакета
install_package() {
    local pkg="$1"
    local cmd="${2:-$1}"
    
    if command -v "$cmd" &>/dev/null; then
        status ok "${pkg} уже установлен"
        return 0
    fi
    
    status info "Установка ${pkg}..."
    
    if apt-get install -y "$pkg" &>/dev/null; then
        status ok "${pkg} установлен"
        return 0
    else
        status error "Не удалось установить ${pkg}"
        return 1
    fi
}

#=== ПРОВЕРКА СУЩЕСТВОВАНИЯ СЕРВИСОВ =========================================

torrserver_is_installed() {
    [ -f "${QUADLET_DIR}/torrserver.container" ] || \
    systemctl is-active torrserver &>/dev/null || \
    podman ps --format '{{.Names}}' 2>/dev/null | grep -q '^torrserver$'
}

xray_is_installed() {
    [ -f "/usr/local/bin/xray" ] && systemctl is-active xray &>/dev/null
}

#=== УСТАНОВКА ЗАВИСИМОСТЕЙ ===================================================

install_dependencies() {
    section "Проверка и установка зависимостей"
    
    # Обновление пакетов
    status info "Обновление списка пакетов..."
    apt-get update &>/dev/null && status ok "Список пакетов обновлен"
    
    # Установка необходимых пакетов
    local packages=(
        "curl:curl"
        "wget:wget"
        "podman:podman"
        "jq:jq"
        "qrencode:qrencode"
        "netcat-openbsd:nc"
        "openssl:openssl"
    )
    
    for pkg_def in "${packages[@]}"; do
        local pkg="${pkg_def%%:*}"
        local cmd="${pkg_def##*:}"
        install_package "$pkg" "$cmd"
    done
    
    status ok "Все зависимости установлены"
}

#=== УСТАНОВКА TORRSERVER =====================================================

install_torrserver() {
    section "Настройка TorrServer"
    
    # Проверка идемпотентности
    if torrserver_is_installed; then
        status skip "TorrServer уже установлен и настроен"
        
        if confirm "Переустановить TorrServer?" "n"; then
            status info "Удаление существующей установки..."
            systemctl stop torrserver 2>/dev/null || true
            podman rm -f torrserver 2>/dev/null || true
            rm -f "${QUADLET_DIR}/torrserver.container"
        else
            return 0
        fi
    fi
    
    # Настройка авторизации
    echo ""
    status ask "Настройка авторизации TorrServer"
    echo -e "  ${DIM}Введите учетные данные для доступа к веб-интерфейсу${NC}"
    echo ""
    
    TORRSERVER_USER=$(input "Имя пользователя" "admin")
    
    while true; do
        TORRSERVER_PASS=$(input "Пароль" "" "true")
        if [ -n "$TORRSERVER_PASS" ]; then
            local pass_confirm=$(input "Подтвердите пароль" "" "true")
            if [ "$TORRSERVER_PASS" = "$pass_confirm" ]; then
                break
            else
                status error "Пароли не совпадают, попробуйте снова"
            fi
        else
            status error "Пароль не может быть пустым"
        fi
    done
    
    # Создание директорий
    status info "Создание директорий данных..."
    mkdir -p "${TORRSERVER_CONFIG}"
    mkdir -p "${TORRSERVER_DATA}/db"
    mkdir -p "${QUADLET_DIR}"
    
    # Создание файла авторизации (htpasswd формат)
    status info "Создание файла авторизации..."
    echo -n "${TORRSERVER_USER}:${TORRSERVER_PASS}" > "${TORRSERVER_CONFIG}/accs.db"
    chmod 600 "${TORRSERVER_CONFIG}/accs.db"
    
    # Создание Quadlet файла
    status info "Создание systemd Quadlet..."
    cat > "${QUADLET_DIR}/torrserver.container" << QUADLET_EOF
[Unit]
Description=TorrServer - Torrent Streaming Server
Documentation=https://github.com/YouROK/TorrServer
After=network-online.target
Wants=network-online.target

[Container]
Image=${TORRSERVER_IMAGE}
ContainerName=torrserver

# Переменные окружения
Environment=TS_HTTPAUTH=1
Environment=TS_PORT=${TORRSERVER_PORT}
Environment=TS_RDB=1

# Порты
PublishPort=${TORRSERVER_PORT}:${TORRSERVER_PORT}

# Тома
Volume=${TORRSERVER_CONFIG}:/opt/ts/config:Z
Volume=${TORRSERVER_DATA}/db:/opt/ts/db:Z

# Автообновление
Pull=always

# Ресурсы (опционально)
# MemoryMax=2G
# CPUQuota=100%

# Безопасность
ReadOnlyTmpfs=true

[Service]
Restart=always
RestartSec=10
TimeoutStartSec=300
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
QUADLET_EOF
    
    # Перезагрузка systemd
    status info "Перезагрузка systemd..."
    systemctl daemon-reload
    
    # Загрузка образа
    status info "Загрузка образа ${TORRSERVER_IMAGE}..."
    (podman pull "${TORRSERVER_IMAGE}" &>/dev/null) &
    spinner $! "Загрузка Docker образа" "Образ загружен"
    
    # Запуск сервиса
    status info "Запуск сервиса torrserver..."
    systemctl enable --now torrserver &>/dev/null
    
    # Ожидание запуска
    sleep 5
    
    if systemctl is-active torrserver &>/dev/null; then
        status ok "TorrServer успешно запущен"
        status info "Веб-интерфейс: http://$(curl -4 -s --max-time 3 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}'):${TORRSERVER_PORT}"
        return 0
    else
        status error "Не удалось запустить TorrServer"
        echo ""
        echo -e "${DIM}Логи ошибки:${NC}"
        journalctl -u torrserver --no-pager -n 20 --output=cat 2>/dev/null || \
            podman logs torrserver 2>/dev/null | tail -20
        return 1
    fi
}

#=== УСТАНОВКА XRAY ===========================================================

install_xray() {
    section "Настройка XRay-core (VLESS + XHTTP + Reality)"
    
    # Проверка идемпотентности
    if xray_is_installed; then
        status skip "XRay уже установлен и настроен"
        
        if confirm "Переустановить XRay?" "n"; then
            status info "Удаление существующей установки..."
            systemctl stop xray 2>/dev/null || true
            rm -rf /usr/local/etc/xray
            rm -f /usr/local/bin/xray
            rm -f /usr/local/bin/mainuser /usr/local/bin/newuser /usr/local/bin/rmuser
            rm -f /usr/local/bin/userlist /usr/local/bin/sharelink
            rm -f ~/help
        else
            return 0
        fi
    fi
    
    # Запрос доменного имени
    echo ""
    status ask "Настройка домена для XRay"
    echo -e "  ${DIM}Введите доменное имя вашего сервера${NC}"
    echo -e "  ${DIM}Если домена нет, будет использован SNI github.com${NC}"
    echo ""
    
    XRAY_DOMAIN=$(input "Доменное имя (Enter для github.com)" "github.com")
    
    # Проверка порта 443
    if ss -tuln | grep -q ":${XRAY_PORT} "; then
        status warn "Порт ${XRAY_PORT} уже используется!"
        if ! confirm "Продолжить установку?" "n"; then
            return 1
        fi
    fi
    
    # Создаем модифицированный скрипт установки
    status info "Создание скрипта установки..."
    
    local install_script=$(cat << 'SCRIPT_EOF'
#!/bin/bash
# Модифицированный скрипт установки XRay с поддержкой домена

echo "Установка VLESS с транспортом XHTTP..."
sleep 2

# Обновление системы
apt update
apt install qrencode curl jq -y

# Включение BBR
bbr=$(sysctl -a 2>/dev/null | grep net.ipv4.tcp_congestion_control || echo "")
if [[ "$bbr" == *"bbr"* ]]; then
    echo "BBR уже включен"
else
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p
    echo "BBR включен"
fi

# Установка Xray-core
bash -c "$(curl -4 -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# Генерация ключей
[ -f /usr/local/etc/xray/.keys ] && rm /usr/local/etc/xray/.keys
touch /usr/local/etc/xray/.keys
echo "shortsid: $(openssl rand -hex 8)" >> /usr/local/etc/xray/.keys
echo "uuid: $(xray uuid)" >> /usr/local/etc/xray/.keys
xray x25519 >> /usr/local/etc/xray/.keys

export uuid=$(cat /usr/local/etc/xray/.keys | awk -F': ' '/uuid/ {print $2}')
export privatkey=$(cat /usr/local/etc/xray/.keys | awk -F': ' '/PrivateKey/ {print $2}')
export shortsid=$(cat /usr/local/etc/xray/.keys | awk -F': ' '/shortsid/ {print $2}')
export domain="__DOMAIN_PLACEHOLDER__"
SCRIPT_EOF
)
    
    # Подставляем домен
    install_script="${install_script//__DOMAIN_PLACEHOLDER__/$XRAY_DOMAIN}"
    
    # Добавляем конфигурацию
    install_script+=$(cat << 'CONFIG_EOF'

# Создание конфигурации Xray
touch /usr/local/etc/xray/config.json
cat << EOF > /usr/local/etc/xray/config.json
{
    "log": {
        "loglevel": "warning"
    },
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {
                "type": "field",
                "domain": ["geosite:category-ads-all"],
                "outboundTag": "block"
            },
            {
                "type": "field",
                "ip": ["geoip:cn"],
                "outboundTag": "block"
            }
        ]
    },
    "inbounds": [
        {
            "listen": "0.0.0.0",
            "port": 443,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "email": "main",
                        "id": "$uuid",
                        "flow": ""
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "xhttp",
                "xhttpSettings": {
                    "path": "/"
                },
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "target": "$domain:443",
                    "serverNames": ["$domain", "www.$domain"],
                    "privateKey": "$privatkey",
                    "minClientVer": "",
                    "maxClientVer": "",
                    "maxTimeDiff": 0,
                    "shortIds": ["$shortsid"]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls", "quic"]
            }
        }
    ],
    "outbounds": [
        {"protocol": "freedom", "tag": "direct"},
        {"protocol": "blackhole", "tag": "block"}
    ],
    "policy": {
        "levels": {
            "0": {
                "handshake": 3,
                "connIdle": 180
            }
        }
    }
}
EOF

# Утилиты управления пользователями
mkdir -p /usr/local/bin

# userlist
cat << 'EOF' > /usr/local/bin/userlist
#!/bin/bash
emails=($(jq -r '.inbounds[0].settings.clients[].email' "/usr/local/etc/xray/config.json" 2>/dev/null))
if [[ ${#emails[@]} -eq 0 ]]; then
    echo "Список клиентов пуст"
    exit 1
fi
echo "Список клиентов:"
for i in "${!emails[@]}"; do
    echo "$((i+1)). ${emails[$i]}"
done
EOF
chmod +x /usr/local/bin/userlist

# mainuser
cat << 'EOF' > /usr/local/bin/mainuser
#!/bin/bash
protocol=$(jq -r '.inbounds[0].protocol' /usr/local/etc/xray/config.json)
port=$(jq -r '.inbounds[0].port' /usr/local/etc/xray/config.json)
uuid=$(cat /usr/local/etc/xray/.keys | awk -F': ' '/uuid/ {print $2}')
pbk=$(cat /usr/local/etc/xray/.keys | awk -F': ' '/Password/ {print $2}')
sid=$(cat /usr/local/etc/xray/.keys | awk -F': ' '/shortsid/ {print $2}')
sni=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' /usr/local/etc/xray/config.json)
ip=$(timeout 3 curl -4 -s icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}')
link="$protocol://$uuid@$ip:$port?security=reality&path=%2F&host=&mode=auto&sni=$sni&fp=firefox&pbk=$pbk&sid=$sid&spx=%2F&type=xhttp&encryption=none#vless-$ip"
echo ""
echo "Ссылка для подключения:"
echo "$link"
echo ""
echo "QR-код:"
echo "${link}" | qrencode -t ansiutf8 2>/dev/null || echo "$link"
EOF
chmod +x /usr/local/bin/mainuser

# newuser
cat << 'EOF' > /usr/local/bin/newuser
#!/bin/bash
read -p "Введите имя пользователя (email): " email
if [[ -z "$email" || "$email" == *" "* ]]; then
    echo "Имя пользователя не может быть пустым или содержать пробелы"
    exit 1
fi
user_json=$(jq --arg email "$email" '.inbounds[0].settings.clients[] | select(.email == $email)' /usr/local/etc/xray/config.json 2>/dev/null)
if [[ -z "$user_json" ]]; then
    uuid=$(xray uuid)
    jq --arg email "$email" --arg uuid "$uuid" '.inbounds[0].settings.clients += [{"email": $email, "id": $uuid, "flow": ""}]' /usr/local/etc/xray/config.json > /tmp/xray_config.tmp && mv /tmp/xray_config.tmp /usr/local/etc/xray/config.json
    systemctl restart xray
    index=$(jq --arg email "$email" '.inbounds[0].settings.clients | to_entries[] | select(.value.email == $email) | .key' /usr/local/etc/xray/config.json)
    protocol=$(jq -r '.inbounds[0].protocol' /usr/local/etc/xray/config.json)
    port=$(jq -r '.inbounds[0].port' /usr/local/etc/xray/config.json)
    uuid=$(jq --argjson index "$index" -r '.inbounds[0].settings.clients[$index].id' /usr/local/etc/xray/config.json)
    pbk=$(cat /usr/local/etc/xray/.keys | awk -F': ' '/Password/ {print $2}')
    sid=$(cat /usr/local/etc/xray/.keys | awk -F': ' '/shortsid/ {print $2}')
    sni=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' /usr/local/etc/xray/config.json)
    ip=$(curl -4 -s icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}')
    link="$protocol://$uuid@$ip:$port?security=reality&path=%2F&host=&mode=auto&sni=$sni&fp=firefox&pbk=$pbk&sid=$sid&spx=%2F&type=xhttp&encryption=none#$email"
    echo ""
    echo "Ссылка для подключения:"
    echo "$link"
    echo ""
    echo "QR-код:"
    echo "${link}" | qrencode -t ansiutf8 2>/dev/null || echo "$link"
else
    echo "Пользователь с таким именем уже существует"
fi
EOF
chmod +x /usr/local/bin/newuser

# rmuser
cat << 'EOF' > /usr/local/bin/rmuser
#!/bin/bash
emails=($(jq -r '.inbounds[0].settings.clients[].email' "/usr/local/etc/xray/config.json" 2>/dev/null))
if [[ ${#emails[@]} -eq 0 ]]; then
    echo "Нет клиентов для удаления"
    exit 1
fi
echo "Список клиентов:"
for i in "${!emails[@]}"; do
    echo "$((i+1)). ${emails[$i]}"
done
read -p "Введите номер клиента для удаления: " choice
if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#emails[@]} )); then
    echo "Ошибка: номер должен быть от 1 до ${#emails[@]}"
    exit 1
fi
selected_email="${emails[$((choice - 1))]}"
jq --arg email "$selected_email" '(.inbounds[0].settings.clients) |= map(select(.email != $email))' "/usr/local/etc/xray/config.json" > /tmp/xray_config.tmp && mv /tmp/xray_config.tmp "/usr/local/etc/xray/config.json"
systemctl restart xray
echo "Клиент $selected_email удалён"
EOF
chmod +x /usr/local/bin/rmuser

# sharelink
cat << 'EOF' > /usr/local/bin/sharelink
#!/bin/bash
emails=($(jq -r '.inbounds[0].settings.clients[].email' /usr/local/etc/xray/config.json 2>/dev/null))
for i in "${!emails[@]}"; do
    echo "$((i + 1)). ${emails[$i]}"
done
read -p "Выберите клиента: " client
if ! [[ "$client" =~ ^[0-9]+$ ]] || (( client < 1 || client > ${#emails[@]} )); then
    echo "Ошибка: номер должен быть от 1 до ${#emails[@]}"
    exit 1
fi
selected_email="${emails[$((client - 1))]}"
index=$(jq --arg email "$selected_email" '.inbounds[0].settings.clients | to_entries[] | select(.value.email == $email) | .key' /usr/local/etc/xray/config.json)
protocol=$(jq -r '.inbounds[0].protocol' /usr/local/etc/xray/config.json)
port=$(jq -r '.inbounds[0].port' /usr/local/etc/xray/config.json)
uuid=$(jq --argjson index "$index" -r '.inbounds[0].settings.clients[$index].id' /usr/local/etc/xray/config.json)
pbk=$(cat /usr/local/etc/xray/.keys | awk -F': ' '/Password/ {print $2}')
sid=$(cat /usr/local/etc/xray/.keys | awk -F': ' '/shortsid/ {print $2}')
username=$(jq --argjson index "$index" -r '.inbounds[0].settings.clients[$index].email' /usr/local/etc/xray/config.json)
sni=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' /usr/local/etc/xray/config.json)
ip=$(curl -4 -s icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}')
link="$protocol://$uuid@$ip:$port?security=reality&path=%2F&host=&mode=auto&sni=$sni&fp=firefox&pbk=$pbk&sid=$sid&spx=%2F&type=xhttp&encryption=none#$username"
echo ""
echo "Ссылка для подключения:"
echo "$link"
echo ""
echo "QR-код:"
echo "${link}" | qrencode -t ansiutf8 2>/dev/null || echo "$link"
EOF
chmod +x /usr/local/bin/sharelink

systemctl restart xray
echo "Xray-core успешно установлен"
mainuser
CONFIG_EOF
)
    
    # Сохраняем скрипт во временный файл
    local tmp_script="/tmp/xray-install-$$.sh"
    echo "$install_script" > "$tmp_script"
    chmod +x "$tmp_script"
    
    # Запускаем установку
    status info "Запуск установки XRay-core..."
    echo ""
    
    if bash "$tmp_script"; then
        status ok "XRay-core успешно установлен"
        rm -f "$tmp_script"
        return 0
    else
        status error "Ошибка при установке XRay-core"
        rm -f "$tmp_script"
        return 1
    fi
}

#=== ПРОВЕРКА ПОРТОВ И СЕРВИСОВ ==============================================

check_services() {
    section "Проверка статуса сервисов и портов"
    
    local external_ip=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    
    echo -e "  ${BOLD}Статус сервисов:${NC}"
    echo ""
    
    # TorrServer статус
    if systemctl is-active torrserver &>/dev/null; then
        status ok "TorrServer активен (systemd service)"
    elif podman ps --format '{{.Names}}' 2>/dev/null | grep -q '^torrserver$'; then
        status ok "TorrServer активен (podman container)"
    else
        status error "TorrServer не активен"
    fi
    
    # XRay статус
    if systemctl is-active xray &>/dev/null; then
        status ok "XRay активен (systemd service)"
    else
        status warn "XRay не активен"
    fi
    
    echo ""
    echo -e "  ${BOLD}Проверка портов:${NC}"
    echo ""
    
    # Проверка порта TorrServer
    if ss -tuln | grep -q ":${TORRSERVER_PORT} "; then
        status ok "Порт ${TORRSERVER_PORT} (TorrServer) открыт"
        
        # Проверка локального подключения
        if nc -z -w3 localhost ${TORRSERVER_PORT} 2>/dev/null; then
            status ok "TorrServer отвечает на localhost:${TORRSERVER_PORT}"
        else
            status warn "TorrServer не отвечает на подключение"
        fi
    else
        status error "Порт ${TORRSERVER_PORT} (TorrServer) закрыт"
    fi
    
    # Проверка порта XRay
    if ss -tuln | grep -q ":${XRAY_PORT} "; then
        status ok "Порт ${XRAY_PORT} (XRay) открыт"
        
        # Проверка локального подключения
        if nc -z -w3 localhost ${XRAY_PORT} 2>/dev/null; then
            status ok "XRay отвечает на localhost:${XRAY_PORT}"
        else
            status warn "XRay не отвечает на подключение"
        fi
    else
        status error "Порт ${XRAY_PORT} (XRay) закрыт"
    fi
    
    echo ""
    echo -e "  ${BOLD}Информация для подключения:${NC}"
    echo ""
    
    # TorrServer
    echo -e "  ${BLUE}${BOLD}TorrServer:${NC}"
    echo -e "    ${ARROW} URL: ${WHITE}${BOLD}http://${external_ip}:${TORRSERVER_PORT}${NC}"
    if [ -f "${TORRSERVER_CONFIG}/accs.db" ]; then
        local creds=$(cat "${TORRSERVER_CONFIG}/accs.db" 2>/dev/null)
        local user=$(echo "$creds" | cut -d: -f1)
        echo -e "    ${ARROW} Пользователь: ${WHITE}${BOLD}${user}${NC}"
        echo -e "    ${ARROW} Пароль: ${WHITE}${BOLD}***${NC}"
    fi
    
    # XRay
    echo ""
    echo -e "  ${BLUE}${BOLD}XRay:${NC}"
    if [ -f "/usr/local/bin/mainuser" ]; then
        echo -e "    ${ARROW} Для получения ссылки: ${WHITE}${BOLD}mainuser${NC}"
        echo -e "    ${ARROW} Добавить пользователя: ${WHITE}${BOLD}newuser${NC}"
        echo -e "    ${ARROW} Список пользователей: ${WHITE}${BOLD}userlist${NC}"
        echo -e "    ${ARROW} Удалить пользователя: ${WHITE}${BOLD}rmuser${NC}"
        echo -e "    ${ARROW} Ссылка для пользователя: ${WHITE}${BOLD}sharelink${NC}"
    fi
    
    # Напоминание о firewall
    echo ""
    echo -e "  ${YELLOW}${BOLD}Важно:${NC} Убедитесь, что порты ${TORRSERVER_PORT} и ${XRAY_PORT} открыты в firewall!"
    echo -e "  ${DIM}    ufw allow ${TORRSERVER_PORT}/tcp${NC}"
    echo -e "  ${DIM}    ufw allow ${XRAY_PORT}/tcp${NC}"
}

#=== ПОКАЗАТЬ СПРАВКУ ========================================================

show_help() {
    section "Доступные команды"
    
    echo -e "  ${BOLD}TorrServer:${NC}"
    echo -e "    systemctl status torrserver   - статус сервиса"
    echo -e "    systemctl restart torrserver  - перезапуск"
    echo -e "    journalctl -u torrserver -f   - логи в реальном времени"
    echo -e "    podman logs -f torrserver     - логи контейнера"
    echo ""
    
    echo -e "  ${BOLD}XRay:${NC}"
    echo -e "    mainuser   - ссылка основного пользователя"
    echo -e "    newuser    - создать нового пользователя"
    echo -e "    rmuser     - удалить пользователя"
    echo -e "    userlist   - список пользователей"
    echo -e "    sharelink  - получить ссылку для пользователя"
    echo ""
    
    echo -e "  ${BOLD}Конфигурация:${NC}"
    echo -e "    TorrServer: ${TORRSERVER_CONFIG}"
    echo -e "    XRay: /usr/local/etc/xray/config.json"
    echo ""
    
    echo -e "  ${BOLD}Этот скрипт:${NC}"
    echo -e "    $0          - установка"
    echo -e "    $0 check    - проверка статуса"
    echo -e "    $0 uninstall - удаление"
}

#=== УДАЛЕНИЕ =================================================================

uninstall() {
    section "Удаление установки"
    
    local remove_all=false
    
    if confirm "Удалить ВСЕ компоненты (TorrServer и XRay)?" "n"; then
        remove_all=true
    fi
    
    # TorrServer
    if $remove_all || confirm "Удалить TorrServer?" "n"; then
        status info "Остановка TorrServer..."
        systemctl stop torrserver 2>/dev/null || true
        systemctl disable torrserver 2>/dev/null || true
        
        status info "Удаление контейнера..."
        podman rm -f torrserver 2>/dev/null || true
        
        status info "Удаление конфигурации..."
        rm -f "${QUADLET_DIR}/torrserver.container"
        rm -rf "${TORRSERVER_DATA}"
        
        systemctl daemon-reload
        status ok "TorrServer удален"
    fi
    
    # XRay
    if $remove_all || confirm "Удалить XRay?" "n"; then
        status info "Остановка XRay..."
        systemctl stop xray 2>/dev/null || true
        systemctl disable xray 2>/dev/null || true
        
        status info "Удаление файлов..."
        rm -rf /usr/local/etc/xray
        rm -f /usr/local/bin/xray
        rm -f /usr/local/bin/{mainuser,newuser,rmuser,userlist,sharelink}
        rm -f ~/help
        
        status ok "XRay удален"
    fi
    
    # Удаление образа podman
    if confirm "Удалить Docker образ TorrServer?" "n"; then
        podman rmi "${TORRSERVER_IMAGE}" 2>/dev/null || true
        status ok "Образ удален"
    fi
}

#=== ГЛАВНАЯ ФУНКЦИЯ ==========================================================

main() {
    print_banner
    check_root
    
    case "${1:-install}" in
        install|"")
            install_dependencies
            install_torrserver
            install_xray
            check_services
            show_help
            ;;
        check|status)
            check_services
            ;;
        uninstall|remove)
            uninstall
            ;;
        help|--help|-h)
            echo "Использование: $0 [команда]"
            echo ""
            echo "Команды:"
            echo "  install    - установка (по умолчанию)"
            echo "  check      - проверка статуса сервисов"
            echo "  uninstall  - полное удаление"
            echo "  help       - эта справка"
            ;;
        *)
            echo -e "${RED}Неизвестная команда: $1${NC}"
            echo "Используйте '$0 help' для справки"
            exit 1
            ;;
    esac
    
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC} ${WHITE}${BOLD}Готово! Установка завершена успешно.${NC} ${GREEN}║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# Запуск
main "$@"
