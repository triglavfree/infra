#!/bin/bash
set -uo pipefail
# =============================================================================
# INFRASTRUCTURE v12.0.0 (ФИНАЛЬНАЯ АБСОЛЮТНАЯ)
# =============================================================================
# Полноценная домашняя инфраструктура на Ubuntu Server 24.04
# Использует Quadlet для управления контейнерами через systemd
#
# ✅ Passbolt — менеджер паролей для людей
# ✅ Faucet — MCP-сервер + GUI для API-ключей (AI-агенты)
# ✅ Backrest — управление бэкапами
# ✅ Restic REST — хранилище бэкапов
# ✅ Gitea + Runner — Git с CI/CD
# ✅ TorrServer — торрент-стриминг
# ✅ Homepage — красивый дашборд с погодой
# ✅ Nginx Proxy Manager — reverse proxy с GUI
# ✅ NetBird VPN — доступ из любой точки
# ✅ mkcert — локальный HTTPS
# =============================================================================

# =============== 1. ЦВЕТА ===============
if [ -t 1 ]; then
    ncolors=$(tput colors 2>/dev/null || echo 0)
    if [ $ncolors -ge 256 ]; then
        NEON_CYAN=$(tput setaf 51); NEON_GREEN=$(tput setaf 48)
        NEON_YELLOW=$(tput setaf 220); NEON_RED=$(tput setaf 196)
        NEON_PURPLE=$(tput setaf 135); NEON_BLUE=$(tput setaf 39)
        SOFT_WHITE=$(tput setaf 255); MUTED_GRAY=$(tput setaf 245)
        DIM_GRAY=$(tput setaf 240); BOLD=$(tput bold); RESET=$(tput sgr0)
    else
        NEON_CYAN=$(tput setaf 6); NEON_GREEN=$(tput setaf 2)
        NEON_YELLOW=$(tput setaf 3); NEON_RED=$(tput setaf 1)
        NEON_PURPLE=$(tput setaf 5); NEON_BLUE=$(tput setaf 4)
        SOFT_WHITE=$(tput setaf 7); MUTED_GRAY=$(tput setaf 8)
        DIM_GRAY=$(tput setaf 8); BOLD=$(tput bold); RESET=$(tput sgr0)
    fi
else
    NEON_CYAN=""; NEON_GREEN=""; NEON_YELLOW=""; NEON_RED=""
    NEON_PURPLE=""; NEON_BLUE=""; SOFT_WHITE=""; MUTED_GRAY=""
    DIM_GRAY=""; BOLD=""; RESET=""
fi

CURRENT_USER="${SUDO_USER:-$(whoami)}"
CURRENT_UID=$(id -u "$CURRENT_USER")
CURRENT_HOME="$(getent passwd "$CURRENT_USER" 2>/dev/null | cut -d: -f6)"
SERVER_IP=$(hostname -I | awk '{print $1}')

# =============== 2. ФУНКЦИИ ===============
print_header() { 
    echo ""; 
    echo -e "${DIM_GRAY}─────────────────────────────────────────${RESET}"; 
    echo -e "${NEON_CYAN}${BOLD}  $1${RESET}"; 
    echo -e "${DIM_GRAY}─────────────────────────────────────────${RESET}"; 
    echo ""; 
}

print_step() { 
    echo ""; 
    echo -e "${NEON_CYAN}${BOLD}▸${RESET} ${SOFT_WHITE}${BOLD}$1${RESET}"; 
    echo -e "${DIM_GRAY}  $(printf '─%.0s' $(seq 1 40))${RESET}"; 
}

print_success() { echo -e "  ${NEON_GREEN}✓${RESET} ${SOFT_WHITE}$1${RESET}"; }
print_warning() { echo -e "  ${NEON_YELLOW}⚡${RESET} ${SOFT_WHITE}$1${RESET}"; }
print_error() { echo -e "  ${NEON_RED}✗${RESET} ${BOLD}$1${RESET}" >&2; }
print_info() { echo -e "  ${NEON_BLUE}ℹ${RESET} ${MUTED_GRAY}$1${RESET}"; }
print_url() { echo -e "  ${NEON_CYAN}➜${RESET} ${BOLD}${NEON_CYAN}$1${RESET}"; }

step() {
    local msg=$1
    local cmd=$2
    local critical=${3:-false}
    echo -ne "  ${MUTED_GRAY}➜${RESET} $msg... "
    if eval "$cmd" >/dev/null 2>&1; then
        echo -e "${NEON_GREEN}✓${RESET}"
        return 0
    else
        echo -e "${NEON_RED}✗${RESET}"
        if [ "$critical" = true ]; then
            print_error "Критическая ошибка. Прерывание."
            exit 1
        fi
        return 1
    fi
}

# =============== 3. ПРОВЕРКА ПРАВ ===============
if [ "$(id -u)" = "0" ] && [ -z "${SUDO_USER:-}" ]; then
    print_error "Запускайте от обычного пользователя с sudo!"
    exit 1
fi

print_header "🚀 INFRASTRUCTURE v12.0.0 (ФИНАЛЬНАЯ АБСОЛЮТНАЯ С QUADLET)"
print_info "User: $CURRENT_USER | UID: $CURRENT_UID | IP: $SERVER_IP"

# =============== 4. ДИРЕКТОРИИ ===============
print_step "Создание структуры"

INFRA_DIR="$CURRENT_HOME/infra"
VOLUMES_DIR="$INFRA_DIR/volumes"
BIN_DIR="$INFRA_DIR/bin"
LOGS_DIR="$INFRA_DIR/logs"
BACKUP_DIR="$INFRA_DIR/backups"
CERT_DIR="$INFRA_DIR/certs"
FAUCET_DIR="$INFRA_DIR/faucet"
NPM_DIR="$INFRA_DIR/nginx-proxy-manager"
QUADLET_USER_DIR="$CURRENT_HOME/.config/containers/systemd"
QUADLET_SYSTEM_DIR="/etc/containers/systemd"

USER_DIRS=(
    "$INFRA_DIR" "$VOLUMES_DIR" "$BIN_DIR" "$LOGS_DIR" "$BACKUP_DIR"
    "$BACKUP_DIR/cache" "$BACKUP_DIR/snapshots" "$CERT_DIR"
    "$VOLUMES_DIR/gitea" "$VOLUMES_DIR/torrserver" "$VOLUMES_DIR/homepage/config"
    "$FAUCET_DIR"/{data,config}
    "$NPM_DIR"/{data,letsencrypt}
    "$QUADLET_USER_DIR"
)

