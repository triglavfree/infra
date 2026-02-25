#!/bin/bash
set -uo pipefail
# =============================================================================
# INFRASTRUCTURE v11.0.6 (ТЕСТОВАЯ)
# =============================================================================
# Совместная работа команды ❤️
# 
# ✅ Passbolt — менеджер паролей
# ✅ secretctl — API-ключи с Web UI и Windows GUI
# ✅ Backrest — управление бэкапами
# ✅ Gitea + Runner — Git с CI/CD
# ✅ TorrServer — торрент-стриминг
# ✅ Homepage — красивый дашборд с погодой
# ✅ Nginx Proxy Manager — reverse proxy с GUI
# ✅ NetBird VPN — доступ из любой точки
# ✅ Restic REST — хранилище бэкапов
# ✅ mkcert — локальный HTTPS
# =============================================================================

# Цвета
if [ -t 1 ]; then
    ncolors=$(tput colors 2>/dev/null || echo 0)
    if [ $ncolors -ge 256 ]; then
        NEON_CYAN=$(tput setaf 81); NEON_GREEN=$(tput setaf 84)
        NEON_YELLOW=$(tput setaf 220); NEON_RED=$(tput setaf 203)
        NEON_PURPLE=$(tput setaf 141); NEON_BLUE=$(tput setaf 75)
        SOFT_WHITE=$(tput setaf 252); MUTED_GRAY=$(tput setaf 245)
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

print_header() { echo ""; echo -e "${DIM_GRAY}─────────────────────────────────────────${RESET}"; echo -e "${NEON_CYAN}${BOLD}  $1${RESET}"; echo -e "${DIM_GRAY}─────────────────────────────────────────${RESET}"; echo ""; }
print_step() { echo ""; echo -e "${NEON_CYAN}${BOLD}▸${RESET} ${SOFT_WHITE}${BOLD}$1${RESET}"; echo -e "${DIM_GRAY}  $(printf '─%.0s' $(seq 1 40))${RESET}"; }
print_success() { echo -e "  ${NEON_GREEN}✓${RESET} ${SOFT_WHITE}$1${RESET}"; }
print_warning() { echo -e "  ${NEON_YELLOW}⚡${RESET} ${SOFT_WHITE}$1${RESET}"; }
print_error() { echo -e "  ${NEON_RED}✗${RESET} ${BOLD}$1${RESET}" >&2; }
print_info() { echo -e "  ${NEON_BLUE}ℹ${RESET} ${MUTED_GRAY}$1${RESET}"; }
print_url() { echo -e "  ${NEON_CYAN}➜${RESET} ${BOLD}${NEON_CYAN}$1${RESET}"; }

# Функция для пошагового выполнения
step() {
    local msg=$1
    local cmd=$2
    echo -ne "  ${MUTED_GRAY}➜${RESET} $msg... "
    if eval "$cmd" >/dev/null 2>&1; then
        echo -e "${NEON_GREEN}✓${RESET}"
        return 0
    else
        echo -e "${NEON_RED}✗${RESET}"
        return 1
    fi
}

# Проверка прав
if [ "$(id -u)" = "0" ] && [ -z "${SUDO_USER:-}" ]; then
    print_error "Запускайте от обычного пользователя с sudo!"
    exit 1
fi

print_header "🚀 INFRASTRUCTURE v11.0.6 (ТЕСТОВАЯ)"
print_info "User: $CURRENT_USER | UID: $CURRENT_UID | IP: $SERVER_IP"

# =============== ДИРЕКТОРИИ ===============
print_step "Создание структуры"

INFRA_DIR="$CURRENT_HOME/infra"
VOLUMES_DIR="$INFRA_DIR/volumes"
BIN_DIR="$INFRA_DIR/bin"
LOGS_DIR="$INFRA_DIR/logs"
BACKUP_DIR="$INFRA_DIR/backups"
CERT_DIR="$INFRA_DIR/certs"
QUADLET_USER_DIR="$CURRENT_HOME/.config/containers/systemd"
QUADLET_SYSTEM_DIR="/etc/containers/systemd"

