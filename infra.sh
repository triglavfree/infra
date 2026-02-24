#!/bin/bash
set -uo pipefail
# =============================================================================
# INFRASTRUCTURE v10.0.0 (FINAL QUADLET EDITION FOR UBUNTU 24.04)
# =============================================================================

# Цвета через tput
if [ -t 1 ]; then
    ncolors=$(tput colors 2>/dev/null || echo 0)
    if [ $ncolors -ge 256 ]; then
        NEON_CYAN=$(tput setaf 81)
        NEON_GREEN=$(tput setaf 84)
        NEON_YELLOW=$(tput setaf 220)
        NEON_RED=$(tput setaf 203)
        NEON_PURPLE=$(tput setaf 141)
        NEON_BLUE=$(tput setaf 75)
        SOFT_WHITE=$(tput setaf 252)
        MUTED_GRAY=$(tput setaf 245)
        DIM_GRAY=$(tput setaf 240)
        BOLD=$(tput bold)
        RESET=$(tput sgr0)
    else
        NEON_CYAN=$(tput setaf 6)
        NEON_GREEN=$(tput setaf 2)
        NEON_YELLOW=$(tput setaf 3)
        NEON_RED=$(tput setaf 1)
        NEON_PURPLE=$(tput setaf 5)
        NEON_BLUE=$(tput setaf 4)
        SOFT_WHITE=$(tput setaf 7)
        MUTED_GRAY=$(tput setaf 8)
        DIM_GRAY=$(tput setaf 8)
        BOLD=$(tput bold)
        RESET=$(tput sgr0)
    fi
else
    NEON_CYAN=""; NEON_GREEN=""; NEON_YELLOW=""; NEON_RED=""
    NEON_PURPLE=""; NEON_BLUE=""; SOFT_WHITE=""; MUTED_GRAY=""
    DIM_GRAY=""; BOLD=""; RESET=""
fi

CURRENT_USER="${SUDO_USER:-$(whoami)}"
CURRENT_UID=$(id -u "$CURRENT_USER")

print_header() {
    echo ""
    echo -e "${DIM_GRAY}─────────────────────────────────────────${RESET}"
    echo -e "${NEON_CYAN}${BOLD}  $1${RESET}"
    echo -e "${DIM_GRAY}─────────────────────────────────────────${RESET}"
    echo ""
}

print_step() {
    echo ""
    echo -e "${NEON_CYAN}${BOLD}▸${RESET} ${SOFT_WHITE}${BOLD}$1${RESET}"
    echo -e "${DIM_GRAY}  $(printf '─%.0s' $(seq 1 40))${RESET}"
}

print_success() { echo -e "  ${NEON_GREEN}✓${RESET} ${SOFT_WHITE}$1${RESET}"; }
print_warning() { echo -e "  ${NEON_YELLOW}⚡${RESET} ${SOFT_WHITE}$1${RESET}"; }
print_error() { echo -e "  ${NEON_RED}✗${RESET} ${BOLD}$1${RESET}" >&2; }
print_info() { echo -e "  ${NEON_BLUE}ℹ${RESET} ${MUTED_GRAY}$1${RESET}"; }
print_url() { echo -e "  ${NEON_CYAN}➜${RESET} ${BOLD}${NEON_CYAN}$1${RESET}"; }

# =============== ПРОВЕРКА ===============
if [ "$(id -u)" = "0" ] && [ -z "${SUDO_USER:-}" ]; then
    print_error "Запускайте от обычного пользователя с sudo!"
    exit 1
fi

CURRENT_HOME="$(getent passwd "$CURRENT_USER" 2>/dev/null | cut -d: -f6)"
SERVER_IP=$(hostname -I | awk '{print $1}')

print_header "INFRASTRUCTURE v10.0.0 (FINAL)"
print_info "User: $CURRENT_USER | UID: $CURRENT_UID | IP: $SERVER_IP"

# =============== КАТАЛОГИ С ПРАВАМИ ===============
print_step "Создание структуры"

INFRA_DIR="$CURRENT_HOME/infra"
VOLUMES_DIR="$INFRA_DIR/volumes"
BIN_DIR="$INFRA_DIR/bin"
LOGS_DIR="$INFRA_DIR/logs"
BACKUP_DIR="$INFRA_DIR/backups"

# Директории для Quadlet
QUADLET_USER_DIR="$CURRENT_HOME/.config/containers/systemd"
QUADLET_SYSTEM_DIR="/etc/containers/systemd"

for dir in "$INFRA_DIR" "$VOLUMES_DIR" "$BIN_DIR" "$LOGS_DIR" "$BACKUP_DIR" "$BACKUP_DIR/cache" "$BACKUP_DIR/snapshots" \
           "$VOLUMES_DIR"/{gitea,torrserver} "$QUADLET_USER_DIR"; do
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        chown "$CURRENT_USER:$CURRENT_USER" "$dir"
        chmod 755 "$dir"
    fi
done

if [ ! -d "$QUADLET_SYSTEM_DIR" ]; then
    sudo mkdir -p "$QUADLET_SYSTEM_DIR"
fi

sudo mkdir -p /var/lib/gitea-runner /var/lib/netbird
sudo chmod 755 /var/lib/gitea-runner /var/lib/netbird

print_success "Директории созданы с правами $CURRENT_USER"

# =============== ДИАГНОСТИКА QUADLET ===============
print_step "Диагностика Quadlet"

if [ -f "/usr/libexec/podman/quadlet" ]; then
    print_success "Quadlet найден: /usr/libexec/podman/quadlet"
    if [ ! -L "/usr/lib/systemd/system-generators/podman-system-generator" ]; then
        print_warning "Systemd генератор не найден, создаем ссылку"
        sudo ln -sf /usr/libexec/podman/quadlet /usr/lib/systemd/system-generators/podman-system-generator
    fi
    if ! systemctl is-active --quiet podman.socket; then
        sudo systemctl enable --now podman.socket
    fi
    print_success "podman.socket активен"
else
    print_error "Quadlet не установлен! Устанавливаем podman..."
    sudo apt-get update
    sudo apt-get install -y podman podman-docker