SYSTEM_DIRS=(
    "$QUADLET_SYSTEM_DIR"
    "/var/lib/gitea-runner" "/var/lib/netbird" "/var/lib/rest-server"
    "/var/lib/passbolt/database" "/var/lib/passbolt/gpg" "/var/lib/passbolt/jwt"
    "/var/lib/backrest/data" "/var/lib/backrest/config" "/var/lib/backrest/cache"
)

for dir in "${USER_DIRS[@]}"; do
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        chown "$CURRENT_USER:$CURRENT_USER" "$dir"
        chmod 755 "$dir"
    fi
done

for dir in "${SYSTEM_DIRS[@]}"; do
    sudo mkdir -p "$dir"
    sudo chown "$CURRENT_USER:$CURRENT_USER" "$dir" 2>/dev/null || true
done

print_success "Директории созданы"

# =============== 5. BOOTSTRAP ===============
print_step "Подготовка системы"

if [ ! -f "$INFRA_DIR/.bootstrap_done" ]; then
    print_info "Настройка системы (это займёт несколько минут)..."

    RAM_MB=$(free -m | awk '/^Mem:/ {print $2}')
    SWAP_MB=$((RAM_MB * 2))
    [ $SWAP_MB -gt 8192 ] && SWAP_MB=8192

    sudo bash -c "
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq >/dev/null 2>&1
        apt-get upgrade -y -qq >/dev/null 2>&1 || true
        
        # Установка пакетов
        apt-get install -y -qq uidmap slirp4netns fuse-overlayfs curl wget \
            openssl ufw fail2ban apache2-utils argon2 jq podman podman-docker \
            >/dev/null 2>&1 || true

        # Swap
        if [ ! -f /swapfile ] && [ \$(free | grep -c Swap) -eq 0 ] || [ \$(free | awk '/^Swap:/ {print \$2}') -eq 0 ]; then
            fallocate -l ${SWAP_MB}M /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=${SWAP_MB} 2>/dev/null
            chmod 600 /swapfile
            mkswap /swapfile >/dev/null 2>&1
            swapon /swapfile >/dev/null 2>&1
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
            sysctl vm.swappiness=10 >/dev/null 2>&1
            echo 'vm.swappiness=10' >> /etc/sysctl.conf
        fi

        # BBR
        if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
            echo 'net.core.default_qdisc=fq' >> /etc/sysctl.conf
            echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.conf
            sysctl -p >/dev/null 2>&1
        fi

        # subuid/subgid
        if ! grep -q '$CURRENT_USER:' /etc/subuid 2>/dev/null; then
            usermod --add-subuids 100000-165535 --add-subgids 100000-165535 '$CURRENT_USER' 2>/dev/null || true
        fi

        # UFW
        sed -i 's/DEFAULT_FORWARD_POLICY=\"DROP\"/DEFAULT_FORWARD_POLICY=\"ACCEPT\"/' /etc/default/ufw 2>/dev/null
        ufw --force reset >/dev/null 2>&1
        ufw default deny incoming >/dev/null 2>&1
        ufw default allow outgoing >/dev/null 2>&1
        ufw default allow routed >/dev/null 2>&1
        
        # Открываем порты
        ufw allow 22/tcp >/dev/null 2>&1      # SSH
        ufw allow 80/tcp >/dev/null 2>&1      # HTTP
        ufw allow 443/tcp >/dev/null 2>&1     # HTTPS
        ufw allow 81/tcp >/dev/null 2>&1      # NPM Admin
        ufw allow 3000/tcp >/dev/null 2>&1    # Gitea
        ufw allow 2222/tcp >/dev/null 2>&1    # Gitea SSH
        ufw allow 3001/tcp >/dev/null 2>&1    # Homepage
        ufw allow 8090/tcp >/dev/null 2>&1    # TorrServer
        ufw allow 8080/tcp >/dev/null 2>&1    # Passbolt
        ufw allow 8082/tcp >/dev/null 2>&1    # Faucet GUI
        ufw allow 8083/tcp >/dev/null 2>&1    # Faucet MCP
        ufw allow 9898/tcp >/dev/null 2>&1    # Backrest
        ufw allow 8000/tcp >/dev/null 2>&1    # Restic REST
        ufw allow 51820/udp >/dev/null 2>&1   # NetBird
        
        ufw --force enable >/dev/null 2>&1

        # fail2ban
        cat > /etc/fail2ban/jail.local <<'EOFAIL'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
backend = systemd
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
EOFAIL
        systemctl restart fail2ban >/dev/null 2>&1 || true
        systemctl enable fail2ban >/dev/null 2>&1 || true
    "

    # Настройка registries.conf для Podman (ВАЖНО ДЛЯ QUADLET)
    sudo tee /etc/containers/registries.conf > /dev/null <<EOF
unqualified-search-registries = ["docker.io", "quay.io", "registry.fedoraproject.org"]

[[registry]]
prefix = "docker.io"
location = "docker.io"

[[registry.mirror]]
location = "mirror.gcr.io"
[[registry.mirror]]
location = "docker-mirror.rancher.io"
EOF

    # Проверка Quadlet
    if [ -f "/usr/libexec/podman/quadlet" ]; then
        if [ ! -L "/usr/lib/systemd/system-generators/podman-system-generator" ]; then
            sudo ln -sf /usr/libexec/podman/quadlet /usr/lib/systemd/system-generators/podman-system-generator
        fi
        print_success "Quadlet настроен"
    else
        print_warning "Quadlet не найден, но podman-docker должен его установить"
    fi

    sudo systemctl enable --now podman.socket >/dev/null 2>&1 || true
    sudo loginctl enable-linger "$CURRENT_USER" 2>/dev/null || true

    # Включаем автообновление для Quadlet
    systemctl --user enable podman-auto-update.timer 2>/dev/null || true
    systemctl --user start podman-auto-update.timer 2>/dev/null || true
    sudo systemctl enable podman-auto-update.timer 2>/dev/null || true
    sudo systemctl start podman-auto-update.timer 2>/dev/null || true

    touch "$INFRA_DIR/.bootstrap_done"
    print_success "Система настроена"
else
    print_info "Bootstrap уже выполнен"
fi

# =============== 6. mkcert ===============
print_step "Настройка локального HTTPS"