USER_DIRS=(
    "$INFRA_DIR" "$VOLUMES_DIR" "$BIN_DIR" "$LOGS_DIR" "$BACKUP_DIR"
    "$BACKUP_DIR/cache" "$BACKUP_DIR/snapshots" "$CERT_DIR"
    "$VOLUMES_DIR/gitea" "$VOLUMES_DIR/torrserver" "$VOLUMES_DIR/homepage/config"
    "$INFRA_DIR/nginx-proxy-manager/data" "$INFRA_DIR/nginx-proxy-manager/letsencrypt"
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
done

print_success "Директории созданы"

# =============== BOOTSTRAP ===============
print_step "Подготовка системы"

if [ ! -f "$INFRA_DIR/.bootstrap_done" ]; then
    print_info "Настройка системы..."

    RAM_MB=$(free -m | awk '/^Mem:/ {print $2}')
    SWAP_MB=$((RAM_MB * 2))
    [ $SWAP_MB -gt 8192 ] && SWAP_MB=8192

    sudo bash -c "
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq >/dev/null 2>&1
        apt-get upgrade -y -qq >/dev/null 2>&1 || true
        apt-get install -y -qq uidmap slirp4netns fuse-overlayfs curl openssl ufw fail2ban apache2-utils argon2 jq wget golang >/dev/null 2>&1 || true

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

        # UFW (ТИХИЙ РЕЖИМ)
        sed -i 's/DEFAULT_FORWARD_POLICY=\"DROP\"/DEFAULT_FORWARD_POLICY=\"ACCEPT\"/' /etc/default/ufw
        ufw --force reset >/dev/null 2>&1
        ufw default deny incoming >/dev/null 2>&1
        ufw default allow outgoing >/dev/null 2>&1
        ufw default allow routed >/dev/null 2>&1
        
        ufw allow 22/tcp comment 'SSH' >/dev/null 2>&1
        ufw allow 3000/tcp comment 'Gitea HTTP' >/dev/null 2>&1
        ufw allow 3001/tcp comment 'Homepage' >/dev/null 2>&1
        ufw allow 2222/tcp comment 'Gitea SSH' >/dev/null 2>&1
        ufw allow 8090/tcp comment 'TorrServer' >/dev/null 2>&1
        ufw allow 8080/tcp comment 'Passbolt' >/dev/null 2>&1
        ufw allow 9898/tcp comment 'Backrest' >/dev/null 2>&1
        ufw allow 8000/tcp comment 'Restic REST' >/dev/null 2>&1
        ufw allow 81/tcp comment 'Nginx Proxy Manager Admin' >/dev/null 2>&1
        ufw allow 80/tcp comment 'HTTP' >/dev/null 2>&1
        ufw allow 443/tcp comment 'HTTPS' >/dev/null 2>&1
        ufw allow 51820/udp comment 'WireGuard/NetBird' >/dev/null 2>&1
        ufw allow 8082/tcp comment 'secretctl Web UI' >/dev/null 2>&1
        
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

    sudo loginctl enable-linger "$CURRENT_USER" 2>/dev/null || true
    touch "$INFRA_DIR/.bootstrap_done"
    print_success "Система настроена"
else
    print_info "Bootstrap уже выполнен"
fi

# =============== mkcert ===============
print_step "Настройка локального HTTPS"

step "Загрузка mkcert" "
    if ! command -v mkcert &> /dev/null; then
        wget -qO /tmp/mkcert https://github.com/FiloSottile/mkcert/releases/download/v1.4.4/mkcert-v1.4.4-linux-amd64
        chmod +x /tmp/mkcert
        sudo mv /tmp/mkcert /usr/local/bin/mkcert
    fi
"

step "Установка локального CA" "mkcert -install"

step "Генерация сертификатов для доменов" "
    mkcert -key-file \"$CERT_DIR/lab-key.pem\" \
           -cert-file \"$CERT_DIR/lab-cert.pem\" \
           localhost 127.0.0.1 $SERVER_IP \
           passbolt.lab git.lab backup.lab home.lab torrent.lab keys.lab \
           $(hostname) $(hostname).local
"

print_success "SSL сертификаты созданы"

# =============== CLI ===============
print_step "Установка CLI"

cat > "$BIN_DIR/infra" <<'ENDOFCLI'
#!/bin/bash
INFRA_DIR="$HOME/infra"
SERVER_IP=$(hostname -I | awk '{print $1}')

# Цвета
NEON_CYAN="\e[36m"; NEON_GREEN="\e[32m"; NEON_YELLOW="\e[33m"
NEON_RED="\e[31m"; NEON_PURPLE="\e[35m"; NEON_BLUE="\e[34m"
SOFT_WHITE="\e[97m"; MUTED_GRAY="\e[90m"; DIM_GRAY="\e[2m"
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

status_cmd() {
    clear
    echo -e "${NEON_CYAN}╔══════════════════════════════════════════════════╗${RESET}"
    echo -e "${NEON_CYAN}║${RESET} ${BOLD}INFRA STATUS v11.0.6${RESET}"
    echo -e "${NEON_CYAN}╚══════════════════════════════════════════════════╝${RESET}"

    declare -A services=(
        [gitea]="user:https://git.lab"
        [torrserver]="user:https://torrent.lab"
        [homepage]="user:https://home.lab"
        [secretctl]="user:https://keys.lab"
        [gitea-runner]="root:"
        [netbird]="root:"
        [nginx-proxy-manager]="root:http://$SERVER_IP:81"
        [rest-server]="root:http://$SERVER_IP:8000"
        [passbolt]="root:https://passbolt.lab"
        [backrest]="root:https://backup.lab"
    )

    declare -A sections=(
        ["Rootless Services"]="gitea torrserver homepage secretctl"
        ["Rootful Services"]="gitea-runner netbird nginx-proxy-manager"
        ["Backup & Security"]="rest-server passbolt backrest"
    )

    for section in "Rootless Services" "Rootful Services" "Backup & Security"; do
        echo -e "\n${NEON_PURPLE}${ICON_ARROW}${RESET} ${BOLD}$section${RESET}"
        echo -e "${DIM_GRAY}──────────────────────────────────────────────────${RESET}"
        
        for svc in ${sections[$section]}; do
            IFS=':' read -r user url <<< "${services[$svc]}"
            svc_status=$(format_status "$(get_status $svc service $user)")
            ctr_status=$(format_status "$(get_status $svc container $user)")
            printf "  ${DIM_GRAY}%-14s${RESET} %s\n" "$svc" "$svc_status $ctr_status"
            [ -n "$url" ] && printf "                ${MUTED_GRAY}→ %s${RESET}\n" "$url"
        done
    done

    echo -e "\n${NEON_PURPLE}${ICON_ARROW}${RESET} ${BOLD}Resources${RESET}"
    echo -e "${DIM_GRAY}──────────────────────────────────────────────────${RESET}"
    printf "  ${DIM_GRAY}%-14s${RESET} %s\n" "Disk" "$(df -h "$INFRA_DIR" 2>/dev/null | tail -1 | awk '{print $3 "/" $2 " (" $5 ")"}')"
    printf "  ${DIM_GRAY}%-14s${RESET} %s\n" "Memory" "$(free -h 2>/dev/null | awk '/^Mem:/ {print $3 "/" $2}')"
    printf "  ${DIM_GRAY}%-14s${RESET} %s\n" "Containers" "user: $(podman ps -q 2>/dev/null | wc -l), system: $(sudo podman ps -q 2>/dev/null | wc -l)"

    echo -e "\n${DIM_GRAY}──────────────────────────────────────────────────${RESET}"
    echo -e "${MUTED_GRAY}Commands: ${NEON_CYAN}status${RESET}|${NEON_CYAN}start${RESET}|${NEON_CYAN}stop${RESET}|${NEON_CYAN}restart${RESET}|${NEON_CYAN}logs${RESET}|${NEON_CYAN}clear${RESET}"
}

clear_cmd() {
    echo -e "${NEON_RED}▸ ПОЛНОЕ УДАЛЕНИЕ ИНФРАСТРУКТУРЫ${RESET}"
    read -rp "  Вы уверены? Все данные будут удалены [yes/N]: " CONFIRM
    [ "$CONFIRM" = "yes" ] || exit 0

    echo -e "  ${NEON_YELLOW}▸ Остановка сервисов...${RESET}"
    systemctl --user stop gitea torrserver homepage 2>/dev/null
    sudo systemctl stop gitea-runner netbird rest-server passbolt backrest nginx-proxy-manager 2>/dev/null

    echo -e "  ${NEON_YELLOW}▸ Удаление контейнеров...${RESET}"
    podman rm -f systemd-gitea systemd-torrserver systemd-homepage 2>/dev/null
    sudo podman rm -f gitea-runner netbird rest-server passbolt backrest nginx-proxy-manager 2>/dev/null

    echo -e "  ${NEON_YELLOW}▸ Удаление Quadlet файлов...${RESET}"
    rm -f ~/.config/containers/systemd/{gitea,torrserver,homepage}.container
    sudo rm -f /etc/containers/systemd/{gitea-runner,netbird,rest-server,passbolt,backrest,nginx-proxy-manager}.container

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
            netbird|gitea-runner|rest-server|passbolt|backrest|nginx-proxy-manager) sudo journalctl -u "$2" -f ;;
            gitea|torrserver|homepage) journalctl --user -u "$2" -f ;;
            secretctl) journalctl --user -u secretctl-web -f ;;
            *) echo "Usage: infra logs <service>"; exit 1 ;;
        esac
        ;;
    stop)
        echo -e "${NEON_YELLOW}▸ Остановка сервисов...${RESET}"
        systemctl --user stop gitea torrserver homepage 2>/dev/null
        sudo systemctl stop gitea-runner netbird rest-server passbolt backrest nginx-proxy-manager 2>/dev/null
        echo -e "  ${ICON_OK} Services stopped"
        ;;
    start)
        echo -e "${NEON_GREEN}▸ Запуск сервисов...${RESET}"
        systemctl --user start gitea torrserver homepage 2>/dev/null
        sudo systemctl start gitea-runner netbird rest-server passbolt backrest nginx-proxy-manager 2>/dev/null
        echo -e "  ${ICON_OK} Services started"
        ;;
    restart)
        echo -e "${NEON_CYAN}▸ Перезапуск $2...${RESET}"
        case "$2" in
            netbird|gitea-runner|rest-server|passbolt|backrest|nginx-proxy-manager) sudo systemctl restart "$2" ;;
            gitea|torrserver|homepage) systemctl --user restart "$2" ;;
            secretctl) systemctl --user restart secretctl-web ;;
            *) echo "Unknown service: $2"; exit 1 ;;
        esac
        echo -e "  ${ICON_OK} $2 restarted"
        ;;
    clear) clear_cmd ;;
    *) echo "Использование: infra {status|start|stop|restart|logs|clear}" ;;