fi

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
        apt-get install -y -qq uidmap slirp4netns fuse-overlayfs curl openssl ufw fail2ban >/dev/null 2>&1 || true

        if [ ! -f /swapfile ] && [ \$(free | grep -c Swap) -eq 0 ] || [ \$(free | awk '/^Swap:/ {print \$2}') -eq 0 ]; then
            fallocate -l ${SWAP_MB}M /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=${SWAP_MB} 2>/dev/null
            chmod 600 /swapfile
            mkswap /swapfile >/dev/null 2>&1
            swapon /swapfile >/dev/null 2>&1
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
            sysctl vm.swappiness=10 >/dev/null 2>&1
            echo 'vm.swappiness=10' >> /etc/sysctl.conf
        fi

        if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
            echo 'net.core.default_qdisc=fq' >> /etc/sysctl.conf
            echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.conf
            sysctl -p >/dev/null 2>&1
        fi

        if ! grep -q '$CURRENT_USER:' /etc/subuid 2>/dev/null; then
            usermod --add-subuids 100000-165535 --add-subgids 100000-165535 '$CURRENT_USER' 2>/dev/null || true
        fi

        mkdir -p /run/user/$CURRENT_UID
        chown $CURRENT_USER:$CURRENT_USER /run/user/$CURRENT_UID
        chmod 700 /run/user/$CURRENT_UID

        # UFW
        ufw --force reset >/dev/null 2>&1
        ufw default deny incoming >/dev/null 2>&1
        ufw default allow outgoing >/dev/null 2>&1
        ufw allow 22/tcp comment 'SSH' >/dev/null 2>&1
        ufw allow 3000/tcp comment 'Gitea HTTP' >/dev/null 2>&1
        ufw allow 2222/tcp comment 'Gitea SSH' >/dev/null 2>&1
        ufw allow 8090/tcp comment 'TorrServer' >/dev/null 2>&1
        ufw allow 51820/udp comment 'WireGuard' >/dev/null 2>&1
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

        # SSH hardening
        if [ -d '$CURRENT_HOME/.ssh' ] && [ -n '\$(ls -A $CURRENT_HOME/.ssh/*.pub 2>/dev/null)' ]; then
            sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
            sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
            sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
            systemctl restart sshd >/dev/null 2>&1 || true
        else
            echo 'SSH_KEYS_MISSING' > /tmp/ssh_status
        fi
    "

    if [ -f /tmp/ssh_status ]; then
        rm -f /tmp/ssh_status
        print_warning "SSH ключи не найдены! Парольная аутентификация оставлена"
        print_info "Добавьте ключ: ssh-copy-id user@$SERVER_IP"
    else
        print_success "SSH hardening применен"
    fi

    touch "$INFRA_DIR/.bootstrap_done"
    print_success "Система настроена"
else
    print_info "Bootstrap уже выполнен"
fi

sudo loginctl enable-linger "$CURRENT_USER" 2>/dev/null || true

# =============== PODMAN AUTO-UPDATE ===============
print_step "Настройка авто-обновления"

if ! systemctl --user is-enabled podman-auto-update.timer >/dev/null 2>&1; then
    systemctl --user enable podman-auto-update.timer 2>/dev/null || true
    systemctl --user start podman-auto-update.timer 2>/dev/null || true
    print_success "Rootless auto-update timer включен"
fi

if ! sudo systemctl is-enabled podman-auto-update.timer >/dev/null 2>&1; then
    sudo systemctl enable podman-auto-update.timer 2>/dev/null || true
    sudo systemctl start podman-auto-update.timer 2>/dev/null || true
    print_success "Rootful auto-update timer включен"
fi

# =============== TORRSERVER ROOTLESS (QUADLET) ===============
print_step "Создание TorrServer"

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
TimeoutStopSec=10
Type=notify
NotifyAccess=all

[Install]
WantedBy=default.target
EOF

chown "$CURRENT_USER:$CURRENT_USER" "$QUADLET_USER_DIR/torrserver.container"
systemctl --user daemon-reload
systemctl --user start torrserver.service
print_success "TorrServer запущен"
print_url "http://${SERVER_IP}:8090/"

# =============== GITEA ROOTLESS (QUADLET) ===============
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

print_info "Ожидание 15 сек..."
sleep 15

if curl -sf --max-time 5 "http://$SERVER_IP:3000/api/v1/version" >/dev/null 2>&1; then
    print_success "Gitea API доступен"
    GITEA_READY=1
else
    print_warning "Gitea API не отвечает"
    GITEA_READY=0
fi
print_url "http://${SERVER_IP}:3000/"

# =============== RUNNER ROOTFUL (QUADLET) ===============
print_step "Настройка Gitea Runner"

SKIP_RUNNER=0
if sudo systemctl list-unit-files 2>/dev/null | grep -q "gitea-runner.service" || [ -f "$QUADLET_SYSTEM_DIR/gitea-runner.container" ]; then
    print_info "Runner уже существует"
    read -rp "  Пересоздать? [y/N]: " RECREATE
    if [[ "$RECREATE" =~ ^[Yy]$ ]]; then
        sudo systemctl stop gitea-runner.service 2>/dev/null || true
        sudo podman stop gitea-runner 2>/dev/null || true
        sudo podman rm gitea-runner 2>/dev/null || true
        sudo rm -f "$QUADLET_SYSTEM_DIR/gitea-runner.container"
        sudo rm -f /run/systemd/generator/gitea-runner.service 2>/dev/null
        sudo systemctl daemon-reload
    else
        SKIP_RUNNER=1
    fi
fi

if [ $SKIP_RUNNER -eq 0 ]; then
    echo ""
    echo -e "${NEON_PURPLE}${BOLD}▸ РЕГИСТРАЦИЯ RUNNER'А${RESET}"
    echo ""
    echo -e "  Откройте: ${NEON_CYAN}http://$SERVER_IP:3000/-/admin/actions/runners${RESET}"
    print_info "  Создайте новый раннер и скопируйте токен"
    read -rp "  Registration Token: " RUNNER_TOKEN

    if [ -n "$RUNNER_TOKEN" ]; then
        sudo rm -rf /var/lib/gitea-runner
        sudo mkdir -p /var/lib/gitea-runner
        sudo chmod 755 /var/lib/gitea-runner

        sudo tee "$QUADLET_SYSTEM_DIR/gitea-runner.container" > /dev/null <<EOF