if ! command -v mkcert &> /dev/null; then
    step "Загрузка mkcert" "
        wget -qO /tmp/mkcert https://github.com/FiloSottile/mkcert/releases/download/v1.4.4/mkcert-v1.4.4-linux-amd64
        chmod +x /tmp/mkcert
        sudo mv /tmp/mkcert /usr/local/bin/mkcert
    " true
fi

step "Установка локального CA" "mkcert -install" true
step "Генерация сертификатов" "
    mkcert -key-file \"$CERT_DIR/lab-key.pem\" \
           -cert-file \"$CERT_DIR/lab-cert.pem\" \
           localhost 127.0.0.1 $SERVER_IP \
           passbolt.lab git.lab backup.lab home.lab torrent.lab keys.lab \
           $(hostname) $(hostname).local
" true

print_success "SSL сертификаты созданы"

# =============== 7. CLI ===============
print_step "Установка CLI"

cat > "$BIN_DIR/infra" <<'ENDOFCLI'
#!/bin/bash
INFRA_DIR="$HOME/infra"
SERVER_IP=$(hostname -I | awk '{print $1}')

# Цвета
NEON_CYAN="\e[38;5;51m"; NEON_GREEN="\e[38;5;48m"; NEON_YELLOW="\e[38;5;220m"
NEON_RED="\e[38;5;196m"; NEON_PURPLE="\e[38;5;135m"; NEON_BLUE="\e[38;5;39m"
SOFT_WHITE="\e[38;5;255m"; MUTED_GRAY="\e[38;5;245m"; DIM_GRAY="\e[38;5;240m"
BOLD="\e[1m"; RESET="\e[0m"

ICON_OK="${NEON_GREEN}●${RESET}"; ICON_FAIL="${NEON_RED}●${RESET}"
ICON_WARN="${NEON_YELLOW}●${RESET}"; ICON_INFO="${NEON_BLUE}●${RESET}"
ICON_ARROW="▸"

get_status() {
    local name=$1 type=$2 user=$3
    case $type in
        service)
            if [ "$user" = "root" ]; then
                systemctl is-active --quiet "$name" 2>/dev/null && echo "active" || echo "inactive"
            else
                systemctl --user is-active --quiet "$name" 2>/dev/null && echo "active" || echo "inactive"
            fi
            ;;
        container)
            local runtime="podman"
            [ "$user" = "root" ] && runtime="sudo podman"
            local container_name="$name"
            [ "$user" != "root" ] && container_name="systemd-$name"
            
            if $runtime ps --format "{{.Names}}" 2>/dev/null | grep -q "^$container_name$"; then
                echo "running"
            elif $runtime ps -a --format "{{.Names}}" 2>/dev/null | grep -q "^$container_name$"; then
                echo "stopped"
            else
                echo "not_created"
            fi
            ;;
    esac
}

format_status() {
    case $1 in
        active|running) echo -e "${ICON_OK} ${NEON_GREEN}$1${RESET}" ;;
        inactive|stopped) echo -e "${ICON_FAIL} ${NEON_RED}$1${RESET}" ;;
        *) echo -e "${DIM_GRAY}● not created${RESET}" ;;
    esac
}

check_url() {
    local url=$1
    if curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "$url" 2>/dev/null | grep -q "200\|302\|401\|403"; then
        echo -e "${NEON_GREEN}✓${RESET}"
    else
        echo -e "${NEON_RED}✗${RESET}"
    fi
}

status_cmd() {
    clear
    echo -e "${NEON_CYAN}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${NEON_CYAN}║${RESET} ${BOLD}${SOFT_WHITE}INFRA STATUS v12.0.0${RESET}                           ${NEON_CYAN}║${RESET}"
    echo -e "${NEON_CYAN}╚══════════════════════════════════════════════════════════╝${RESET}"

    declare -A services=(
        [gitea]="user:https://git.lab"
        [torrserver]="user:https://torrent.lab"
        [homepage]="user:https://home.lab"
        [gitea-runner]="root:"
        [netbird]="root:"
        [nginx-proxy-manager]="root:http://$SERVER_IP:81"
        [faucet]="root:https://keys.lab"
        [rest-server]="root:http://$SERVER_IP:8000"
        [passbolt]="root:https://passbolt.lab"
        [backrest]="root:https://backup.lab"
    )

    declare -A sections=(
        ["Rootless Services"]="gitea torrserver homepage"
        ["Rootful Services"]="gitea-runner netbird nginx-proxy-manager faucet"
        ["Backup & Security"]="rest-server passbolt backrest"
    )

    for section in "Rootless Services" "Rootful Services" "Backup & Security"; do
        echo -e "\n${NEON_PURPLE}${ICON_ARROW}${RESET} ${BOLD}$section${RESET}"
        echo -e "${DIM_GRAY}────────────────────────────────────────────────────────${RESET}"
        
        for svc in ${sections[$section]}; do
            IFS=':' read -r user url <<< "${services[$svc]}"
            svc_status=$(format_status "$(get_status $svc service $user)")
            ctr_status=$(format_status "$(get_status $svc container $user)")
            printf "  ${DIM_GRAY}%-18s${RESET} %s %s\n" "$svc" "$svc_status" "$ctr_status"
            if [ -n "$url" ]; then
                printf "        ${NEON_CYAN}↗${RESET} ${MUTED_GRAY}%s${RESET} %s\n" "$url" "$(check_url "$url")"
            fi
        done
    done

    # NetBird IP
    if sudo podman ps | grep -q netbird; then
        NB_IP=$(sudo podman exec netbird ip addr show wt0 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1)
        if [ -n "$NB_IP" ]; then
            echo -e "\n${NEON_PURPLE}${ICON_ARROW}${RESET} ${BOLD}NetBird VPN${RESET}"
            echo -e "${DIM_GRAY}────────────────────────────────────────────────────────${RESET}"
            echo -e "        ${NEON_CYAN}↗${RESET} ${MUTED_GRAY}VPN IP: $NB_IP${RESET}"
        fi
    fi

    # Ресурсы
    echo -e "\n${NEON_PURPLE}${ICON_ARROW}${RESET} ${BOLD}Resources${RESET}"
    echo -e "${DIM_GRAY}────────────────────────────────────────────────────────${RESET}"
    printf "  ${DIM_GRAY}%-12s${RESET} ${SOFT_WHITE}%s${RESET}\n" "Disk" "$(df -h "$INFRA_DIR" 2>/dev/null | tail -1 | awk '{print $3 "/" $2 " (" $5 ")"}')"
    printf "  ${DIM_GRAY}%-12s${RESET} ${SOFT_WHITE}%s${RESET}\n" "Memory" "$(free -h 2>/dev/null | awk '/^Mem:/ {print $3 "/" $2}')"
    printf "  ${DIM_GRAY}%-12s${RESET} ${SOFT_WHITE}user: %d, system: %d${RESET}\n" "Containers" "$(podman ps -q 2>/dev/null | wc -l)" "$(sudo podman ps -q 2>/dev/null | wc -l)"

    echo -e "\n${DIM_GRAY}────────────────────────────────────────────────────────${RESET}"
    echo -e "  ${ICON_OK} running  ${ICON_FAIL} stopped  ${NEON_CYAN}↗${RESET} URL ${NEON_GREEN}✓${RESET} доступен ${NEON_RED}✗${RESET} недоступен"
    echo -e "  ${MUTED_GRAY}Commands: ${NEON_CYAN}status${RESET}|${NEON_CYAN}start${RESET}|${NEON_CYAN}stop${RESET}|${NEON_CYAN}restart${RESET}|${NEON_CYAN}logs${RESET}|${NEON_CYAN}backup${RESET}|${NEON_CYAN}clear${RESET}"
}