esac
ENDOFCLI

chmod +x "$BIN_DIR/infra"
sudo ln -sf "$BIN_DIR/infra" /usr/local/bin/infra 2>/dev/null || true
print_success "CLI установлен"

# =============== TORRSERVER ===============
print_step "Создание TorrServer"

step "Создание Quadlet файла" "
    cat > \"$QUADLET_USER_DIR/torrserver.container\" <<EOF
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
    chown $CURRENT_USER:$CURRENT_USER \"$QUADLET_USER_DIR/torrserver.container\"
"

step "Запуск TorrServer" "
    systemctl --user daemon-reload
    systemctl --user start torrserver.service
"

print_success "TorrServer запущен"
print_info "Для настройки: http://$SERVER_IP:8090"
print_info "После настройки NPM: https://torrent.lab"

# =============== GITEA ===============
print_step "Создание Gitea"

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
Environment=GITEA__repository_upload__MAX_FILES=1000
Environment=GITEA__repository_upload__FILE_MAX_SIZE=5000

[Service]
Restart=always
TimeoutStopSec=60
Type=notify
NotifyAccess=all

[Install]
WantedBy=default.target
EOF

chown "$CURRENT_USER:$CURRENT_USER" "$QUADLET_USER_DIR/gitea.container"
systemctl --user daemon-reload
systemctl --user start gitea.service
print_success "Gitea запущена"
print_info "Для настройки: http://$SERVER_IP:3000"
print_info "После настройки NPM: https://git.lab"