[Unit]
Description=Gitea Runner
After=network-online.target
Wants=podman-auto-update.service

[Container]
Image=docker.io/gitea/act_runner:nightly
ContainerName=gitea-runner
Volume=/var/run/docker.sock:/var/run/docker.sock:Z
Volume=/var/lib/gitea-runner:/data:Z
Environment=GITEA_INSTANCE_URL=http://$SERVER_IP:3000
Environment=GITEA_RUNNER_REGISTRATION_TOKEN=$RUNNER_TOKEN
Environment=GITEA_RUNNER_NAME=runner-$(hostname | cut -d. -f1)
Exec=act_runner daemon

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
        sudo systemctl restart podman.socket
        sudo systemctl daemon-reload
        sudo systemctl start gitea-runner.service

        sleep 8
        if sudo podman ps --format "{{.Names}}" | grep -q "^gitea-runner$"; then
            print_success "Runner запущен"
            sudo podman logs gitea-runner 2>&1 | tail -5
        else
            print_error "Ошибка запуска runner"
        fi
    else
        print_info "Runner пропущен"
    fi
fi

# =============== NETBIRD ROOTFUL (QUADLET) ===============
print_step "Настройка NetBird"

SKIP_NETBIRD=0
if sudo systemctl list-unit-files 2>/dev/null | grep -q "netbird.service" || [ -f "$QUADLET_SYSTEM_DIR/netbird.container" ]; then
    print_info "NetBird уже существует"
    read -rp "  Пересоздать? [y/N]: " RECREATE_NB
    if [[ "$RECREATE_NB" =~ ^[Yy]$ ]]; then
        sudo systemctl stop netbird.service 2>/dev/null || true
        sudo podman stop netbird 2>/dev/null || true
        sudo podman rm netbird 2>/dev/null || true
        sudo rm -f "$QUADLET_SYSTEM_DIR/netbird.container"
        sudo rm -f /run/systemd/generator/netbird.service 2>/dev/null
        sudo systemctl daemon-reload
    else
        SKIP_NETBIRD=1
    fi
fi

if [ "${SKIP_NETBIRD:-0}" -eq 0 ]; then
    echo ""
    echo -e "${NEON_BLUE}${BOLD}▸ ПОДКЛЮЧЕНИЕ NETBIRD${RESET}"
    echo -e "  Получить ключ: ${NEON_CYAN}https://app.netbird.io/setup-keys${RESET}"
    read -rp "  Setup Key (Enter - пропустить): " NB_KEY

    if [ -n "${NB_KEY:-}" ]; then
        sudo rm -rf /var/lib/netbird
        sudo mkdir -p /var/lib/netbird
        sudo chmod 755 /var/lib/netbird

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
TimeoutStopSec=30
Type=notify
NotifyAccess=all

[Install]
WantedBy=multi-user.target
EOF

        sudo chmod 644 "$QUADLET_SYSTEM_DIR/netbird.container"
        sudo systemctl restart podman.socket
        sudo systemctl daemon-reload
        sudo systemctl start netbird.service

        sleep 10
        if sudo podman ps --format "{{.Names}}" | grep -q "^netbird$"; then
            print_success "NetBird запущен"
            NB_IP=$(sudo podman exec netbird ip addr show wt0 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1)
            [ -n "$NB_IP" ] && print_info "IP в сети NetBird: $NB_IP"
        else
            print_error "Ошибка запуска NetBird"
        fi
    else
        print_info "NetBird пропущен"
    fi
fi

# =============== CLI (ПОЛНАЯ ВЕРСИЯ) ===============
cat > "$BIN_DIR/infra" <<'ENDOFCLI'
#!/bin/bash
INFRA_DIR="$HOME/infra"
VOLUMES_DIR="$INFRA_DIR/volumes"
BACKUP_DIR="$INFRA_DIR/backups"

if [ -t 1 ]; then
    ncolors=$(tput colors 2>/dev/null || echo 0)
    if [ $ncolors -ge 256 ]; then
        NEON_CYAN=$(tput setaf 81); NEON_GREEN=$(tput setaf 84); NEON_YELLOW=$(tput setaf 220)
        NEON_RED=$(tput setaf 203); NEON_PURPLE=$(tput setaf 141); NEON_BLUE=$(tput setaf 75)
        SOFT_WHITE=$(tput setaf 252); MUTED_GRAY=$(tput setaf 245); DIM_GRAY=$(tput setaf 240)
        BOLD=$(tput bold); RESET=$(tput sgr0)
    else
        NEON_CYAN=$(tput setaf 6); NEON_GREEN=$(tput setaf 2); NEON_YELLOW=$(tput setaf 3)
        NEON_RED=$(tput setaf 1); NEON_PURPLE=$(tput setaf 5); NEON_BLUE=$(tput setaf 4)
        SOFT_WHITE=$(tput setaf 7); MUTED_GRAY=$(tput setaf 8); DIM_GRAY=$(tput setaf 8)
        BOLD=$(tput bold); RESET=$(tput sgr0)
    fi
else
    NEON_CYAN=""; NEON_GREEN=""; NEON_YELLOW=""; NEON_RED=""
    NEON_PURPLE=""; NEON_BLUE=""; SOFT_WHITE=""; MUTED_GRAY=""
    DIM_GRAY=""; BOLD=""; RESET=""
fi

ICON_OK="${NEON_GREEN}●${RESET}"
ICON_FAIL="${NEON_RED}●${RESET}"
ICON_WARN="${NEON_YELLOW}●${RESET}"
ICON_INFO="${NEON_BLUE}●${RESET}"
ICON_ARROW="▸"