backup_cmd() {
    BACKUP_DIR="$INFRA_DIR/backups/snapshots"
    mkdir -p "$BACKUP_DIR"
    backup_time=$(date +%Y%m%d-%H%M%S)
    SNAPSHOT="$BACKUP_DIR/infra-$backup_time.tar.gz"
    echo -e "${NEON_CYAN}▸ Создание бэкапа...${RESET}"
    if podman run --rm -v "$INFRA_DIR/volumes:/data:ro" -v "$BACKUP_DIR:/backup:Z" docker.io/library/alpine:latest tar -czf "/backup/$(basename $SNAPSHOT)" -C /data . 2>/dev/null; then
        sudo chown $USER:$USER "$SNAPSHOT" 2>/dev/null
        size=$(du -h "$SNAPSHOT" 2>/dev/null | cut -f1)
        echo -e "  ${ICON_OK} Бэкап создан: $(basename $SNAPSHOT) ($size)"
    else
        echo -e "  ${ICON_WARN} Ошибка создания бэкапа"
    fi
}

clear_cmd() {
    echo -e "${NEON_RED}▸ ПОЛНОЕ УДАЛЕНИЕ ИНФРАСТРУКТУРЫ${RESET}"
    read -rp "  Вы уверены? Все данные будут удалены [yes/N]: " CONFIRM
    [ "$CONFIRM" = "yes" ] || exit 0

    echo -e "  ${NEON_YELLOW}▸ Остановка сервисов...${RESET}"
    systemctl --user stop gitea torrserver homepage 2>/dev/null
    sudo systemctl stop gitea-runner netbird rest-server passbolt backrest nginx-proxy-manager faucet 2>/dev/null

    echo -e "  ${NEON_YELLOW}▸ Удаление контейнеров...${RESET}"
    podman rm -f systemd-gitea systemd-torrserver systemd-homepage 2>/dev/null
    sudo podman rm -f gitea-runner netbird rest-server passbolt backrest nginx-proxy-manager faucet 2>/dev/null

    echo -e "  ${NEON_YELLOW}▸ Удаление Quadlet файлов...${RESET}"
    rm -f ~/.config/containers/systemd/{gitea,torrserver,homepage}.container
    sudo rm -f /etc/containers/systemd/{gitea-runner,netbird,rest-server,passbolt,backrest,nginx-proxy-manager,faucet}.container

    systemctl --user daemon-reload
    sudo systemctl daemon-reload

    read -rp "  Удалить все данные? [y/N]: " DEL_DATA
    if [[ "$DEL_DATA" =~ ^[Yy]$ ]]; then
        echo -e "  ${NEON_YELLOW}▸ Удаление данных...${RESET}"
        sudo rm -rf "$HOME/infra" /var/lib/gitea-runner /var/lib/netbird /var/lib/rest-server /var/lib/passbolt /var/lib/backrest
    fi

    sudo rm -f /usr/local/bin/infra
    rm -f "$HOME/infra/bin/infra"
    echo -e "\n${NEON_GREEN}${BOLD}╔════════════════════════════════════════════════╗${RESET}"
    echo -e "${NEON_GREEN}${BOLD}║        ИНФРАСТРУКТУРА ПОЛНОСТЬЮ УДАЛЕНА        ║${RESET}"
    echo -e "${NEON_GREEN}${BOLD}╚════════════════════════════════════════════════╝${RESET}"
}

case "${1:-status}" in
    status) status_cmd ;;
    logs) 
        case "$2" in
            netbird|gitea-runner|rest-server|passbolt|backrest|nginx-proxy-manager|faucet) sudo journalctl -u "$2" -f ;;
            gitea|torrserver|homepage) journalctl --user -u "$2" -f ;;
            *) echo "Usage: infra logs <service>"; exit 1 ;;
        esac
        ;;
    stop)
        echo -e "${NEON_YELLOW}▸ Остановка сервисов...${RESET}"
        systemctl --user stop gitea torrserver homepage 2>/dev/null
        sudo systemctl stop gitea-runner netbird rest-server passbolt backrest nginx-proxy-manager faucet 2>/dev/null
        echo -e "  ${ICON_OK} Services stopped"
        ;;
    start)
        echo -e "${NEON_GREEN}▸ Запуск сервисов...${RESET}"
        systemctl --user start gitea torrserver homepage 2>/dev/null
        sudo systemctl start gitea-runner netbird rest-server passbolt backrest nginx-proxy-manager faucet 2>/dev/null
        echo -e "  ${ICON_OK} Services started"
        ;;
    restart)
        echo -e "${NEON_CYAN}▸ Перезапуск $2...${RESET}"
        case "$2" in
            netbird|gitea-runner|rest-server|passbolt|backrest|nginx-proxy-manager|faucet) sudo systemctl restart "$2" ;;
            gitea|torrserver|homepage) systemctl --user restart "$2" ;;
            *) echo "Unknown service: $2"; exit 1 ;;
        esac
        echo -e "  ${ICON_OK} $2 restarted"
        ;;
    backup) backup_cmd ;;
    clear) clear_cmd ;;
    *) echo "Использование: infra {status|start|stop|restart|logs|backup|clear}" ;;