# =============== GITEA RUNNER ===============
print_step "Настройка Gitea Runner"

print_info "Ожидание 60 секунд для инициализации Gitea..."
sleep 60

if curl -sf --max-time 5 "http://$SERVER_IP:3000/api/v1/version" >/dev/null 2>&1; then
    print_success "Gitea API доступен"
    echo ""
    print_info "🔑 Для регистрации Runner'а нужен токен"
    print_info "1. Открой в браузере: ${NEON_CYAN}http://$SERVER_IP:3000/-/admin/actions/runners${RESET}"
    print_info "2. Нажми 'Create new runner'"
    print_info "3. Скопируй токен (выглядит как: ${MUTED_GRAY}xxxxxxxxxxxxxxxxxxxx${RESET})"
    echo ""
    
    while true; do
        read -rp "  Registration Token: " RUNNER_TOKEN
        if [ -n "$RUNNER_TOKEN" ]; then
            if [ ${#RUNNER_TOKEN} -gt 10 ]; then
                break
            else
                print_warning "Токен слишком короткий. Попробуй ещё раз (Enter чтобы пропустить)"
            fi
        else
            print_warning "Токен не введён, Runner пропущен"
            RUNNER_TOKEN=""
            break
        fi
    done
    
    if [ -n "$RUNNER_TOKEN" ]; then
        sudo mkdir -p /var/lib/gitea-runner
        sudo chmod 755 /var/lib/gitea-runner
        
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
        
        sleep 5
        if sudo podman ps --format "{{.Names}}" 2>/dev/null | grep -q "^gitea-runner$"; then
            print_success "Gitea Runner запущен и зарегистрирован"
        else
            print_error "Ошибка запуска Runner'а. Проверь логи: sudo journalctl -u gitea-runner"
        fi
    fi
else
    print_warning "Gitea API не доступен. Runner можно настроить позже командой:"
    print_info "  sudo ./setup-runner.sh"
    print_info "Или вручную после запуска Gitea"
fi

# =============== NETBIRD ===============
print_step "Настройка NetBird"
read -rp "  NetBird Setup Key (Enter - пропустить): " NB_KEY
if [ -n "$NB_KEY" ]; then
    step "Создание директории" "sudo mkdir -p /var/lib/netbird && sudo chmod 755 /var/lib/netbird"
    
    step "Создание Quadlet файла" "
        sudo tee \"$QUADLET_SYSTEM_DIR/netbird.container\" > /dev/null <<EOF
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
        sudo chmod 644 \"$QUADLET_SYSTEM_DIR/netbird.container\"
    "
    
    step "Запуск NetBird" "
        sudo systemctl daemon-reload
        sudo systemctl start netbird.service
        sleep 5
    "
    
    print_success "NetBird запущен"
else
    print_info "NetBird пропущен"
fi

# =============== REST-SERVER ===============
print_step "Настройка Restic REST сервера"

if [ ! -f "/var/lib/rest-server/.htpasswd" ]; then
    REST_PASS=$(openssl rand -base64 24 | tr -d "=+/" | cut -c1-20)
    echo "$REST_PASS" | sudo tee /var/lib/rest-server/.restic_pass > /dev/null
    sudo htpasswd -B -b -c /var/lib/rest-server/.htpasswd restic "$REST_PASS" >/dev/null 2>&1
    sudo chmod 600 /var/lib/rest-server/.htpasswd /var/lib/rest-server/.restic_pass
    print_info "Пароль restic сохранён в /var/lib/rest-server/.restic_pass"
fi

step "Создание Quadlet файла" "
    sudo tee \"$QUADLET_SYSTEM_DIR/rest-server.container\" > /dev/null <<EOF
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
    sudo chmod 644 \"$QUADLET_SYSTEM_DIR/rest-server.container\"
"

step "Запуск rest-server" "
    sudo systemctl daemon-reload
    sudo systemctl start rest-server.service
"

print_success "Restic REST сервер запущен"
print_info "Доступ: http://$SERVER_IP:8000 (user: restic)"

# =============== PASSBOLT ===============
print_step "Настройка Passbolt"

step "Создание директорий" "
    sudo mkdir -p /var/lib/passbolt/{database,gpg,jwt}
    sudo chmod 755 /var/lib/passbolt/{database,gpg,jwt}
"

step "Генерация GPG ключей" "
    sudo podman run --rm -v /var/lib/passbolt/gpg:/etc/passbolt/gpg:Z docker.io/passbolt/passbolt:latest \
        /bin/bash -c \"gpg --batch --gen-key <<EOF
            %no-protection
            Key-Type: RSA
            Key-Length: 4096
            Name-Real: Passbolt
            Name-Email: passbolt@devops.lab
            Expire-Date: 0
        EOF\" 2>/dev/null
"

step "Генерация JWT ключа" "
    openssl rand -base64 32 | sudo tee /var/lib/passbolt/jwt/jwt.key > /dev/null
    sudo chmod 600 /var/lib/passbolt/jwt/jwt.key
"

# Получение fingerprint GPG
GPG_FINGERPRINT=$(sudo gpg --homedir /var/lib/passbolt/gpg --fingerprint 2>/dev/null | grep -oE '[0-9A-F]{40}' | head -1)
PASSBOLT_DB_PASS=$(openssl rand -base64 24)

step "Создание конфигурации" "
    sudo tee /var/lib/passbolt/config.php > /dev/null <<EOF
<?php
return [
    'App' => ['fullBaseUrl' => 'https://passbolt.lab', 'registration' => ['public' => false]],
    'Database' => ['host' => 'localhost', 'port' => '3306', 'username' => 'passbolt', 
                   'password' => '$PASSBOLT_DB_PASS', 'database' => 'passbolt'],
    'passbolt' => ['gpg' => ['serverKey' => ['fingerprint' => '$GPG_FINGERPRINT',
                    'public' => '/etc/passbolt/gpg/public.key', 'private' => '/etc/passbolt/gpg/private.key']],
                   'jwt' => ['key' => file_get_contents('/etc/passbolt/jwt/jwt.key')]]
];
EOF
    sudo chmod 644 /var/lib/passbolt/config.php
"

step "Создание Quadlet файла" "
    sudo tee \"$QUADLET_SYSTEM_DIR/passbolt.container\" > /dev/null <<EOF
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
    sudo chmod 644 \"$QUADLET_SYSTEM_DIR/passbolt.container\"
"

step "Запуск Passbolt" "
    sudo systemctl daemon-reload
    sudo systemctl start passbolt.service
"

print_success "Passbolt запущен"
print_info "Для настройки: http://$SERVER_IP:8080"
print_info "После настройки NPM: https://passbolt.lab"
print_info "Пароль БД: $PASSBOLT_DB_PASS (сохрани!)"

# =============== BACKREST ===============
print_step "Настройка Backrest"

step "Создание директорий" "
    sudo mkdir -p /var/lib/backrest/{data,config,cache}
    sudo chown -R 1000:1000 /var/lib/backrest 2>/dev/null
"

step "Создание Quadlet файла" "
    sudo tee \"$QUADLET_SYSTEM_DIR/backrest.container\" > /dev/null <<EOF
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
    sudo chmod 644 \"$QUADLET_SYSTEM_DIR/backrest.container\"
"

step "Запуск Backrest" "
    sudo systemctl daemon-reload
    sudo systemctl start backrest.service
"

print_success "Backrest запущен"
print_info "Для настройки: http://$SERVER_IP:9898"
print_info "После настройки NPM: https://backup.lab"

# =============== SECRETCTL ===============
print_step "Настройка secretctl (API-ключи)"

step "Установка secretctl" "
    export PATH=$PATH:/usr/local/go/bin
    go install github.com/forest6511/secretctl@latest 2>/dev/null
    sudo ln -sf ~/go/bin/secretctl /usr/local/bin/
"

step "Инициализация хранилища" "
    secretctl init <<< \"$(openssl rand -base64 32)\" 2>/dev/null
"

step "Создание Web UI сервиса" "
    mkdir -p ~/.config/systemd/user
    cat > ~/.config/systemd/user/secretctl-web.service <<EOF
[Unit]
Description=secretctl Web Interface
After=network.target

[Service]
Type=simple
ExecStart=/home/$CURRENT_USER/go/bin/secretctl web --port 8082 --bind 127.0.0.1
Restart=always

[Install]
WantedBy=default.target
EOF
"

step "Запуск Web UI" "
    systemctl --user daemon-reload
    systemctl --user enable --now secretctl-web.service
"

print_success "secretctl установлен"
print_info "Web UI: http://$SERVER_IP:8082 (после настройки NPM: https://keys.lab)"
print_info "Windows GUI: https://github.com/forest6511/secretctl/releases"

# =============== NGINX PROXY MANAGER ===============
print_step "Настройка Nginx Proxy Manager"

NPM_DIR="$INFRA_DIR/nginx-proxy-manager"
mkdir -p "$NPM_DIR"/{data,letsencrypt}

step "Создание Quadlet файла" "
    sudo tee \"$QUADLET_SYSTEM_DIR/nginx-proxy-manager.container\" > /dev/null <<EOF
[Unit]
Description=Nginx Proxy Manager
After=network-online.target
Wants=podman-auto-update.service

[Container]
Image=jc21/nginx-proxy-manager:latest
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
    sudo chmod 644 \"$QUADLET_SYSTEM_DIR/nginx-proxy-manager.container\"
"

step "Запуск NPM" "
    sudo systemctl daemon-reload
    sudo systemctl start nginx-proxy-manager.service
"

print_success "Nginx Proxy Manager запущен"
print_info "Admin UI: http://$SERVER_IP:81 (admin@example.com / changeme)"
print_info "После настройки NPM все сервисы станут доступны по доменам .lab с HTTPS"

# =============== HOMEPAGE ===============
print_step "Настройка Homepage (красивый дашборд)"

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
  - name: \"Погода в Барнауле\"
    type: \"openweathermap\"
    apiKey: \"$WEATHER_KEY\"
    units: \"metric\"
    city: \"Barnaul\"
    country: \"RU\""
else
    WEATHER_CONFIG=""
fi

step "Создание конфигурации Homepage" "
    cat > \"$HOMEPAGE_CONFIG_DIR/settings.yaml\" <<EOF
---
title: \"DevOps Lab Dashboard\"
theme: dark
color: slate
headerStyle: clean
hideVersion: false
useEqualHeights: true
statusStyle: \"dot\"
statusPosition: \"bottom\"
search:
  provider: duckduckgo
  target: _blank
information:
$WEATHER_CONFIG
  - name: \"Системная информация\"
    type: \"glances\"
    url: \"http://localhost:61208\"
    refresh: 5000
EOF

    cat > \"$HOMEPAGE_CONFIG_DIR/services.yaml\" <<EOF
---
Infrastructure:
  - Passbolt:
      icon: https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/passbolt.png
      href: https://passbolt.lab
      description: \"Менеджер паролей\"
      container: passbolt
  - Backrest:
      icon: https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/restic.png
      href: https://backup.lab
      description: \"Управление бэкапами\"
      container: backrest
  - Gitea:
      icon: https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/gitea.png
      href: https://git.lab
      description: \"Git репозиторий\"
      container: systemd-gitea
  - TorrServer:
      icon: https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/torrent.png
      href: https://torrent.lab
      description: \"Торрент стриминг\"
      container: systemd-torrserver

Windows Clients:
  - NetBird VPN:
      icon: https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/netbird.png
      href: https://pkgs.netbird.io/windows
      description: \"Для доступа из любой точки\"
      subtitle: \"Без VPN не попадёшь домой\"
  - secretctl Desktop:
      icon: https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/key.png
      href: https://github.com/forest6511/secretctl/releases
      description: \"GUI для API-ключей\"
      subtitle: \"Хранилище на сервере ~/.secretctl/vault.db\"
  - Bitwarden Desktop:
      icon: https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/bitwarden.png
      href: https://bitwarden.com/download/
      description: \"Клиент для Passbolt\"
      subtitle: \"Настрой сервер https://passbolt.lab\"
  - Restic:
      icon: https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/restic.png
      href: https://github.com/restic/restic/releases
      description: \"Бэкапы Windows\"
      subtitle: \"rest:http://restic:ПАРОЛЬ@keys.lab:8000/windows-backup\"

Administration:
  - Nginx Proxy Manager:
      icon: https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/nginx-proxy-manager.png
      href: http://192.168.1.8:81
      description: \"Reverse proxy GUI\"
      container: nginx-proxy-manager
  - NetBird:
      icon: https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/netbird.png
      href: https://app.netbird.io
      description: \"VPN управление\"
      container: netbird
  - secretctl:
      icon: https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/key.png
      href: https://keys.lab
      description: \"API-ключи (Web UI)\"
  - Restic REST:
      icon: https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/restic.png
      href: http://192.168.1.8:8000
      description: \"Хранилище бэкапов\"
      container: rest-server
EOF

    chown -R $CURRENT_USER:$CURRENT_USER \"$HOMEPAGE_CONFIG_DIR\"
"

step "Создание Quadlet файла Homepage" "
    cat > \"$QUADLET_USER_DIR/homepage.container\" <<EOF
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
    chown $CURRENT_USER:$CURRENT_USER \"$QUADLET_USER_DIR/homepage.container\"
"

step "Запуск Homepage" "
    systemctl --user daemon-reload
    systemctl --user start homepage.service
"

print_success "Homepage запущен"
print_info "Для настройки: http://$SERVER_IP:3001"
print_info "После настройки NPM: https://home.lab"

# =============== ФИНАЛЬНЫЙ ВЫВОД ===============
print_header "🚀 ИНФРАСТРУКТУРА ГОТОВА К НАСТРОЙКЕ"

cat <<EOF

${NEON_GREEN}╔══════════════════════════════════════════════════════════╗${RESET}
${NEON_GREEN}║         🔌 ДОСТУП ДЛЯ ПЕРВОНАЧАЛЬНОЙ НАСТРОЙКИ         ║${RESET}
${NEON_GREEN}╚══════════════════════════════════════════════════════════╝${RESET}

${NEON_CYAN}🏠 ДАШБОРД И УПРАВЛЕНИЕ${RESET}
  ${NEON_GREEN}●${RESET} Homepage:            ${NEON_CYAN}http://$SERVER_IP:3001${RESET}
  ${NEON_GREEN}●${RESET} Nginx Proxy Manager: ${NEON_CYAN}http://$SERVER_IP:81${RESET} (admin@example.com / changeme)

${NEON_CYAN}🔐 МЕНЕДЖЕРЫ СЕКРЕТОВ${RESET}
  ${NEON_GREEN}●${RESET} Passbolt:            ${NEON_CYAN}http://$SERVER_IP:8080${RESET}
  ${NEON_GREEN}●${RESET} secretctl Web UI:    ${NEON_CYAN}http://$SERVER_IP:8082${RESET}

${NEON_CYAN}📦 РАЗРАБОТКА И БЭКАПЫ${RESET}
  ${NEON_GREEN}●${RESET} Gitea:               ${NEON_CYAN}http://$SERVER_IP:3000${RESET}
  ${NEON_GREEN}●${RESET} Backrest:            ${NEON_CYAN}http://$SERVER_IP:9898${RESET}
  ${NEON_GREEN}●${RESET} Restic REST:         ${NEON_CYAN}http://$SERVER_IP:8000${RESET} (user: restic)

${NEON_CYAN}🎬 МЕДИА${RESET}
  ${NEON_GREEN}●${RESET} TorrServer:          ${NEON_CYAN}http://$SERVER_IP:8090${RESET}

${NEON_CYAN}🪟 WINDOWS КЛИЕНТЫ (установи после настройки VPN)${RESET}
  ${NEON_GREEN}●${RESET} NetBird:     ${NEON_CYAN}https://pkgs.netbird.io/windows${RESET}
  ${NEON_GREEN}●${RESET} secretctl:   ${NEON_CYAN}https://github.com/forest6511/secretctl/releases${RESET}
  ${NEON_GREEN}●${RESET} Bitwarden:   ${NEON_CYAN}https://bitwarden.com/download/${RESET}
  ${NEON_GREEN}●${RESET} Restic:      ${NEON_CYAN}https://github.com/restic/restic/releases${RESET}

${NEON_BLUE}📋 СЛЕДУЮЩИЕ ШАГИ${RESET}
  ${NEON_YELLOW}1.${RESET} Зайди в Nginx Proxy Manager (http://$SERVER_IP:81)
  ${NEON_YELLOW}2.${RESET} Добавь proxy hosts для всех доменов (passbolt.lab, git.lab и т.д.)
  ${NEON_YELLOW}3.${RESET} Включи SSL (сертификаты уже созданы в $CERT_DIR)
  ${NEON_YELLOW}4.${RESET} После этого сервисы станут доступны по HTTPS доменам

${NEON_GREEN}🎉 УПРАВЛЕНИЕ: ${NEON_CYAN}infra status${RESET}
${NEON_GREEN}📋 ЛОГИ:       ${NEON_CYAN}infra logs <service>${RESET}
EOF

# =============== САМОУДАЛЕНИЕ ===============
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
if [ -f "$SCRIPT_PATH" ] && [ "$SCRIPT_PATH" != "$BIN_DIR/infra" ] && [ "$SCRIPT_PATH" != "/usr/local/bin/infra" ]; then
    rm -f "$SCRIPT_PATH"
    print_success "Скрипт удалён"
fi