print_box() {
    local title="$1"
    local datetime=$(date "+%d.%m.%Y %H:%M:%S")  # 24.02.2026 15:35:00
    local full_title="${title} ${datetime}"
    echo ""
    echo -e "${NEON_CYAN}╔══════════════════════════════════════════════════╗${RESET}"
    printf "${NEON_CYAN}║${RESET} ${BOLD}%-48s${RESET} ${NEON_CYAN}║${RESET}\n" "$full_title"
    echo -e "${NEON_CYAN}╚══════════════════════════════════════════════════╝${RESET}"
}

print_section() {
    echo ""
    echo -e "${NEON_PURPLE}${ICON_ARROW}${RESET} ${BOLD}$1${RESET}"
    echo -e "${DIM_GRAY}──────────────────────────────────────────────────${RESET}"
}

print_metric() {
    printf "  ${DIM_GRAY}%-14s${RESET} %s\n" "$1" "$2"
}

get_container_status() {
    local name=$1
    local user=$2
    local runtime=""
    [ "$user" = "root" ] && runtime="sudo podman" || runtime="podman"

    # Проверяем запущенные контейнеры
    if $runtime ps --format "{{.Names}}" 2>/dev/null | grep -q "^systemd-$name$"; then
        # Контейнер запущен, получаем время работы
        local started_at=$($runtime inspect --format='{{.State.StartedAt}}' "systemd-$name" 2>/dev/null)
        local uptime_str=""
        
        if [ -n "$started_at" ] && [ "$started_at" != "0001-01-01T00:00:00Z" ]; then
            local start_epoch=$(date -d "$started_at" +%s 2>/dev/null)
            local now_epoch=$(date +%s)
            local diff=$((now_epoch - start_epoch))
            if [ $diff -lt 60 ]; then uptime_str="${diff}s"
            elif [ $diff -lt 3600 ]; then uptime_str="$((diff / 60))m"
            else uptime_str="$((diff / 3600))h$(((diff % 3600) / 60))m"; fi
        fi
        
        echo -e "${ICON_OK} ${NEON_GREEN}running${RESET} ${DIM_GRAY}(${uptime_str})${RESET}"
        return
    fi
    
    # Проверяем остановленные контейнеры
    if $runtime ps -a --format "{{.Names}}" 2>/dev/null | grep -q "^systemd-$name$"; then
        echo -e "${ICON_FAIL} ${NEON_RED}stopped${RESET}"
    else
        echo -e "${DIM_GRAY}● not created${RESET}"
    fi
}

get_service_status() {
    local name=$1
    local user=$2
    if [ "$user" = "root" ]; then
        if systemctl is-active --quiet "$name" 2>/dev/null; then
            echo -e "${ICON_OK} ${NEON_GREEN}active${RESET}"
        else
            echo -e "${DIM_GRAY}● inactive${RESET}"
        fi
    else
        if systemctl --user is-active --quiet "$name" 2>/dev/null; then
            echo -e "${ICON_OK} ${NEON_GREEN}active${RESET}"
        else
            echo -e "${DIM_GRAY}● inactive${RESET}"
        fi
    fi
}

get_disk_type() {
    local disk=$1
    [ -z "$disk" ] && echo "unknown" && return
    
    # Получаем точку монтирования INFRA_DIR
    local mount_point="$INFRA_DIR"
    
    # Получаем устройство для этой точки монтирования
    local device=""
    
    # Метод 1: findmnt
    if command -v findmnt &>/dev/null; then
        device=$(findmnt -no SOURCE "$mount_point" 2>/dev/null | head -1)
    fi
    
    # Метод 2: df
    if [ -z "$device" ]; then
        device=$(df "$mount_point" 2>/dev/null | tail -1 | awk '{print $1}')
    fi
    
    # Если это LVM (/dev/mapper/*), пытаемся найти физическое устройство
    if [[ "$device" == *"/dev/mapper/"* ]] || [[ "$device" == *"/dev/dm-"* ]]; then
        # Метод: через lsblk найти физическое устройство для LVM
        if command -v lsblk &>/dev/null; then
            # Получаем имя LVM тома
            local lvm_name=$(basename "$device")
            # Ищем физическое устройство через lsblk
            local physical_dev=$(lsblk -no PKNAME "/dev/$lvm_name" 2>/dev/null | head -1)
            if [ -n "$physical_dev" ]; then
                device="/dev/$physical_dev"
            fi
        fi
    fi
    
    # Убираем номера партиций
    local base_disk=$(echo "$device" | sed -E 's/[0-9]+$//' | sed -E 's/p[0-9]+$//')
    local dev_name=$(basename "$base_disk")
    
    # Диагностика (можно удалить после отладки)
    # echo "DEBUG: device=$device, base_disk=$base_disk, dev_name=$dev_name" >&2
    
    # Метод 1: Проверка через lsblk ROTA
    if command -v lsblk &>/dev/null && [ -n "$dev_name" ]; then
        local rotational=$(lsblk -d -o ROTA "/dev/$dev_name" 2>/dev/null | tail -1)
        if [ "$rotational" = "0" ]; then
            echo "SSD"
            return
        elif [ "$rotational" = "1" ]; then
            echo "HDD"
            return
        fi
    fi
    
    # Метод 2: Проверка через sysfs
    if [ -n "$dev_name" ] && [ -f "/sys/block/$dev_name/queue/rotational" ]; then
        local rotational=$(cat "/sys/block/$dev_name/queue/rotational" 2>/dev/null)
        if [ "$rotational" = "0" ]; then
            echo "SSD"
            return
        elif [ "$rotational" = "1" ]; then
            echo "HDD"
            return
        fi
    fi
    
    # Метод 3: Проверка по модели
    if command -v lsblk &>/dev/null && [ -n "$dev_name" ]; then
        local model=$(lsblk -d -o MODEL "/dev/$dev_name" 2>/dev/null | tail -1)
        if [[ "$model" == *"SSD"* ]] || [[ "$model" == *"NVMe"* ]] || [[ "$model" == *"Netac"* ]]; then
            echo "SSD"
            return
        elif [[ "$model" == *"HDD"* ]]; then
            echo "HDD"
            return
        fi
    fi
    
    # Метод 4: Прямая проверка всех дисков на наличие SSD
    if command -v lsblk &>/dev/null; then
        # Проверим все диски на наличие ROTA=0 (SSD)
        local all_disks=$(lsblk -d -o NAME,ROTA,MODEL 2>/dev/null | grep -E "^sd|^nvme")
        while IFS= read -r line; do
            if echo "$line" | grep -q "0"; then
                echo "SSD"
                return
            fi
        done <<< "$all_disks"
    fi
    
    echo "unknown"
}