esac
ENDOFCLI

chmod +x "$BIN_DIR/infra"
sudo ln -sf "$BIN_DIR/infra" /usr/local/bin/infra 2>/dev/null || true
print_success "CLI установлен"

# =============== 8. TORRSERVER (rootless QUADLET) ===============
print_step "Создание TorrServer (Quadlet)"

cat > "$QUADLET_USER_DIR/torrserver.container" <<EOF
[Unit]
Description=TorrServer Container
After=network-online.target
Wants=podman-auto-update.service

[Container]
Label=io.containers.autoupdate=registry
Image=ghcr.io/yourok/torrserver:latest
Volume=$CURRENT_HOME/infra/volumes/torrserver:/app/z:Z
PublishPort=8090:8090

[Service]
Restart=always
Type=notify
NotifyAccess=all

[Install]
WantedBy=default.target
EOF

chown $CURRENT_USER:$CURRENT_USER "$QUADLET_USER_DIR/torrserver.container"
systemctl --user daemon-reload
systemctl --user start torrserver.service
print_success "TorrServer запущен"
print_url "http://$SERVER_IP:8090"

# =============== 9. GITEA (rootless QUADLET) ===============
print_step "Создание Gitea (Quadlet)"

cat > "$QUADLET_USER_DIR/gitea.container" <<EOF
[Unit]
Description=Gitea Container
After=network-online.target
Wants=podman-auto-update.service

[Container]
Label=io.containers.autoupdate=registry
Image=docker.io/gitea/gitea:latest
Volume=$CURRENT_HOME/infra/volumes/gitea:/data:Z
PublishPort=3000:3000
PublishPort=2222:22
Environment=GITEA__server__ROOT_URL=http://$SERVER_IP:3000/
Environment=GITEA__actions__ENABLED=true
Environment=GITEA__repository_upload__ENABLED=true

[Service]
Restart=always
TimeoutStopSec=60
Type=notify
NotifyAccess=all

[Install]
WantedBy=default.target
EOF

chown $CURRENT_USER:$CURRENT_USER "$QUADLET_USER_DIR/gitea.container"
systemctl --user daemon-reload
systemctl --user start gitea.service
print_success "Gitea запущена"
print_url "http://$SERVER_IP:3000"

# =============== 10. GITEA RUNNER (rootful QUADLET) ===============
print_step "Настройка Gitea Runner"

print_info "Ожидание 60 секунд для инициализации Gitea..."
sleep 60

if curl -sf --max-time 5 "http://$SERVER_IP:3000/api/v1/version" >/dev/null 2>&1; then
    print_success "Gitea API доступен"
    echo ""
    print_info "🔑 Для регистрации Runner'а нужен токен"
    print_info "1. Открой в браузере: ${NEON_CYAN}http://$SERVER_IP:3000/-/admin/actions/runners${RESET}"
    print_info "2. Нажми 'Create new runner'"
    print_info "3. Скопируй токен"
    echo ""
    
    read -rp "  Registration Token: " RUNNER_TOKEN
    
    if [ -n "$RUNNER_TOKEN" ]; then
        sudo tee "$QUADLET_SYSTEM_DIR/gitea-runner.container" > /dev/null <<EOF
[Unit]
Description=Gitea Runner
After=network-online.target gitea.service
Wants=podman-auto-update.service

[Container]
Image=docker.io/gitea/act_runner:nightly
ContainerName=gitea-runner
Volume=/var/run/docker.sock:/var/run/docker.sock:Z
Volume=/var/lib/gitea-runner:/data:Z
Environment=GITEA_INSTANCE_URL=http://$SERVER_IP:3000
Environment=GITEA_RUNNER_REGISTRATION_TOKEN=$RUNNER_TOKEN
Environment=GITEA_RUNNER_NAME=runner-$(hostname | cut -d. -f1)
AddCapability=SYS_ADMIN
AddDevice=/dev/fuse

[Service]
Restart=always
TimeoutStopSec=60
Type=notify
NotifyAccess=all

[Install]
WantedBy=multi-user.target
EOF

        sudo chmod 644 "$QUADLET_SYSTEM_DIR/gitea-runner.container"
        sudo systemctl daemon-reload
        sudo systemctl start gitea-runner.service
        print_success "Gitea Runner запущен"
    fi
else
    print_warning "Gitea API не доступен. Runner можно настроить позже"
fi

# =============== 11. NETBIRD (rootful QUADLET) ===============
print_step "Настройка NetBird"
echo ""
print_info "🌐 Для подключения к VPN нужен Setup Key"
print_info "1. Зарегистрируйся на https://app.netbird.io/"
print_info "2. Создай Setup Key в разделе Setup Keys"
print_info "3. Введи его ниже (или Enter чтобы пропустить)"
echo ""
read -rp "  NetBird Setup Key: " NB_KEY

if [ -n "$NB_KEY" ]; then
    sudo mkdir -p /var/lib/netbird
    
    sudo tee "$QUADLET_SYSTEM_DIR/netbird.container" > /dev/null <<EOF
[Unit]
Description=NetBird VPN Container
After=network-online.target
Wants=podman-auto-update.service

[Container]
Image=docker.io/netbirdio/netbird:latest
ContainerName=netbird
Network=host
AddDevice=/dev/net/tun
Volume=/var/lib/netbird:/etc/netbird:Z
Environment=NB_SETUP_KEY=$NB_KEY
Environment=NB_MANAGEMENT_URL=https://api.netbird.io:443
SecurityLabelDisable=true
AddCapability=ALL

[Service]
Restart=always
Type=notify
NotifyAccess=all

[Install]
WantedBy=multi-user.target
EOF

    sudo chmod 644 "$QUADLET_SYSTEM_DIR/netbird.container"
    sudo systemctl daemon-reload
    sudo systemctl start netbird.service
    print_success "NetBird запущен"
else
    print_info "NetBird пропущен"
fi

# =============== 12. RESTIC REST SERVER (rootful QUADLET) ===============
print_step "Настройка Restic REST сервера"

if [ ! -f "/var/lib/rest-server/.htpasswd" ]; then
    REST_PASS=$(openssl rand -base64 24 | tr -d "=+/" | cut -c1-20)
    echo "$REST_PASS" | sudo tee /var/lib/rest-server/.restic_pass > /dev/null
    sudo htpasswd -B -b -c /var/lib/rest-server/.htpasswd restic "$REST_PASS" >/dev/null 2>&1
    sudo chmod 600 /var/lib/rest-server/.htpasswd /var/lib/rest-server/.restic_pass
    print_info "Пароль restic: $REST_PASS"
fi

sudo tee "$QUADLET_SYSTEM_DIR/rest-server.container" > /dev/null <<EOF
[Unit]
Description=Restic REST Server
After=network-online.target
Wants=podman-auto-update.service

[Container]
Image=docker.io/restic/rest-server:latest
ContainerName=rest-server
Volume=/var/lib/rest-server:/data:Z
PublishPort=8000:8000
Exec=rest-server --path /data --htpasswd-file /data/.htpasswd --append-only --listen :8000

[Service]
Restart=always
Type=notify
NotifyAccess=all

[Install]
WantedBy=multi-user.target
EOF

sudo chmod 644 "$QUADLET_SYSTEM_DIR/rest-server.container"
sudo systemctl daemon-reload
sudo systemctl start rest-server.service
print_success "Restic REST сервер запущен"
print_url "http://$SERVER_IP:8000"

# =============== 13. PASSBOLT (rootful QUADLET) ===============
print_step "Настройка Passbolt"

# Генерация GPG ключей
mkdir -p /tmp/passbolt-gpg
chmod 700 /tmp/passbolt-gpg

cat > /tmp/gpg-batch <<EOF
%no-protection
Key-Type: RSA
Key-Length: 4096
Name-Real: Passbolt
Name-Email: passbolt@devops.lab
Expire-Date: 0
%commit
EOF

gpg --homedir /tmp/passbolt-gpg --batch --gen-key /tmp/gpg-batch

# Экспорт ключей
gpg --homedir /tmp/passbolt-gpg --export --armor passbolt@devops.lab | sudo tee /var/lib/passbolt/gpg/public.key > /dev/null
gpg --homedir /tmp/passbolt-gpg --export-secret-key --armor passbolt@devops.lab | sudo tee /var/lib/passbolt/gpg/private.key > /dev/null

# Получение fingerprint
FINGERPRINT=$(gpg --homedir /tmp/passbolt-gpg --list-keys --with-colons | grep '^fpr:' | head -1 | cut -d: -f10)

# Права на ключи
sudo chmod 644 /var/lib/passbolt/gpg/public.key
sudo chmod 600 /var/lib/passbolt/gpg/private.key
sudo chown -R $CURRENT_USER:$CURRENT_USER /var/lib/passbolt/gpg

# JWT ключ
openssl rand -base64 32 | sudo tee /var/lib/passbolt/jwt/jwt.key > /dev/null
sudo chmod 600 /var/lib/passbolt/jwt/jwt.key
sudo chown $CURRENT_USER:$CURRENT_USER /var/lib/passbolt/jwt/jwt.key

# Пароль БД
PASSBOLT_DB_PASS=$(openssl rand -base64 24 | tr -d "=+/" | cut -c1-20)
echo "$PASSBOLT_DB_PASS" | sudo tee /var/lib/passbolt/db_password.txt > /dev/null
sudo chmod 600 /var/lib/passbolt/db_password.txt

# Конфиг Passbolt
sudo tee /var/lib/passbolt/config.php > /dev/null <<EOF
<?php
return [
    'App' => [
        'fullBaseUrl' => 'https://passbolt.lab',
        'registration' => ['public' => false]
    ],
    'Database' => [
        'host' => 'localhost',
        'port' => '3306',
        'username' => 'passbolt',
        'password' => '$PASSBOLT_DB_PASS',
        'database' => 'passbolt'
    ],
    'passbolt' => [
        'gpg' => [
            'serverKey' => [
                'fingerprint' => '$FINGERPRINT',
                'public' => '/etc/passbolt/gpg/public.key',
                'private' => '/etc/passbolt/gpg/private.key'
            ]
        ],
        'jwt' => [
            'key' => file_get_contents('/etc/passbolt/jwt/jwt.key')
        ]
    ]
];
EOF

sudo chmod 644 /var/lib/passbolt/config.php
sudo chown $CURRENT_USER:$CURRENT_USER /var/lib/passbolt/config.php

# Quadlet файл
sudo tee "$QUADLET_SYSTEM_DIR/passbolt.container" > /dev/null <<EOF
[Unit]
Description=Passbolt Password Manager
After=network-online.target
Wants=podman-auto-update.service

[Container]
Image=docker.io/passbolt/passbolt:latest
ContainerName=passbolt
Volume=/var/lib/passbolt/database:/var/lib/mysql:Z
Volume=/var/lib/passbolt/gpg:/etc/passbolt/gpg:Z
Volume=/var/lib/passbolt/jwt:/etc/passbolt/jwt:Z
Volume=/var/lib/passbolt/config.php:/etc/passbolt/passbolt.php:Z
PublishPort=8080:80

[Service]
Restart=always
Type=notify
NotifyAccess=all

[Install]
WantedBy=multi-user.target
EOF

sudo chmod 644 "$QUADLET_SYSTEM_DIR/passbolt.container"
sudo systemctl daemon-reload
sudo systemctl start passbolt.service

# Очистка
rm -rf /tmp/passbolt-gpg /tmp/gpg-batch

print_success "Passbolt запущен"
print_url "http://$SERVER_IP:8080"
print_info "Пароль БД: $PASSBOLT_DB_PASS"

# =============== 14. BACKREST (rootful QUADLET) ===============
print_step "Настройка Backrest"

sudo chown -R 1000:1000 /var/lib/backrest 2>/dev/null || true

if [ -f "/var/lib/rest-server/.restic_pass" ]; then
    RESTIC_PASS=$(sudo cat /var/lib/rest-server/.restic_pass)
    sudo tee /var/lib/backrest/config/restic.env > /dev/null <<EOF
RESTIC_REPOSITORY=rest:http://restic:$RESTIC_PASS@localhost:8000/windows-backup
RESTIC_PASSWORD=$RESTIC_PASS
EOF
    sudo chmod 600 /var/lib/backrest/config/restic.env
fi

sudo tee "$QUADLET_SYSTEM_DIR/backrest.container" > /dev/null <<EOF
[Unit]
Description=Backrest WebUI for Restic
After=network-online.target rest-server.service
Wants=podman-auto-update.service