status_cmd() {
    clear
    print_box "INFRA STATUS v10.0.0"  # ← здесь вызов с датой внутри
    local server_ip=$(hostname -I | awk '{print $1}')

    print_section "Rootless Services (User: $USER)"
    local gitea_svc=$(get_service_status "gitea" "user")
    local gitea_ctr=$(get_container_status "gitea" "user")
    print_metric "Gitea" "$gitea_svc $gitea_ctr"
    
    # Показываем ссылки для Gitea
    if podman ps --format "{{.Names}}" 2>/dev/null | grep -q "^systemd-gitea$"; then
        local gitea_port=$(podman port systemd-gitea 2>/dev/null | grep "3000/tcp" | cut -d: -f2 || echo "3000")
        local gitea_ssh=$(podman port systemd-gitea 2>/dev/null | grep "22/tcp" | cut -d: -f2 || echo "2222")
        print_metric "" "${MUTED_GRAY}→ http://${server_ip}:${gitea_port} | ssh://${server_ip}:${gitea_ssh}${RESET}"
    fi
    
    local torr_svc=$(get_service_status "torrserver" "user")
    local torr_ctr=$(get_container_status "torrserver" "user")
    print_metric "TorrServer" "$torr_svc $torr_ctr"
    
    # Показываем ссылки для TorrServer
    if podman ps --format "{{.Names}}" 2>/dev/null | grep -q "^systemd-torrserver$"; then
        local torr_port=$(podman port systemd-torrserver 2>/dev/null | grep "8090/tcp" | cut -d: -f2 || echo "8090")
        print_metric "" "${MUTED_GRAY}→ http://${server_ip}:${torr_port}${RESET}"
    fi

    print_section "Rootful Services (System)"
    local runner_svc=$(get_service_status "gitea-runner" "root")
    local runner_ctr=$(get_container_status "gitea-runner" "root")
    print_metric "Gitea Runner" "$runner_svc $runner_ctr"
    if sudo podman ps --format "{{.Names}}" 2>/dev/null | grep -q "^gitea-runner$"; then
        local runner_reg=$(sudo podman inspect --format='{{.Config.Env}}' gitea-runner 2>/dev/null | grep -o 'GITEA_INSTANCE_URL=[^ ]*' | cut -d= -f2 | cut -d/ -f3 || echo "unknown")
        print_metric "" "${MUTED_GRAY}→ $runner_reg${RESET}"
    fi

    local netbird_svc=$(get_service_status "netbird" "root")
    local netbird_ctr=$(get_container_status "netbird" "root")
    print_metric "NetBird VPN" "$netbird_svc $netbird_ctr"
    if sudo podman ps --format "{{.Names}}" 2>/dev/null | grep -q "^netbird$"; then
        local nb_ip=$(sudo podman exec netbird ip addr show wt0 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1 || echo "connecting...")
        if [ "$nb_ip" != "connecting..." ]; then
            print_metric "" "${MUTED_GRAY}→ IP: $nb_ip${RESET}"
            print_metric "" "${MUTED_GRAY}→ https://app.netbird.io/peers${RESET} ${NEON_CYAN}[dashboard]${RESET}"
        else
            print_metric "" "${NEON_YELLOW}→ $nb_ip${RESET}"
        fi
    fi

    print_section "Resources"
    local disk_info=$(df -h "$INFRA_DIR" 2>/dev/null | tail -1)
    local disk_usage=$(echo "$disk_info" | awk '{print $3 "/" $2 " (" $5 ")"}')
    local disk_dev=$(echo "$disk_info" | awk '{print $1}')
    local disk_type=$(get_disk_type "$disk_dev")
    local fs_type=$(df -T "$INFRA_DIR" 2>/dev/null | tail -1 | awk '{print $2}')
    
    # Цветная индикация типа диска
    case "$disk_type" in
        "SSD"|"NVMe")
            disk_type_colored="${NEON_GREEN}${disk_type}${RESET}"
            ;;
        "HDD")
            disk_type_colored="${NEON_YELLOW}${disk_type}${RESET}"
            ;;
        *)
            disk_type_colored="${DIM_GRAY}${disk_type}${RESET}"
            ;;
    esac
    
    print_metric "Disk" "$disk_usage ${NEON_CYAN}[${disk_type_colored}]${RESET} ${MUTED_GRAY}(${fs_type})${RESET}"
    
    local mem_info=$(free -h 2>/dev/null | awk '/^Mem:/ {print $3 "/" $2}')
    print_metric "Memory" "$mem_info"
    
    local swap_info=$(free -h 2>/dev/null | awk '/^Swap:/ {if ($2 != "0B") print $3 "/" $2; else print "disabled"}')
    print_metric "Swap" "$swap_info"
    
    local bbr_status=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -o 'bbr' || echo "off")
    if [ "$bbr_status" = "bbr" ]; then 
        print_metric "BBR" "${NEON_GREEN}enabled${RESET}"
    else 
        print_metric "BBR" "${DIM_GRAY}disabled${RESET}"
    fi
    
    local ctr_count=$(podman ps -q 2>/dev/null | wc -l)
    local ctr_total=$(podman ps -aq 2>/dev/null | wc -l)
    local root_ctr_count=$(sudo podman ps -q 2>/dev/null | wc -l)
    local root_ctr_total=$(sudo podman ps -aq 2>/dev/null | wc -l)
    print_metric "Containers" "${SOFT_WHITE}user:${RESET} ${NEON_CYAN}${ctr_count}${RESET}/${ctr_total} ${SOFT_WHITE}root:${RESET} ${NEON_CYAN}${root_ctr_count}${RESET}/${root_ctr_total}"

    print_section "Backup"
    if [ -d "$BACKUP_DIR/snapshots" ] || [ -f "$INFRA_DIR/.backup_configured" ]; then
        local last_backup="never"
        if [ -f "$INFRA_DIR/logs/backup.log" ]; then
            last_backup=$(grep -E "^[0-9]{4}-[0-9]{2}-[0-9]{2}" "$INFRA_DIR/logs/backup.log" 2>/dev/null | tail -1 | awk '{print $1 " " $2}' || echo "never")
        fi
        if [ -d "$BACKUP_DIR/snapshots" ] && [ "$last_backup" = "never" ]; then
            last_backup=$(ls -t "$BACKUP_DIR/snapshots"/*.tar.gz 2>/dev/null | head -1 | xargs stat -c %y 2>/dev/null | cut -d. -f1 || echo "never")
        fi
        local backup_count=$(ls -1 "$BACKUP_DIR/snapshots"/*.tar.gz 2>/dev/null | wc -l)
        print_metric "Status" "${ICON_OK} ${NEON_GREEN}configured${RESET}"
        print_metric "Last" "${last_backup:-never}"
        print_metric "Snapshots" "${NEON_CYAN}${backup_count}${RESET}"
        print_metric "Restic" "${MUTED_GRAY}infra backup-setup${RESET}"
    else
        print_metric "Status" "${DIM_GRAY}● not configured${RESET}"
        print_metric "Setup" "${MUTED_GRAY}infra backup-setup${RESET}"
    fi

    echo ""
    echo -e "${DIM_GRAY}──────────────────────────────────────────────────${RESET}"
    echo -e "${MUTED_GRAY}Commands: ${NEON_CYAN}start${RESET}|${NEON_CYAN}stop${RESET}|${NEON_CYAN}restart${RESET}|${NEON_CYAN}logs${RESET}|${NEON_CYAN}backup${RESET}|${NEON_CYAN}clear${RESET}"
}

case "${1:-status}" in
    status) status_cmd ;;
    logs) [ "$2" = "netbird" ] && sudo journalctl -u netbird -f || journalctl --user -u "$2" -f ;;
    stop)
        echo -e "${NEON_YELLOW}▸ Остановка сервисов...${RESET}"
        systemctl --user stop gitea torrserver 2>/dev/null && echo -e "  ${ICON_OK} Gitea/TorrServer" || echo -e "  ${DIM_GRAY}○ Gitea/TorrServer${RESET}"
        sudo systemctl stop gitea-runner netbird 2>/dev/null && echo -e "  ${ICON_OK} Runner/NetBird" || echo -e "  ${DIM_GRAY}○ Runner/NetBird${RESET}"
        ;;
    start)
        echo -e "${NEON_GREEN}▸ Запуск сервисов...${RESET}"
        systemctl --user start gitea torrserver 2>/dev/null && echo -e "  ${ICON_OK} Gitea/TorrServer" || echo -e "  ${ICON_FAIL} Gitea/TorrServer"
        sudo systemctl start gitea-runner netbird 2>/dev/null && echo -e "  ${ICON_OK} Runner/NetBird" || echo -e "  ${ICON_FAIL} Runner/NetBird"
        ;;
    restart)
        echo -e "${NEON_CYAN}▸ Перезапуск $2...${RESET}"
        if [ "$2" = "netbird" ] || [ "$2" = "gitea-runner" ]; then
            sudo systemctl restart "$2" && echo -e "  ${ICON_OK} $2 перезапущен" || echo -e "  ${ICON_FAIL} Ошибка"
        else
            systemctl --user restart "$2" && echo -e "  ${ICON_OK} $2 перезапущен" || echo -e "  ${ICON_FAIL} Ошибка"
        fi
        ;;
    clear)
        echo -e "${NEON_RED}▸ УДАЛЕНИЕ ВСЕЙ ИНФРАСТРУКТУРЫ${RESET}"
        read -rp "  Вы уверены? Все данные будут удалены [yes/N]: " CONFIRM
        if [ "$CONFIRM" = "yes" ]; then
            echo -e "  ${NEON_YELLOW}▸ Остановка сервисов...${RESET}"
            systemctl --user stop gitea torrserver 2>/dev/null
            sudo systemctl stop gitea-runner netbird 2>/dev/null
            
            echo -e "  ${NEON_YELLOW}▸ Удаление контейнеров...${RESET}"
            podman rm -f gitea torrserver 2>/dev/null
            sudo podman rm -f gitea-runner netbird 2>/dev/null
            
            echo -e "  ${NEON_YELLOW}▸ Удаление Quadlet файлов...${RESET}"
            rm -f ~/.config/containers/systemd/gitea.container ~/.config/containers/systemd/torrserver.container
            sudo rm -f /etc/containers/systemd/gitea-runner.container /etc/containers/systemd/netbird.container
            sudo rm -f /run/systemd/generator/*.service
            
            systemctl --user daemon-reload
            sudo systemctl daemon-reload
            
            read -rp "  Удалить директорию $INFRA_DIR с данными? [y/N]: " DEL_DATA
            if [[ "$DEL_DATA" =~ ^[Yy]$ ]]; then
                sudo rm -rf "$INFRA_DIR" /var/lib/gitea-runner /var/lib/netbird
            fi
            
            sudo rm -f /usr/local/bin/infra
            echo -e "${NEON_GREEN}${BOLD}╔════════════════════════════════════════════════╗${RESET}"
            echo -e "${NEON_GREEN}${BOLD}║     ИНФРАСТРУКТУРА ПОЛНОСТЬЮ УДАЛЕНА           ║${RESET}"
            echo -e "${NEON_GREEN}${BOLD}╚════════════════════════════════════════════════╝${RESET}"
        fi
        ;;
    backup)
        mkdir -p "$BACKUP_DIR/snapshots"
        backup_time=$(date +%Y%m%d-%H%M%S)
        SNAPSHOT="$BACKUP_DIR/snapshots/infra-$backup_time.tar.gz"
        echo -e "${NEON_CYAN}▸ Создание бэкапа...${RESET}"
        if podman run --rm -v "$VOLUMES_DIR:/data:ro" -v "$BACKUP_DIR/snapshots:/backup:Z" docker.io/library/alpine:latest tar -czf "/backup/$(basename $SNAPSHOT)" -C /data . 2>/dev/null; then
            sudo chown $USER:$USER "$SNAPSHOT" 2>/dev/null
            size=$(du -h "$SNAPSHOT" 2>/dev/null | cut -f1)
            if [ -n "$size" ]; then
                echo -e "  ${ICON_OK} Локальный архив создан: $(basename $SNAPSHOT) ($size)"
            else
                echo -e "  ${ICON_OK} Локальный архив создан: $(basename $SNAPSHOT)"
            fi
        else
            echo -e "  ${ICON_WARN} Директория volumes пуста"
        fi
        ;;
    backup-setup)
        echo -e "${NEON_CYAN}▸ Настройка бэкапов (Restic)${RESET}"
        echo ""
        echo "  Выберите backend:"
        echo -e "  ${NEON_CYAN}1)${RESET} Локальная директория"
        echo -e "  ${NEON_CYAN}2)${RESET} SFTP (user@host:/path)"
        echo -e "  ${NEON_CYAN}3)${RESET} S3 (s3:s3.amazonaws.com/bucket)"
        echo -e "  ${NEON_CYAN}4)${RESET} rclone (rclone:remote:path)"
        read -rp "  Backend [1-4]: " BACKEND_TYPE

        REPO=""; REPO_PATH=""; AWS_KEY=""; AWS_SECRET=""; LOCAL_PATH=""
        case "$BACKEND_TYPE" in
            1) read -rp "  Путь для бэкапов [/backup/infra]: " REPO_PATH
               REPO_PATH="${REPO_PATH:-/backup/infra}"
               REPO="local:${REPO_PATH}"
               LOCAL_PATH="$REPO_PATH"
               sudo mkdir -p "$LOCAL_PATH" ;;
            2) read -rp "  SFTP адрес (user@host:/path): " REPO_PATH
               REPO="sftp:${REPO_PATH}" ;;
            3) read -rp "  S3 endpoint (s3:host:port/bucket): " REPO_PATH
               REPO="$REPO_PATH"
               read -rp "  AWS_ACCESS_KEY_ID: " AWS_KEY
               read -rp "  AWS_SECRET_ACCESS_KEY: " AWS_SECRET ;;
            4) read -rp "  rclone remote (rclone:remote:path): " REPO_PATH
               REPO="$REPO_PATH" ;;
            *) echo -e "  ${ICON_FAIL} Неверный выбор"; exit 1 ;;
        esac
        read -rsp "  Пароль для шифрования бэкапов: " RESTIC_PASS
        echo ""
        read -rp "  Время автобэкапа [0 2 * * *]: " CRON_TIME
        CRON_TIME="${CRON_TIME:-0 2 * * *}"
        
        mkdir -p "$BACKUP_DIR/cache"
        cat > "$INFRA_DIR/.backup_env" <<EOENV
RESTIC_REPOSITORY=$REPO
RESTIC_PASSWORD=$RESTIC_PASS
EOENV
        [ -n "${AWS_KEY:-}" ] && echo "AWS_ACCESS_KEY_ID=$AWS_KEY" >> "$INFRA_DIR/.backup_env"
        [ -n "${AWS_SECRET:-}" ] && echo "AWS_SECRET_ACCESS_KEY=$AWS_SECRET" >> "$INFRA_DIR/.backup_env"
        chmod 600 "$INFRA_DIR/.backup_env"
        
        echo -e "  ${NEON_CYAN}▸ Инициализация репозитория...${RESET}"
        podman run --rm \
            -e RESTIC_REPOSITORY="$REPO" \
            -e RESTIC_PASSWORD="$RESTIC_PASS" \
            ${AWS_KEY:+-e AWS_ACCESS_KEY_ID="$AWS_KEY"} \
            ${AWS_SECRET:+-e AWS_SECRET_ACCESS_KEY="$AWS_SECRET"} \
            -v "$BACKUP_DIR/cache:/cache" \
            ${LOCAL_PATH:+-v "$LOCAL_PATH:$LOCAL_PATH:Z"} \
            docker.io/restic/restic:latest \
            init --cache-dir=/cache 2>/dev/null && \
            echo -e "  ${ICON_OK} Репозиторий инициализирован" || \
            echo -e "  ${ICON_WARN} Репозиторий уже существует"
        
        touch "$INFRA_DIR/.backup_configured"
        ( crontab -l 2>/dev/null | grep -v "infra backup" || true; echo "$CRON_TIME $INFRA_DIR/bin/infra backup >> $INFRA_DIR/logs/backup.log 2>&1" ) | crontab -
        echo -e "  ${ICON_OK} ${NEON_GREEN}Бэкап настроен${RESET}"
        echo -e "  ${MUTED_GRAY}Репозиторий: $REPO${RESET}"
        ;;
    backup-list)
        echo -e "${NEON_CYAN}▸ Локальные архивы:${RESET}"
        ls -lh "$BACKUP_DIR/snapshots"/*.tar.gz 2>/dev/null | awk '{printf "  %s %s %s\n", $6, $7, $9}' | sed 's|.*/||' || echo "  Нет локальных архивов"
        if [ -f "$INFRA_DIR/.backup_configured" ]; then
            echo ""
            echo -e "${NEON_CYAN}▸ Restic снапшоты:${RESET}"
            source "$INFRA_DIR/.backup_env"
            podman run --rm \
                -e RESTIC_REPOSITORY="$RESTIC_REPOSITORY" \
                -e RESTIC_PASSWORD="$RESTIC_PASSWORD" \
                -v "$BACKUP_DIR/cache:/cache" \
                docker.io/restic/restic:latest \
                snapshots --cache-dir=/cache 2>/dev/null || echo "  Нет снапшотов"
        fi
        ;;
    backup-restore)
        if [ ! -f "$INFRA_DIR/.backup_configured" ]; then 
            echo -e "${ICON_FAIL} Бэкап не настроен"
            exit 1
        fi
        source "$INFRA_DIR/.backup_env"
        echo -e "${NEON_CYAN}▸ Доступные снапшоты:${RESET}"
        podman run --rm \
            -e RESTIC_REPOSITORY="$RESTIC_REPOSITORY" \
            -e RESTIC_PASSWORD="$RESTIC_PASSWORD" \
            -v "$BACKUP_DIR/cache:/cache" \
            docker.io/restic/restic:latest \
            snapshots --cache-dir=/cache
        echo ""
        read -rp "  ID снапшота [latest]: " SNAP_ID
        SNAP_ID="${SNAP_ID:-latest}"
        read -rp "  Остановить сервисы? [Y/n]: " STOP_SERV
        if [[ ! "${STOP_SERV:-Y}" =~ ^[Nn]$ ]]; then
            systemctl --user stop gitea torrserver 2>/dev/null
            sudo systemctl stop gitea-runner netbird 2>/dev/null
        fi
        echo -e "  ${NEON_CYAN}▸ Восстановление...${RESET}"
        podman run --rm \
            -e RESTIC_REPOSITORY="$RESTIC_REPOSITORY" \
            -e RESTIC_PASSWORD="$RESTIC_PASSWORD" \
            -v "$INFRA_DIR:/restore:Z" \
            -v "$BACKUP_DIR/cache:/cache" \
            docker.io/restic/restic:latest \
            restore "$SNAP_ID" --target /restore --cache-dir=/cache
        ;;
    restore-local)
        echo -e "${NEON_CYAN}▸ Восстановление из локального архива${RESET}"
        local archives=( $(ls -t "$BACKUP_DIR/snapshots"/*.tar.gz 2>/dev/null) )
        if [ ${#archives[@]} -eq 0 ]; then
            echo -e "  ${ICON_FAIL} Архивы не найдены"
            exit 1
        fi
        echo ""
        for i in "${!archives[@]}"; do
            local size=$(du -h "${archives[$i]}" | cut -f1)
            printf "  ${NEON_CYAN}%2d)${RESET} %s ${DIM_GRAY}(%s)${RESET}\n" $((i+1)) "$(basename "${archives[$i]}")" "$size"
        done
        echo ""
        read -rp "  Выберите архив: " num
        local selected="${archives[$((num-1))]}"
        
        read -rp "  Остановить сервисы? [Y/n]: " STOP_SERV
        if [[ ! "${STOP_SERV:-Y}" =~ ^[Nn]$ ]]; then
            systemctl --user stop gitea torrserver 2>/dev/null
            sudo systemctl stop gitea-runner netbird 2>/dev/null
        fi
        
        echo -e "  ${NEON_CYAN}▸ Распаковка...${RESET}"
        if tar -xzf "$selected" -C "$VOLUMES_DIR" 2>/dev/null; then
            chown -R $USER:$USER "$VOLUMES_DIR" 2>/dev/null
            echo -e "  ${ICON_OK} ${NEON_GREEN}Восстановление завершено${RESET}"
        else
            echo -e "  ${ICON_FAIL} ${NEON_RED}Ошибка распаковки${RESET}"
        fi
        ;;
    update)
        echo -e "${NEON_CYAN}▸ Принудительное обновление контейнеров...${RESET}"
        echo -e "  ${NEON_YELLOW}Rootless контейнеры...${RESET}"
        systemctl --user stop gitea torrserver 2>/dev/null
        podman auto-update --rollback 2>/dev/null && echo -e "    ${ICON_OK} Обновлено" || echo -e "    ${ICON_INFO} Нет обновлений"
        systemctl --user start gitea torrserver 2>/dev/null
        
        echo -e "  ${NEON_YELLOW}Rootful контейнеры...${RESET}"
        sudo systemctl stop gitea-runner netbird 2>/dev/null
        sudo podman auto-update --rollback 2>/dev/null && echo -e "    ${ICON_OK} Обновлено" || echo -e "    ${ICON_INFO} Нет обновлений"
        sudo systemctl start gitea-runner netbird 2>/dev/null
        echo -e "  ${ICON_OK} ${NEON_GREEN}Обновление завершено${RESET}"
        ;;
    *) echo "Использование: infra {status|start|stop|restart <svc>|logs <svc>|clear|backup|backup-setup|backup-list|backup-restore|restore-local|update}" ;;
esac
ENDOFCLI

chmod +x "$BIN_DIR/infra"
sudo ln -sf "$BIN_DIR/infra" /usr/local/bin/infra 2>/dev/null || true

# =============== CRON ===============
print_step "Настройка cron"
(crontab -l 2>/dev/null | grep -v "infra" || true; echo "*/5 * * * * $BIN_DIR/infra status > /dev/null 2>&1") | crontab - 2>/dev/null || true

# =============== САМОУДАЛЕНИЕ ===============
print_step "Завершение"
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
if [ -f "$SCRIPT_PATH" ] && [ "$SCRIPT_PATH" != "$BIN_DIR/infra" ] && [ "$SCRIPT_PATH" != "/usr/local/bin/infra" ]; then
    rm -f "$SCRIPT_PATH"
    print_success "Скрипт удалён"
fi

# =============== ИТОГ ===============
print_header "ГОТОВО v10.0.0"
echo -e "${NEON_GREEN}●${RESET} Gitea:      ${NEON_CYAN}http://$SERVER_IP:3000${RESET}"
echo -e "${NEON_GREEN}●${RESET} TorrServer: ${NEON_CYAN}http://$SERVER_IP:8090${RESET}"
echo -e "${NEON_GREEN}●${RESET} Runner:     ${NEON_CYAN}sudo systemctl status gitea-runner${RESET}"
echo -e "${NEON_GREEN}●${RESET} NetBird:    ${NEON_CYAN}sudo systemctl status netbird${RESET}"
echo -e "\nУправление: ${NEON_CYAN}infra status${RESET}"
echo -e "Логи:       ${NEON_CYAN}infra logs${RESET}"