[Container]
Image=ghcr.io/garethgeorge/backrest:latest
ContainerName=backrest
Volume=/var/lib/backrest/data:/data:Z
Volume=/var/lib/backrest/config:/config:Z
Volume=/var/lib/backrest/cache:/cache:Z
Volume=$VOLUMES_DIR:/userdata:ro,Z
Environment=BACKREST_DATA=/data
Environment=BACKREST_CONFIG=/config/config.json
Environment=XDG_CACHE_HOME=/cache
Environment=BACKREST_PORT=:9898
PublishPort=9898:9898

[Service]
Restart=always
Type=notify
NotifyAccess=all

[Install]
WantedBy=multi-user.target
EOF

sudo chmod 644 "$QUADLET_SYSTEM_DIR/backrest.container"
sudo systemctl daemon-reload
sudo systemctl start backrest.service
print_success "Backrest запущен"
print_url "http://$SERVER_IP:9898"

# =============== 15. FAUCET (rootful QUADLET) ===============
print_step "Настройка Faucet (MCP Server + GUI)"

FAUCET_PASS=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)
FAUCET_JWT=$(openssl rand -base64 32)

# Создание конфига
cat > "$FAUCET_DIR/config/faucet.yaml" <<EOF
database:
  driver: sqlite
  dsn: /data/faucet.db

auth:
  enabled: true
  jwt_secret: ${FAUCET_JWT}
  
admin:
  enabled: true
  users:
    - username: admin
      password: ${FAUCET_PASS}
EOF

chmod 644 "$FAUCET_DIR/config/faucet.yaml"
touch "$FAUCET_DIR/data/faucet.db"
chmod 666 "$FAUCET_DIR/data/faucet.db"
echo "$FAUCET_PASS" > "$FAUCET_DIR/admin_password.txt"
chmod 600 "$FAUCET_DIR/admin_password.txt"

# Quadlet файл
sudo tee "$QUADLET_SYSTEM_DIR/faucet.container" > /dev/null <<EOF
[Unit]
Description=Faucet MCP Server with GUI
After=network-online.target
Wants=podman-auto-update.service

[Container]
Image=docker.io/faucetdb/faucet:latest
ContainerName=faucet
Volume=$FAUCET_DIR/data:/data:Z
Volume=$FAUCET_DIR/config:/config:Z
PublishPort=8082:8080
PublishPort=8083:8081
Environment=FAUCET_CONFIG=/config/faucet.yaml

[Service]
Restart=always
Type=notify
NotifyAccess=all

[Install]
WantedBy=multi-user.target
EOF

sudo chmod 644 "$QUADLET_SYSTEM_DIR/faucet.container"
sudo systemctl daemon-reload
sudo systemctl start faucet.service

print_success "Faucet запущен"
print_url "http://$SERVER_IP:8082"
print_info "Логин: admin / Пароль: $FAUCET_PASS"

# =============== 16. NGINX PROXY MANAGER (rootful QUADLET) ===============
print_step "Настройка Nginx Proxy Manager"

sudo tee "$QUADLET_SYSTEM_DIR/nginx-proxy-manager.container" > /dev/null <<EOF
[Unit]
Description=Nginx Proxy Manager
After=network-online.target
Wants=podman-auto-update.service

[Container]
Image=docker.io/jc21/nginx-proxy-manager:latest
ContainerName=nginx-proxy-manager
Volume=$NPM_DIR/data:/data:Z
Volume=$NPM_DIR/letsencrypt:/etc/letsencrypt:Z
PublishPort=80:80
PublishPort=443:443
PublishPort=81:81

[Service]
Restart=always
Type=notify
NotifyAccess=all

[Install]
WantedBy=multi-user.target
EOF

sudo chmod 644 "$QUADLET_SYSTEM_DIR/nginx-proxy-manager.container"
sudo systemctl daemon-reload
sudo systemctl start nginx-proxy-manager.service

print_success "Nginx Proxy Manager запущен"
print_url "http://$SERVER_IP:81"
print_info "Логин: admin@example.com / Пароль: changeme"

# =============== 17. HOMEPAGE (rootless QUADLET) ===============
print_step "Настройка Homepage"

echo ""
print_info "🌤 Хочешь видеть погоду на дашборде?"
print_info "1. Зарегистрируйся на https://home.openweathermap.org/users/sign_up"
print_info "2. Получи бесплатный API ключ"
print_info "3. Введи его ниже (или Enter чтобы пропустить)"
echo ""
read -rp "  OpenWeatherMap API ключ: " WEATHER_KEY

HOMEPAGE_CONFIG_DIR="$VOLUMES_DIR/homepage/config"
mkdir -p "$HOMEPAGE_CONFIG_DIR"

if [ -n "$WEATHER_KEY" ]; then
    WEATHER_CONFIG="
  - name: \"Погода в вашем городе\"
    type: \"openweathermap\"
    apiKey: \"$WEATHER_KEY\"
    units: \"metric\"
    city: \"YourCity\"
    country: \"RU\""
else
    WEATHER_CONFIG=""
fi

# Конфиг Homepage
cat > "$HOMEPAGE_CONFIG_DIR/settings.yaml" <<EOF
---
title: "DevOps Lab Dashboard"
theme: dark
color: slate
headerStyle: clean
hideVersion: false
useEqualHeights: true
statusStyle: "dot"
statusPosition: "bottom"
search:
  provider: duckduckgo
  target: _blank
information:
$WEATHER_CONFIG
EOF

cat > "$HOMEPAGE_CONFIG_DIR/services.yaml" <<EOF
---
Инфраструктура:
  - Passbolt:
      icon: https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/passbolt.png
      href: https://passbolt.lab
      description: "Менеджер паролей"
      container: passbolt
  - Faucet:
      icon: https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/faucet.png
      href: https://keys.lab
      description: "API-ключи для AI"
      container: faucet
  - Backrest:
      icon: https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/restic.png
      href: https://backup.lab
      description: "Управление бэкапами"
      container: backrest
  - Gitea:
      icon: https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/gitea.png
      href: https://git.lab
      description: "Git репозиторий"
      container: systemd-gitea
  - TorrServer:
      icon: https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/torrent.png
      href: https://torrent.lab
      description: "Торрент стриминг"
      container: systemd-torrserver

Windows Клиенты:
  - NetBird VPN:
      icon: https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/netbird.png
      href: https://pkgs.netbird.io/windows
      description: "Для доступа из любой точки"
  - Bitwarden Desktop:
      icon: https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/bitwarden.png
      href: https://bitwarden.com/download/
      description: "Клиент для Passbolt"
  - Restic:
      icon: https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/restic.png
      href: https://github.com/restic/restic/releases
      description: "Бэкапы Windows"

Администрирование:
  - Nginx Proxy Manager:
      icon: https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/nginx-proxy-manager.png
      href: http://$SERVER_IP:81
      description: "Reverse proxy GUI"
      container: nginx-proxy-manager
  - NetBird:
      icon: https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/netbird.png
      href: https://app.netbird.io
      description: "VPN управление"
      container: netbird
  - Restic REST:
      icon: https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/restic.png
      href: http://$SERVER_IP:8000
      description: "Хранилище бэкапов"
      container: rest-server
EOF

chown -R $CURRENT_USER:$CURRENT_USER "$HOMEPAGE_CONFIG_DIR"

# Quadlet файл для Homepage
cat > "$QUADLET_USER_DIR/homepage.container" <<EOF
[Unit]
Description=Homepage Dashboard
After=network-online.target
Wants=podman-auto-update.service

[Container]
Label=io.containers.autoupdate=registry
Image=ghcr.io/gethomepage/homepage:latest
ContainerName=homepage
Volume=$HOMEPAGE_CONFIG_DIR:/app/config:Z
Volume=/var/run/docker.sock:/var/run/docker.sock:ro,Z
PublishPort=3001:3000
Environment=PUID=$CURRENT_UID
Environment=PGID=$CURRENT_UID
Environment=HOMEPAGE_ALLOWED_HOSTS=$SERVER_IP:3001,localhost:3001,127.0.0.1:3001,home.lab:3001,$(hostname):3001

[Service]
Restart=always
Type=notify
NotifyAccess=all

[Install]
WantedBy=default.target
EOF

chown $CURRENT_USER:$CURRENT_USER "$QUADLET_USER_DIR/homepage.container"
systemctl --user daemon-reload
systemctl --user start homepage.service

print_success "Homepage запущен"
print_url "http://$SERVER_IP:3001"

# =============== 18. ФИНАЛЬНЫЙ ВЫВОД ===============
print_header "🚀 ИНФРАСТРУКТУРА ПОЛНОСТЬЮ ГОТОВА"

cat <<EOF

${NEON_GREEN}╔══════════════════════════════════════════════════════════╗${RESET}
${NEON_GREEN}║          ДОСТУП ДЛЯ ПЕРВОНАЧАЛЬНОЙ НАСТРОЙКИ             ║${RESET}
${NEON_GREEN}╚══════════════════════════════════════════════════════════╝${RESET}

${NEON_CYAN}🏠 ДАШБОРД И УПРАВЛЕНИЕ${RESET}
  ${NEON_GREEN}●${RESET} Homepage:            ${NEON_CYAN}http://$SERVER_IP:3001${RESET}
  ${NEON_GREEN}●${RESET} Nginx Proxy Manager: ${NEON_CYAN}http://$SERVER_IP:81${RESET} (admin@example.com / changeme)

${NEON_CYAN}🔐 МЕНЕДЖЕРЫ СЕКРЕТОВ${RESET}
  ${NEON_GREEN}●${RESET} Passbolt:            ${NEON_CYAN}http://$SERVER_IP:8080${RESET}
  ${MUTED_GRAY}  └─ Пароль БД: ${NEON_CYAN}$PASSBOLT_DB_PASS${RESET}
  ${NEON_GREEN}●${RESET} Faucet:              ${NEON_CYAN}http://$SERVER_IP:8082${RESET}
  ${MUTED_GRAY}  └─ Логин: admin / Пароль: ${NEON_CYAN}$FAUCET_PASS${RESET}

${NEON_CYAN}📦 РАЗРАБОТКА И БЭКАПЫ${RESET}
  ${NEON_GREEN}●${RESET} Gitea:               ${NEON_CYAN}http://$SERVER_IP:3000${RESET}
  ${NEON_GREEN}●${RESET} Backrest:            ${NEON_CYAN}http://$SERVER_IP:9898${RESET}
  ${NEON_GREEN}●${RESET} Restic REST:         ${NEON_CYAN}http://$SERVER_IP:8000${RESET} (user: restic)

${NEON_CYAN}🎬 МЕДИА${RESET}
  ${NEON_GREEN}●${RESET} TorrServer:          ${NEON_CYAN}http://$SERVER_IP:8090${RESET}

${NEON_CYAN}🪟 WINDOWS КЛИЕНТЫ${RESET}
  ${NEON_GREEN}●${RESET} NetBird:     ${NEON_CYAN}https://pkgs.netbird.io/windows${RESET}
  ${NEON_GREEN}●${RESET} Bitwarden:   ${NEON_CYAN}https://bitwarden.com/download/${RESET}
  ${NEON_GREEN}●${RESET} Restic:      ${NEON_CYAN}https://github.com/restic/restic/releases${RESET}

${NEON_BLUE}📋 СЛЕДУЮЩИЕ ШАГИ${RESET}
  ${NEON_YELLOW}1.${RESET} Зайди в Nginx Proxy Manager (http://$SERVER_IP:81)
  ${NEON_YELLOW}2.${RESET} Добавь proxy hosts для всех доменов (passbolt.lab, git.lab, keys.lab и т.д.)
  ${NEON_YELLOW}3.${RESET} Включи SSL (сертификаты уже созданы в $CERT_DIR)
  ${NEON_YELLOW}4.${RESET} Настрой Passbolt и Faucet через их веб-интерфейсы

${NEON_GREEN}🎉 УПРАВЛЕНИЕ: ${NEON_CYAN}infra status${RESET}
${NEON_GREEN}📋 ЛОГИ:       ${NEON_CYAN}infra logs <service>${RESET}
${NEON_GREEN}💾 БЭКАП:      ${NEON_CYAN}infra backup${RESET}
EOF

# =============== 19. САМОУДАЛЕНИЕ ===============
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
if [ -f "$SCRIPT_PATH" ] && [ "$SCRIPT_PATH" != "$BIN_DIR/infra" ] && [ "$SCRIPT_PATH" != "/usr/local/bin/infra" ]; then
    rm -f "$SCRIPT_PATH"
    print_success "Скрипт удалён"
fi
