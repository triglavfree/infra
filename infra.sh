#!/bin/bash
set -uo pipefail
# =============================================================================
# INFRASTRUCTURE v9.4.0
# =============================================================================

# Цвета через tput (более надежный способ)
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
    NEON_CYAN=""
    NEON_GREEN=""
    NEON_YELLOW=""
    NEON_RED=""
    NEON_PURPLE=""
    NEON_BLUE=""
    SOFT_WHITE=""
    MUTED_GRAY=""
    DIM_GRAY=""
    BOLD=""
    RESET=""
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

print_header "INFRASTRUCTURE v9.4.0"
print_info "User: $CURRENT_USER | UID: $CURRENT_UID | IP: $SERVER_IP"

# =============== КАТАЛОГИ С ПРАВАМИ ===============
print_step "Создание структуры"

INFRA_DIR="$CURRENT_HOME/infra"
VOLUMES_DIR="$INFRA_DIR/volumes"
BIN_DIR="$INFRA_DIR/bin"
LOGS_DIR="$INFRA_DIR/logs"
BACKUP_DIR="$INFRA_DIR/backups"

for dir in "$INFRA_DIR" "$VOLUMES_DIR" "$BIN_DIR" "$LOGS_DIR" "$BACKUP_DIR" "$BACKUP_DIR/cache"            "$VOLUMES_DIR"/{gitea,torrserver,dockge}; do
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        chown "$CURRENT_USER:$CURRENT_USER" "$dir"
        chmod 755 "$dir"
    fi
done
print_success "Директории созданы с правами $CURRENT_USER"

# =============== BOOTSTRAP ===============
print_step "Подготовка системы"

if [ ! -f "$INFRA_DIR/.bootstrap_done" ]; then
    print_info "Настройка системы..."

    # Расчет swap = RAM * 2, но не более 8GB
    RAM_MB=$(free -m | awk '/^Mem:/ {print $2}')
    SWAP_MB=$((RAM_MB * 2))
    if [ $SWAP_MB -gt 8192 ]; then SWAP_MB=8192; fi

    sudo bash -c "
        # Обновление системы
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq >/dev/null 2>&1
        apt-get upgrade -y -qq >/dev/null 2>&1 || true

        # Установка необходимых пакетов + ufw + fail2ban
        apt-get install -y -qq podman podman-docker uidmap slirp4netns fuse-overlayfs curl openssl ufw fail2ban >/dev/null 2>&1 || true

        # Настройка swap
        if [ ! -f /swapfile ] && [ \$(free | grep -c Swap) -eq 0 ] || [ \$(free | awk '/^Swap:/ {print \$2}') -eq 0 ]; then
            fallocate -l ${SWAP_MB}M /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=${SWAP_MB} 2>/dev/null
            chmod 600 /swapfile
            mkswap /swapfile >/dev/null 2>&1
            swapon /swapfile >/dev/null 2>&1
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
            sysctl vm.swappiness=10 >/dev/null 2>&1
            echo 'vm.swappiness=10' >> /etc/sysctl.conf
        fi

        # Включение BBR
        if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
            echo 'net.core.default_qdisc=fq' >> /etc/sysctl.conf
            echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.conf
            sysctl -p >/dev/null 2>&1
        fi

        # Оптимизация сети
        echo 'net.ipv4.tcp_fastopen=3' >> /etc/sysctl.conf
        echo 'net.ipv4.tcp_tw_reuse=1' >> /etc/sysctl.conf
        echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1

        # Настройка subuid/subgid для rootless
        if ! grep -q '$CURRENT_USER:' /etc/subuid 2>/dev/null; then
            usermod --add-subuids 100000-165535 --add-subgids 100000-165535 '$CURRENT_USER' 2>/dev/null || true
        fi

        # Создание runtime директории
        mkdir -p /run/user/$CURRENT_UID
        chown $CURRENT_USER:$CURRENT_USER /run/user/$CURRENT_UID
        chmod 700 /run/user/$CURRENT_UID

        # Директории для rootful сервисов
        mkdir -p /var/lib/gitea-runner /var/lib/netbird
        chmod 755 /var/lib/gitea-runner /var/lib/netbird

        # === UFW НАСТРОЙКА ===
        ufw --force reset >/dev/null 2>&1
        ufw default deny incoming >/dev/null 2>&1
        ufw default allow outgoing >/dev/null 2>&1
        # SSH
        ufw allow 22/tcp comment 'SSH' >/dev/null 2>&1
        # Gitea
        ufw allow 3000/tcp comment 'Gitea HTTP' >/dev/null 2>&1
        ufw allow 2222/tcp comment 'Gitea SSH' >/dev/null 2>&1
        # TorrServer
        ufw allow 8090/tcp comment 'TorrServer' >/dev/null 2>&1
        # Dockge
        ufw allow 5001/tcp comment 'Dockge' >/dev/null 2>&1
        # NetBird (WireGuard)
        ufw allow 51820/udp comment 'WireGuard' >/dev/null 2>&1
        # Включение UFW
        ufw --force enable >/dev/null 2>&1

        # === FAIL2BAN НАСТРОЙКА ===
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

[nginx-http-auth]
enabled = false

[nginx-noscript]
enabled = false
EOFAIL
        systemctl restart fail2ban >/dev/null 2>&1 || true
        systemctl enable fail2ban >/dev/null 2>&1 || true

        # === SSH HARDENING ===
        # Проверяем наличие SSH ключей у текущего пользователя
        if [ -d '$CURRENT_HOME/.ssh' ] && [ -n '\$(ls -A $CURRENT_HOME/.ssh/*.pub 2>/dev/null)' ]; then
            # Ключи есть - отключаем парольную аутентификацию
            sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
            sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
            sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
            echo 'AuthenticationMethods publickey' >> /etc/ssh/sshd_config
            systemctl restart sshd >/dev/null 2>&1 || true
        else
            # Ключей нет - предупреждаем но не отключаем пароли
            echo 'SSH_KEYS_MISSING' > /tmp/ssh_status
        fi
    "

    # Проверяем статус SSH
    if [ -f /tmp/ssh_status ]; then
        rm -f /tmp/ssh_status
        print_warning "SSH ключи не найдены! Парольная аутентификация оставлена включенной"
        print_info "Добавьте ключ: ssh-copy-id user@$SERVER_IP"
    else
        print_success "SSH hardening применен (ключи найдены, пароли отключены)"
    fi

    touch "$INFRA_DIR/.bootstrap_done"
    print_success "Система настроена (swap: ${SWAP_MB}MB, BBR: enabled, UFW: enabled, fail2ban: enabled)"
else
    print_info "Bootstrap уже выполнен"
fi

sudo loginctl enable-linger "$CURRENT_USER" 2>/dev/null || true

# =============== PODMAN AUTO-UPDATE ===============
print_step "Настройка авто-обновления контейнеров"

# Для rootless контейнеров - включаем user timer
if ! systemctl --user is-enabled podman-auto-update.timer >/dev/null 2>&1; then
    systemctl --user enable podman-auto-update.timer 2>/dev/null || true
    systemctl --user start podman-auto-update.timer 2>/dev/null || true
    print_success "Rootless auto-update timer включен"
else
    print_info "Rootless auto-update timer уже активен"
fi

# Для rootful контейнеров - включаем system timer
if ! sudo systemctl is-enabled podman-auto-update.timer >/dev/null 2>&1; then
    sudo systemctl enable podman-auto-update.timer 2>/dev/null || true
    sudo systemctl start podman-auto-update.timer 2>/dev/null || true
    print_success "Rootful auto-update timer включен"
else
    print_info "Rootful auto-update timer уже активен"
fi

# Добавляем label для auto-update в сервисы systemd
print_info "Контейнеры будут обновляться автоматически (проверка каждые 5 минут)"

# =============== CLI ===============
cat > "$BIN_DIR/infra" <<'ENDOFCLI'
#!/bin/bash
INFRA_DIR="$HOME/infra"
VOLUMES_DIR="$INFRA_DIR/volumes"
BACKUP_DIR="$INFRA_DIR/backups"

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
    local time_str
    time_str=$(date +%H:%M:%S)
    local full_title="${title} ${time_str}"
    echo ""
    echo -e "${NEON_CYAN}══════════════════════════════════════════════════${RESET}"
    printf "${NEON_CYAN}║${RESET} ${BOLD}%-48s${RESET} ${NEON_CYAN}║${RESET}\n" "$full_title"
    echo -e "${NEON_CYAN}══════════════════════════════════════════════════${RESET}"
}

print_section() {
    echo ""
    echo -e "${NEON_PURPLE}${ICON_ARROW}${RESET} ${BOLD}$1${RESET}"
    echo -e "${DIM_GRAY}────────────────────────────────────────────────${RESET}"
}

print_metric() {
    printf "  ${DIM_GRAY}%-12s${RESET} %s\n" "$1" "$2"
}

get_container_status() {
    local name=$1
    local user=$2
    local runtime=""
    if [ "$user" = "root" ]; then runtime="sudo podman"; else runtime="podman"; fi

    if $runtime ps --format "{{.Names}}" 2>/dev/null | grep -q "^${name}$"; then
        local health=$($runtime inspect --format='{{.State.Health.Status}}' "$name" 2>/dev/null || echo "no-check")
        local started_at=$($runtime inspect --format='{{.State.StartedAt}}' "$name" 2>/dev/null || echo "")
        local uptime_str="unknown"

        if [ -n "$started_at" ] && [ "$started_at" != "0001-01-01T00:00:00Z" ]; then
            local start_epoch=$(date -d "$started_at" +%s 2>/dev/null || echo "0")
            local now_epoch=$(date +%s)
            if [ "$start_epoch" != "0" ]; then
                local diff=$((now_epoch - start_epoch))
                if [ $diff -lt 60 ]; then uptime_str="${diff}s"
                elif [ $diff -lt 3600 ]; then uptime_str="$((diff / 60))m"
                else uptime_str="$((diff / 3600))h$((diff % 3600 / 60))m"; fi
            fi
        fi

        if [ "$health" = "healthy" ] || [ "$health" = "no-check" ]; then
            echo -e "${ICON_OK} ${NEON_GREEN}running${RESET} ${DIM_GRAY}(${uptime_str})${RESET}"
        else
            echo -e "${ICON_WARN} ${NEON_YELLOW}unhealthy${RESET} ${DIM_GRAY}(${uptime_str})${RESET}"
        fi
    else
        if $runtime ps -a --format "{{.Names}}" 2>/dev/null | grep -q "^${name}$"; then
            echo -e "${ICON_FAIL} ${NEON_RED}stopped${RESET}"
        else
            echo -e "${DIM_GRAY}● not created${RESET}"
        fi
    fi
}

get_service_status() {
    local name=$1
    local user=$2
    if [ "$user" = "root" ]; then
        if systemctl is-active --quiet "$name" 2>/dev/null; then echo -e "${ICON_OK} ${NEON_GREEN}active${RESET}"
        elif systemctl is-failed --quiet "$name" 2>/dev/null; then echo -e "${ICON_FAIL} ${NEON_RED}failed${RESET}"
        else echo -e "${DIM_GRAY}● inactive${RESET}"; fi
    else
        if systemctl --user is-active --quiet "$name" 2>/dev/null; then echo -e "${ICON_OK} ${NEON_GREEN}active${RESET}"
        elif systemctl --user is-failed --quiet "$name" 2>/dev/null; then echo -e "${ICON_FAIL} ${NEON_RED}failed${RESET}"
        else echo -e "${DIM_GRAY}● inactive${RESET}"; fi
    fi
}

get_disk_type() {
    local disk=$1
    local disk_type="unknown"
    if [[ "$disk" == *"nvme"* ]]; then disk_type="NVMe"
    elif [ -f "/sys/block/$(basename $disk)/queue/rotational" ]; then
        local rotational=$(cat "/sys/block/$(basename $disk)/queue/rotational" 2>/dev/null || echo "1")
        if [ "$rotational" = "0" ]; then disk_type="SSD"; else disk_type="HDD"; fi
    fi
    echo "$disk_type"
}

# Получение количества снапшотов restic
get_backup_count() {
    local count=0
    if [ -f "$INFRA_DIR/.backup_env" ]; then
        source "$INFRA_DIR/.backup_env"
        # Используем restic snapshots с json выводом
        local snapshots_json
        snapshots_json=$(podman run --rm \
            -e RESTIC_REPOSITORY="$RESTIC_REPOSITORY" \
            -e RESTIC_PASSWORD="$RESTIC_PASSWORD" \
            ${AWS_ACCESS_KEY_ID:+-e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID"} \
            ${AWS_SECRET_ACCESS_KEY:+-e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"} \
            -v "$BACKUP_DIR/cache:/cache" \
            docker.io/restic/restic:latest \
            snapshots --cache-dir=/cache --json 2>/dev/null)

        if [ -n "$snapshots_json" ] && [ "$snapshots_json" != "null" ]; then
            # Парсим JSON массив - считаем количество объектов
            count=$(echo "$snapshots_json" | grep -c '"time"' || echo "0")
        fi

        # Fallback если json не сработал
        if [ "$count" = "0" ]; then
            local snapshots_text
            snapshots_text=$(podman run --rm \
                -e RESTIC_REPOSITORY="$RESTIC_REPOSITORY" \
                -e RESTIC_PASSWORD="$RESTIC_PASSWORD" \
                ${AWS_ACCESS_KEY_ID:+-e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID"} \
                ${AWS_SECRET_ACCESS_KEY:+-e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"} \
                -v "$BACKUP_DIR/cache:/cache" \
                docker.io/restic/restic:latest \
                snapshots --cache-dir=/cache 2>/dev/null | grep -E '^[0-9a-f]{8}' | wc -l)
            count=${snapshots_text:-0}
        fi
    fi
    echo "$count"
}

status_cmd() {
    clear
    print_box "INFRASTRUCTURE STATUS"
    local server_ip; server_ip=$(hostname -I | awk '{print $1}')

    print_section "Rootless Services (User: $USER)"
    local gitea_svc=$(get_service_status "gitea" "user")
    local gitea_ctr=$(get_container_status "gitea" "user")
    print_metric "Gitea" "$gitea_svc $gitea_ctr"

    local dockge_svc=$(get_service_status "dockge" "user")
    local dockge_ctr=$(get_container_status "dockge" "user")
    print_metric "Dockge" "$dockge_svc $dockge_ctr"
    if podman ps --format "{{.Names}}" 2>/dev/null | grep -q "^dockge$"; then
        print_metric "" "${MUTED_GRAY}http://${server_ip}:5001${RESET}"
    fi
    if podman ps --format "{{.Names}}" 2>/dev/null | grep -q "^gitea$"; then
        local gitea_port=$(podman port gitea 2>/dev/null | grep "3000/tcp" | cut -d: -f2 || echo "3000")
        local gitea_ssh=$(podman port gitea 2>/dev/null | grep "2222/tcp" | cut -d: -f2 || echo "2222")
        if [ -n "$gitea_ssh" ]; then
            print_metric "" "${MUTED_GRAY}http://${server_ip}:${gitea_port} | ssh://${server_ip}:${gitea_ssh}${RESET}"
        else
            print_metric "" "${MUTED_GRAY}http://${server_ip}:${gitea_port}${RESET}"
        fi
    fi

    local torr_svc=$(get_service_status "torrserver" "user")
    local torr_ctr=$(get_container_status "torrserver" "user")
    print_metric "TorrServer" "$torr_svc $torr_ctr"
    if systemctl --user is-active --quiet torrserver 2>/dev/null || podman ps -a --format "{{.Names}}" 2>/dev/null | grep -q "^torrserver$"; then
        local torr_port=$(podman port torrserver 2>/dev/null | grep "8090/tcp" | cut -d: -f2 || echo "8090")
        print_metric "" "${MUTED_GRAY}http://${server_ip}:${torr_port}${RESET}"
    fi

    print_section "Rootful Services (System)"
    local runner_svc=$(get_service_status "gitea-runner" "root")
    local runner_ctr=$(get_container_status "gitea-runner" "root")
    print_metric "Gitea Runner" "$runner_svc $runner_ctr"
    if sudo podman ps --format "{{.Names}}" 2>/dev/null | grep -q "^gitea-runner$"; then
        local runner_reg=$(sudo podman inspect --format='{{.Config.Env}}' gitea-runner 2>/dev/null | grep -o 'GITEA_INSTANCE_URL=[^ ]*' | cut -d= -f2 | cut -d/ -f3 || echo "unknown")
        print_metric "" "${MUTED_GRAY}-> $runner_reg${RESET}"
    fi

    local netbird_svc=$(get_service_status "netbird" "root")
    local netbird_ctr=$(get_container_status "netbird" "root")
    print_metric "NetBird VPN" "$netbird_svc $netbird_ctr"
    if sudo podman ps --format "{{.Names}}" 2>/dev/null | grep -q "^netbird$"; then
        local nb_ip=$(sudo podman exec netbird ip addr show wt0 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1 || echo "connecting...")
        [ "$nb_ip" != "connecting..." ] && print_metric "" "${MUTED_GRAY}IP: $nb_ip${RESET}" || print_metric "" "${NEON_YELLOW}Connecting...${RESET}"
    fi

    print_section "Resources"
    local disk_info=$(df -h "$INFRA_DIR" 2>/dev/null | tail -1)
    local disk_usage=$(echo "$disk_info" | awk '{print $3 "/" $2 " (" $5 ")"}')
    local disk_dev=$(echo "$disk_info" | awk '{print $1}' | sed 's/[0-9]*$//' | sed 's/p[0-9]*$//')
    local disk_type=$(get_disk_type "$disk_dev")
    print_metric "Disk" "$disk_usage ${NEON_CYAN}[${disk_type}]${RESET}"

    local mem_info=$(free -h 2>/dev/null | awk '/^Mem:/ {print $3 "/" $2}')
    print_metric "Memory" "$mem_info"

    local swap_info=$(free -h 2>/dev/null | awk '/^Swap:/ {if ($2 != "0B" && $2 != "0") print $3 "/" $2; else print "disabled"}')
    print_metric "Swap" "$swap_info"

    local bbr_status=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -o 'bbr' || echo "off")
    if [ "$bbr_status" = "bbr" ]; then print_metric "BBR" "${NEON_GREEN}enabled${RESET}"
    else print_metric "BBR" "${DIM_GRAY}disabled${RESET}"; fi

    local ctr_count=$(podman ps -q 2>/dev/null | wc -l)
    local ctr_total=$(podman ps -aq 2>/dev/null | wc -l)
    local root_ctr_count=$(sudo podman ps -q 2>/dev/null | wc -l)
    local root_ctr_total=$(sudo podman ps -aq 2>/dev/null | wc -l)
    print_metric "Containers" "${SOFT_WHITE}user:${RESET} ${NEON_CYAN}${ctr_count}${RESET}/${ctr_total} ${SOFT_WHITE}root:${RESET} ${NEON_CYAN}${root_ctr_count}${RESET}/${root_ctr_total}"

    print_section "Security"
    local ufw_status=$(sudo ufw status 2>/dev/null | grep -i "status:" | awk '{print $2}' || echo "unknown")
    if [ "$ufw_status" = "active" ]; then print_metric "UFW" "${NEON_GREEN}${ufw_status}${RESET}"
    else print_metric "UFW" "${NEON_RED}${ufw_status}${RESET}"; fi

    local f2b_status=$(sudo systemctl is-active fail2ban 2>/dev/null || echo "inactive")
    if [ "$f2b_status" = "active" ]; then print_metric "Fail2Ban" "${NEON_GREEN}${f2b_status}${RESET}"
    else print_metric "Fail2Ban" "${NEON_RED}${f2b_status}${RESET}"; fi

    local ssh_pass=$(grep -E "^PasswordAuthentication" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "yes")
    if [ "$ssh_pass" = "no" ]; then print_metric "SSH Auth" "${NEON_GREEN}key-only${RESET}"
    else print_metric "SSH Auth" "${NEON_YELLOW}password${RESET}"; fi

    print_section "Backup"
    if [ -f "$INFRA_DIR/.backup_configured" ]; then
        local last_backup="never"
        if [ -f "$INFRA_DIR/logs/backup.log" ]; then
            # Ищем строку с датой вида YYYY-MM-DD HH:MM:SS перед "saved"
            last_backup=$(grep -E "^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}" "$INFRA_DIR/logs/backup.log" 2>/dev/null | grep "saved" | tail -1 | awk '{print $1 " " $2}' || echo "never")
            [ -z "$last_backup" ] && last_backup="never"
        fi

        # Используем функцию для получения количества снапшотов
        local backup_count=$(get_backup_count)

        print_metric "Status" "${ICON_OK} ${NEON_GREEN}configured${RESET}"
        print_metric "Last" "$last_backup"
        print_metric "Snapshots" "${NEON_CYAN}${backup_count}${RESET}"
    else
        print_metric "Status" "${DIM_GRAY}● not configured${RESET}"
        print_metric "Setup" "${MUTED_GRAY}infra backup-setup${RESET}"
    fi

    echo ""
    echo -e "${DIM_GRAY}────────────────────────────────────────────────${RESET}"
    echo -e "${MUTED_GRAY}Commands: ${NEON_CYAN}start${RESET}|${NEON_CYAN}stop${RESET}|${NEON_CYAN}restart${RESET}|${NEON_CYAN}logs${RESET}|${NEON_CYAN}backup${RESET}|${NEON_CYAN}clear${RESET}"
}

case "${1:-status}" in
    status) status_cmd ;;
    logs) [ "$2" = "netbird" ] && sudo journalctl -u netbird -f || journalctl --user -u "$2" -f ;;
    stop)
        echo -e "${NEON_YELLOW}▸ Остановка сервисов...${RESET}"
        systemctl --user stop gitea torrserver dockge 2>/dev/null && echo -e "  ${ICON_OK} Gitea/TorrServer" || echo -e "  ${DIM_GRAY}○ Gitea/TorrServer${RESET}"
        sudo systemctl stop gitea-runner netbird 2>/dev/null && echo -e "  ${ICON_OK} Runner/NetBird" || echo -e "  ${DIM_GRAY}○ Runner/NetBird${RESET}"
        ;;
    start)
        echo -e "${NEON_GREEN}▸ Запуск сервисов...${RESET}"
        systemctl --user start gitea torrserver dockge 2>/dev/null && echo -e "  ${ICON_OK} Gitea/TorrServer" || echo -e "  ${ICON_FAIL} Gitea/TorrServer"
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
            systemctl --user stop gitea torrserver dockge 2>/dev/null || true
            echo -e "    ${ICON_OK} User сервисы остановлены"
            sudo systemctl stop gitea-runner netbird 2>/dev/null || true
            sudo systemctl disable gitea-runner netbird 2>/dev/null || true
            echo -e "    ${ICON_OK} Rootful сервисы остановлены"

            echo -e "  ${NEON_YELLOW}▸ Удаление контейнеров...${RESET}"
            podman rm -f gitea torrserver dockge 2>/dev/null || true
            echo -e "    ${ICON_OK} User контейнеры удалены"
            sudo podman rm -f gitea-runner netbird 2>/dev/null || true
            echo -e "    ${ICON_OK} Rootful контейнеры удалены"

            echo -e "  ${NEON_YELLOW}▸ Удаление образов...${RESET}"
            podman rmi -f $(podman images -q) 2>/dev/null || true
            sudo podman rmi -f $(sudo podman images -q) 2>/dev/null || true
            echo -e "    ${ICON_OK} Образы удалены"

            echo -e "  ${NEON_YELLOW}▸ Очистка Podman...${RESET}"
            podman system prune -f 2>/dev/null || true
            sudo podman system prune -f 2>/dev/null || true
            echo -e "    ${ICON_OK} Podman очищен"

            echo -e "  ${NEON_YELLOW}▸ Удаление systemd units...${RESET}"
            rm -f ~/.config/systemd/user/gitea.service ~/.config/systemd/user/torrserver.service ~/.config/systemd/user/dockge.service
            sudo rm -f /etc/systemd/system/gitea-runner.service /etc/systemd/system/netbird.service
            systemctl --user daemon-reload
            sudo systemctl daemon-reload
            echo -e "    ${ICON_OK} Units удалены"

            echo -e "  ${NEON_YELLOW}▸ Удаление cron задач...${RESET}"
            ( crontab -l 2>/dev/null | grep -v "infra" | grep -v "restic" || true ) | crontab - 2>/dev/null || true
            echo -e "    ${ICON_OK} Cron очищен"

            read -rp "  Удалить директорию $INFRA_DIR с данными? [y/N]: " DEL_DATA
            if [[ "$DEL_DATA" =~ ^[Yy]$ ]]; then
                echo -e "  ${NEON_YELLOW}▸ Удаление данных...${RESET}"
                sudo rm -rf "$INFRA_DIR"
                sudo rm -rf /var/lib/gitea-runner /var/lib/netbird
                echo -e "    ${ICON_OK} Данные удалены"
            else
                echo -e "  ${ICON_INFO} Директория сохранена: $INFRA_DIR"
            fi

            echo -e "  ${NEON_YELLOW}▸ Удаление CLI...${RESET}"
            sudo rm -f /usr/local/bin/infra

            echo ""
            echo -e "${NEON_GREEN}${BOLD}╔════════════════════════════════════════════════╗${RESET}"
            echo -e "${NEON_GREEN}${BOLD}║     ИНФРАСТРУКТУРА ПОЛНОСТЬЮ УДАЛЕНА           ║${RESET}"
            echo -e "${NEON_GREEN}${BOLD}╚════════════════════════════════════════════════╝${RESET}"
        else
            echo -e "${NEON_YELLOW}Отменено${RESET}"
        fi
        ;;
    backup)
        if [ ! -f "$INFRA_DIR/.backup_configured" ]; then
            echo -e "${ICON_FAIL} Бэкап не настроен. Запустите: ${NEON_CYAN}infra backup-setup${RESET}"
            exit 1
        fi
        source "$INFRA_DIR/.backup_env"
        mkdir -p "$BACKUP_DIR/cache"
        backup_time=$(date "+%Y-%m-%d %H:%M:%S")
        echo -e "${NEON_CYAN}▸ Создание бэкапа ${backup_time}...${RESET}"
        mkdir -p "$BACKUP_DIR/snapshots"
        SNAPSHOT="$BACKUP_DIR/snapshots/infra-$(date +%Y%m%d-%H%M%S).tar.gz"
        tar -czf "$SNAPSHOT" -C "$VOLUMES_DIR" . 2>/dev/null || true

        extra_mounts=""
        if [[ "$RESTIC_REPOSITORY" == local:* ]]; then
            local_path="${RESTIC_REPOSITORY#local:}"
            if [ -n "$local_path" ]; then
                extra_mounts="-v ${local_path}:${local_path}:Z"
            fi
        fi

        if ! podman run --rm \
            -e RESTIC_REPOSITORY="$RESTIC_REPOSITORY" \
            -e RESTIC_PASSWORD="$RESTIC_PASSWORD" \
            ${AWS_ACCESS_KEY_ID:+-e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID"} \
            ${AWS_SECRET_ACCESS_KEY:+-e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"} \
            -v "$INFRA_DIR:/data:ro" \
            -v "$BACKUP_DIR/cache:/cache" \
            ${extra_mounts} \
            docker.io/restic/restic:latest \
            backup /data --exclude=/data/backups --cache-dir=/cache 2>&1 | tee -a "$INFRA_DIR/logs/backup.log"; then
            echo -e "  ${ICON_FAIL} ${NEON_RED}Ошибка бэкапа${RESET}"
            rm -f "$SNAPSHOT" 2>/dev/null
            exit 1
        fi
        ls -t "$BACKUP_DIR/snapshots"/*.tar.gz 2>/dev/null | tail -n +4 | xargs -r rm -f

        forget_mounts=""
        if [[ "$RESTIC_REPOSITORY" == local:* ]]; then
            forget_local_path="${RESTIC_REPOSITORY#local:}"
            if [ -n "$forget_local_path" ]; then
                forget_mounts="-v ${forget_local_path}:${forget_local_path}:Z"
            fi
        fi

        podman run --rm \
            -e RESTIC_REPOSITORY="$RESTIC_REPOSITORY" \
            -e RESTIC_PASSWORD="$RESTIC_PASSWORD" \
            ${AWS_ACCESS_KEY_ID:+-e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID"} \
            ${AWS_SECRET_ACCESS_KEY:+-e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"} \
            -v "$BACKUP_DIR/cache:/cache" \
            ${forget_mounts} \
            docker.io/restic/restic:latest \
            forget --keep-daily 7 --prune --cache-dir=/cache 2>/dev/null || true
        echo -e "  ${ICON_OK} ${NEON_GREEN}Backup completed${RESET}"
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
            1) read -rp "  Путь для бэкапов [по умолчанию: /backup/infra]: " REPO_PATH
               REPO_PATH="${REPO_PATH:-/backup/infra}"
               REPO="local:${REPO_PATH}"
               LOCAL_PATH="$REPO_PATH" ;;
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
        read -rp "  Время автобэкапа [по умолчанию: 0 2 * * *]: " CRON_TIME
        CRON_TIME="${CRON_TIME:-0 2 * * *}"
        if [ $(echo "$CRON_TIME" | wc -w) -ne 5 ]; then
            echo -e "  ${ICON_WARN} Неверный формат cron. Используется значение по умолчанию: 0 2 * * *"
            CRON_TIME="0 2 * * *"
        fi
        mkdir -p "$BACKUP_DIR/cache"
        cat > "$INFRA_DIR/.backup_env" <<EOENV
RESTIC_REPOSITORY=$REPO
RESTIC_PASSWORD=$RESTIC_PASS
EOENV
        [ -n "${AWS_KEY:-}" ] && echo "AWS_ACCESS_KEY_ID=$AWS_KEY" >> "$INFRA_DIR/.backup_env"
        [ -n "${AWS_SECRET:-}" ] && echo "AWS_SECRET_ACCESS_KEY=$AWS_SECRET" >> "$INFRA_DIR/.backup_env"
        chmod 600 "$INFRA_DIR/.backup_env"
        if [ -n "$LOCAL_PATH" ]; then
            if [ ! -d "$LOCAL_PATH" ]; then
                echo -e "  ${NEON_CYAN}▸ Создание директории $LOCAL_PATH...${RESET}"
                sudo mkdir -p "$LOCAL_PATH"
                sudo chown "$USER:$USER" "$LOCAL_PATH" 2>/dev/null || true
            fi
        fi
        echo -e "  ${NEON_CYAN}▸ Инициализация репозитория...${RESET}"
        init_mounts=""
        if [ -n "$LOCAL_PATH" ]; then init_mounts="-v ${LOCAL_PATH}:${LOCAL_PATH}:Z"; fi
        if podman run --rm \
            -e RESTIC_REPOSITORY="$REPO" \
            -e RESTIC_PASSWORD="$RESTIC_PASS" \
            ${AWS_KEY:+-e AWS_ACCESS_KEY_ID="$AWS_KEY"} \
            ${AWS_SECRET:+-e AWS_SECRET_ACCESS_KEY="$AWS_SECRET"} \
            -v "$BACKUP_DIR/cache:/cache" \
            ${init_mounts} \
            docker.io/restic/restic:latest \
            init --cache-dir=/cache 2>/dev/null; then
            echo -e "  ${ICON_OK} ${NEON_GREEN}Репозиторий инициализирован${RESET}"
        else
            echo -e "  ${ICON_WARN} Репозиторий уже существует или ошибка инициализации"
        fi
        touch "$INFRA_DIR/.backup_configured"
        ( crontab -l 2>/dev/null | grep -v "infra backup" || true; echo "$CRON_TIME $INFRA_DIR/bin/infra backup >> $INFRA_DIR/logs/backup.log 2>&1" ) | crontab -
        echo -e "  ${ICON_OK} ${NEON_GREEN}Бэкап настроен${RESET}"
        echo -e "  ${MUTED_GRAY}Репозиторий: $REPO${RESET}"
        echo -e "  ${MUTED_GRAY}Расписание: $CRON_TIME${RESET}"
        echo -e "  ${MUTED_GRAY}Тест: infra backup${RESET}"
        ;;
    backup-list)
        if [ ! -f "$INFRA_DIR/.backup_configured" ]; then echo -e "${ICON_FAIL} Бэкап не настроен"; exit 1; fi
        source "$INFRA_DIR/.backup_env"
        list_mounts=""
        if [[ "$RESTIC_REPOSITORY" == local:* ]]; then
            list_local_path="${RESTIC_REPOSITORY#local:}"
            if [ -n "$list_local_path" ]; then list_mounts="-v ${list_local_path}:${list_local_path}:Z"; fi
        fi
        echo -e "${NEON_CYAN}▸ Снапшоты:${RESET}"
        podman run --rm -e RESTIC_REPOSITORY="$RESTIC_REPOSITORY" -e RESTIC_PASSWORD="$RESTIC_PASSWORD" ${AWS_ACCESS_KEY_ID:+-e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID"} ${AWS_SECRET_ACCESS_KEY:+-e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"} -v "$BACKUP_DIR/cache:/cache" ${list_mounts} docker.io/restic/restic:latest snapshots --cache-dir=/cache
        ;;
    backup-restore)
        if [ ! -f "$INFRA_DIR/.backup_configured" ]; then 
            echo -e "${ICON_FAIL} Бэкап не настроен"
            echo -e "${ICON_INFO} Используйте restore-local для восстановления из локальных архивов"
            exit 1
        fi
        source "$INFRA_DIR/.backup_env"
        restore_mounts=""
        if [[ "$RESTIC_REPOSITORY" == local:* ]]; then
            restore_local_path="${RESTIC_REPOSITORY#local:}"
            if [ -n "$restore_local_path" ]; then restore_mounts="-v ${restore_local_path}:${restore_local_path}:Z"; fi
        fi
        echo -e "${NEON_CYAN}▸ Доступные снапшоты:${RESET}"
        podman run --rm -e RESTIC_REPOSITORY="$RESTIC_REPOSITORY" -e RESTIC_PASSWORD="$RESTIC_PASSWORD" ${AWS_ACCESS_KEY_ID:+-e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID"} ${AWS_SECRET_ACCESS_KEY:+-e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"} -v "$BACKUP_DIR/cache:/cache" ${restore_mounts} docker.io/restic/restic:latest snapshots --cache-dir=/cache
        echo ""
        read -rp "  ID снапшота [по умолчанию: latest]: " SNAP_ID; SNAP_ID="${SNAP_ID:-latest}"
        read -rp "  Куда восстановить [$INFRA_DIR]: " TARGET; TARGET="${TARGET:-$INFRA_DIR}"
        read -rp "  Остановить сервисы перед восстановлением? [Y/n]: " STOP_SERV
        if [[ ! "${STOP_SERV:-Y}" =~ ^[Nn]$ ]]; then
            systemctl --user stop gitea torrserver dockge 2>/dev/null || true
            sudo systemctl stop gitea-runner netbird 2>/dev/null || true
            echo -e "  ${ICON_OK} Сервисы остановлены"
        fi
        echo -e "  ${NEON_CYAN}▸ Восстановление $SNAP_ID в $TARGET...${RESET}"
        podman run --rm -e RESTIC_REPOSITORY="$RESTIC_REPOSITORY" -e RESTIC_PASSWORD="$RESTIC_PASSWORD" ${AWS_ACCESS_KEY_ID:+-e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID"} ${AWS_SECRET_ACCESS_KEY:+-e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"} -v "$TARGET:/restore:Z" -v "$BACKUP_DIR/cache:/cache" ${restore_mounts} docker.io/restic/restic:latest restore "$SNAP_ID" --target /restore --cache-dir=/cache
        echo -e "  ${ICON_OK} ${NEON_GREEN}Восстановление завершено${RESET}"
        echo -e "  ${ICON_INFO} Перезапустите сервисы: infra start"
        ;;
    restore-local)
        # Восстановление из локальных tar.gz архивов
        echo -e "${NEON_CYAN}▸ Восстановление из локального архива${RESET}"

        # Ищем доступные архивы
        local archives=()
        if [ -d "$BACKUP_DIR/snapshots" ]; then
            while IFS= read -r -d '' file; do
                archives+=("$file")
            done < <(find "$BACKUP_DIR/snapshots" -name "*.tar.gz" -type f -print0 2>/dev/null | sort -z -r)
        fi

        if [ ${#archives[@]} -eq 0 ]; then
            echo -e "  ${ICON_FAIL} Локальные архивы не найдены в $BACKUP_DIR/snapshots"
            exit 1
        fi

        echo ""
        echo -e "  ${NEON_CYAN}Доступные архивы:${RESET}"
        for i in "${!archives[@]}"; do
            local size=$(du -h "${archives[$i]}" 2>/dev/null | cut -f1)
            local date=$(stat -c %y "${archives[$i]}" 2>/dev/null | cut -d' ' -f1)
            printf "  ${NEON_CYAN}%2d)${RESET} %-30s ${DIM_GRAY}(%s, %s)${RESET}\n" $((i+1)) "$(basename "${archives[$i]}")" "$size" "$date"
        done

        echo ""
        read -rp "  Выберите архив [1-${#archives[@]}]: " ARCHIVE_NUM

        if ! [[ "$ARCHIVE_NUM" =~ ^[0-9]+$ ]] || [ "$ARCHIVE_NUM" -lt 1 ] || [ "$ARCHIVE_NUM" -gt ${#archives[@]} ]; then
            echo -e "  ${ICON_FAIL} Неверный выбор"
            exit 1
        fi

        local selected_archive="${archives[$((ARCHIVE_NUM-1))]}"
        echo -e "  ${ICON_OK} Выбран: $(basename "$selected_archive")"

        read -rp "  Остановить сервисы перед восстановлением? [Y/n]: " STOP_SERV
        if [[ ! "${STOP_SERV:-Y}" =~ ^[Nn]$ ]]; then
            systemctl --user stop gitea torrserver dockge 2>/dev/null || true
            sudo systemctl stop gitea-runner netbird 2>/dev/null || true
            echo -e "  ${ICON_OK} Сервисы остановлены"
        fi

        read -rp "  Очистить текущие данные перед восстановлением? [y/N]: " CLEAN_DATA
        if [[ "$CLEAN_DATA" =~ ^[Yy]$ ]]; then
            echo -e "  ${NEON_YELLOW}▸ Очистка текущих данных...${RESET}"
            rm -rf "$VOLUMES_DIR"/*
            echo -e "    ${ICON_OK} Данные очищены"
        fi

        echo -e "  ${NEON_CYAN}▸ Распаковка архива...${RESET}"
        if tar -xzf "$selected_archive" -C "$VOLUMES_DIR" 2>/dev/null; then
            echo -e "    ${ICON_OK} ${NEON_GREEN}Архив распакован${RESET}"
            # Фиксим права
            chown -R "$USER:$USER" "$VOLUMES_DIR" 2>/dev/null || true
            echo -e "    ${ICON_OK} Права восстановлены"
        else
            echo -e "    ${ICON_FAIL} ${NEON_RED}Ошибка распаковки${RESET}"
            exit 1
        fi

        echo ""
        echo -e "${NEON_GREEN}${BOLD}╔════════════════════════════════════════════════╗${RESET}"
        echo -e "${NEON_GREEN}${BOLD}║   ВОССТАНОВЛЕНИЕ ЗАВЕРШЕНО                     ║${RESET}"
        echo -e "${NEON_GREEN}${BOLD}╚════════════════════════════════════════════════╝${RESET}"
        echo -e "${ICON_INFO} Запустите сервисы: ${NEON_CYAN}infra start${RESET}"
        ;;
    update)
        echo -e "${NEON_CYAN}▸ Принудительное обновление контейнеров...${RESET}"
        echo -e "  ${NEON_YELLOW}Rootless контейнеры...${RESET}"
        systemctl --user stop gitea torrserver dockge 2>/dev/null || true
        podman auto-update --rollback 2>/dev/null && echo -e "    ${ICON_OK} Обновлено" || echo -e "    ${ICON_INFO} Нет обновлений"
        systemctl --user start gitea torrserver dockge 2>/dev/null || true

        echo -e "  ${NEON_YELLOW}Rootful контейнеры...${RESET}"
        sudo systemctl stop gitea-runner netbird 2>/dev/null || true
        sudo podman auto-update --rollback 2>/dev/null && echo -e "    ${ICON_OK} Обновлено" || echo -e "    ${ICON_INFO} Нет обновлений"
        sudo systemctl start gitea-runner netbird 2>/dev/null || true
        echo -e "  ${ICON_OK} ${NEON_GREEN}Обновление завершено${RESET}"
        ;;
    *) echo "Использование: infra {status|start|stop|restart <svc>|logs <svc>|clear|backup|backup-setup|backup-list|backup-restore|restore-local|update}" ;;
esac
ENDOFCLI

chmod +x "$BIN_DIR/infra"
sudo ln -sf "$BIN_DIR/infra" /usr/local/bin/infra 2>/dev/null || true

# =============== GITEA ROOTLESS ===============
print_step "Создание Gitea (rootless)"

mkdir -p ~/.config/systemd/user

cat > ~/.config/systemd/user/gitea.service <<EOF
[Unit]
Description=Gitea
After=network-online.target

[Service]
Type=simple
Restart=always
ExecStartPre=-/usr/bin/podman rm -f gitea
ExecStart=/usr/bin/podman run --name gitea --rm \
    --label io.containers.autoupdate=registry \
    -v $CURRENT_HOME/infra/volumes/gitea:/data:Z \
    -e GITEA__server__ROOT_URL=http://$SERVER_IP:3000/ \
    -e GITEA__actions__ENABLED=true \
    -p 3000:3000 -p 2222:22 \
    docker.io/gitea/gitea:latest
ExecStop=/usr/bin/podman stop -t 10 gitea

[Install]
WantedBy=default.target
EOF

chown "$CURRENT_USER:$CURRENT_USER" ~/.config/systemd/user/gitea.service

systemctl --user daemon-reload
systemctl --user start gitea.service && print_success "Gitea запущена" || print_warning "Возможна ошибка запуска"

# Вывод URL сразу после запуска
print_info "Ждём инициализацию (15 сек)..."
print_url "http://${SERVER_IP}:3000/"
print_info "Откройте URL для настройки администратора"

sleep 15

if curl -sf --max-time 5 "http://$SERVER_IP:3000/api/v1/version" >/dev/null 2>&1; then
    print_success "Gitea API доступен"
    GITEA_READY=1
else
    print_warning "Gitea API не отвечает (возможно ещё инициализируется)"
    GITEA_READY=0
fi

# =============== TORRSERVER ROOTLESS ===============
print_step "Создание TorrServer (rootless)"

cat > ~/.config/systemd/user/torrserver.service <<EOF
[Unit]
Description=TorrServer
After=network-online.target

[Service]
Type=simple
Restart=always
ExecStartPre=-/usr/bin/podman rm -f torrserver
ExecStart=/usr/bin/podman run --name torrserver --rm \
    --label io.containers.autoupdate=registry \
    -v $CURRENT_HOME/infra/volumes/torrserver:/app/z:Z \
    -p 8090:8090 \
    ghcr.io/yourok/torrserver:latest
ExecStop=/usr/bin/podman stop -t 10 torrserver

[Install]
WantedBy=default.target
EOF

chown "$CURRENT_USER:$CURRENT_USER" ~/.config/systemd/user/torrserver.service

systemctl --user daemon-reload
systemctl --user start torrserver.service && print_success "TorrServer запущен" || print_warning "Возможна ошибка запуска"

# Вывод URL для TorrServer
print_url "http://${SERVER_IP}:8090/"
print_info "TorrServer Web UI доступен"

# =============== DOCKGE ROOTLESS ===============
print_step "Создание Dockge (rootless)"

mkdir -p "$CURRENT_HOME/infra/stacks"
chown "$CURRENT_USER:$CURRENT_USER" "$CURRENT_HOME/infra/stacks"

cat > ~/.config/systemd/user/dockge.service <<EOF
[Unit]
Description=Dockge - Container Management UI
After=network-online.target

[Service]
Type=simple
Restart=always
ExecStartPre=-/usr/bin/podman rm -f dockge
ExecStart=/usr/bin/podman run --name dockge --rm \
    --label io.containers.autoupdate=registry \
    -v $CURRENT_HOME/infra/volumes/dockge:/app/data:Z \
    -v $CURRENT_HOME/infra/stacks:/opt/stacks:Z \
    -v /run/user/$CURRENT_UID/podman/podman.sock:/var/run/docker.sock:Z \
    -e DOCKGE_STACKS_DIR=/opt/stacks \
    -e DOCKGE_ENABLE_CONSOLE=true
    -p 5001:5001 \
    docker.io/louislam/dockge:latest
ExecStop=/usr/bin/podman stop -t 10 dockge

[Install]
WantedBy=default.target
EOF

chown "$CURRENT_USER:$CURRENT_USER" ~/.config/systemd/user/dockge.service
systemctl --user daemon-reload
systemctl --user start dockge.service && print_success "Dockge запущен" || print_warning "Возможна ошибка запуска"
print_url "http://${SERVER_IP}:5001/"
print_info "Dockge управляет контейнерами через Podman socket"

# =============== RUNNER ROOTFUL ===============
print_step "Настройка Gitea Runner (rootful)"

# Проверяем существование контейнера runner (не только файл сервиса)
SKIP_RUNNER=0
if sudo podman ps -a --format "{{.Names}}" 2>/dev/null | grep -q "^gitea-runner$" || [ -f /etc/systemd/system/gitea-runner.service ]; then
    print_info "Runner уже существует (контейнер или сервис найден)"
    read -rp "  Пересоздать? [y/N]: " RECREATE
    if [[ "$RECREATE" =~ ^[Yy]$ ]]; then
        sudo systemctl stop gitea-runner 2>/dev/null || true
        sudo podman rm -f gitea-runner 2>/dev/null || true
        sudo rm -f /etc/systemd/system/gitea-runner.service
    else
        SKIP_RUNNER=1
    fi
fi

if [ $SKIP_RUNNER -eq 0 ]; then
    echo ""
    echo -e "${NEON_PURPLE}${BOLD}▸ РЕГИСТРАЦИЯ RUNNER'А${RESET}"
    echo ""
    [ $GITEA_READY -eq 1 ] && echo -e "  ${NEON_GREEN}✓ Gitea готова!${RESET}" || echo -e "  ${NEON_YELLOW}⚡ Gitea может быть ещё инициализируется${RESET}"
    echo -e "  Откройте: ${NEON_CYAN}http://$SERVER_IP:3000/-/admin/actions/runners${RESET}"
    echo ""

    read -rp "  Registration Token: " RUNNER_TOKEN

    if [ -n "$RUNNER_TOKEN" ]; then
        sudo tee /etc/systemd/system/gitea-runner.service > /dev/null <<EOF
[Unit]
Description=Gitea Runner
After=network-online.target

[Service]
Type=simple
Restart=always
ExecStartPre=-/usr/bin/podman rm -f gitea-runner
ExecStart=/usr/bin/podman run --name gitea-runner --rm \
    --privileged \
    --label io.containers.autoupdate=registry \
    -v /var/run/docker.sock:/var/run/docker.sock:Z \
    -v /var/lib/gitea-runner:/data:Z \
    -e GITEA_INSTANCE_URL=http://$SERVER_IP:3000 \
    -e GITEA_RUNNER_REGISTRATION_TOKEN=$RUNNER_TOKEN \
    -e GITEA_RUNNER_NAME=runner-$(hostname | cut -d. -f1) \
    docker.io/gitea/act_runner:nightly
ExecStop=/usr/bin/podman stop -t 10 gitea-runner

[Install]
WantedBy=multi-user.target
EOF
        sudo systemctl daemon-reload
        sudo systemctl enable gitea-runner.service 2>/dev/null || true

        if sudo systemctl start gitea-runner.service; then
            print_success "Runner запущен"
            sleep 8
            if sudo podman ps --format "{{.Names}}" | grep -q "^gitea-runner$"; then
                print_info "Логи runner:"
                sudo podman logs gitea-runner 2>&1 | tail -3
            fi
        else
            print_error "Ошибка запуска runner"
        fi
    else
        print_info "Runner пропущен"
    fi
fi

# =============== NETBIRD ROOTFUL ===============
print_step "Настройка NetBird (rootful)"

# Проверяем существование контейнера netbird
if sudo podman ps -a --format "{{.Names}}" 2>/dev/null | grep -q "^netbird$" || sudo systemctl is-active --quiet netbird.service 2>/dev/null; then
    print_success "NetBird уже существует (контейнер или сервис найден)"
    read -rp "  Пересоздать? [y/N]: " RECREATE_NB
    if [[ "$RECREATE_NB" =~ ^[Yy]$ ]]; then
        sudo systemctl stop netbird 2>/dev/null || true
        sudo podman rm -f netbird 2>/dev/null || true
        sudo rm -f /etc/systemd/system/netbird.service
    else
        SKIP_NETBIRD=1
    fi
else
    SKIP_NETBIRD=0
fi

if [ "${SKIP_NETBIRD:-0}" -eq 0 ]; then
    echo ""
    echo -e "${NEON_BLUE}${BOLD}▸ ПОДКЛЮЧЕНИЕ NETBIRD${RESET}"
    echo -e "  Получить ключ: ${NEON_CYAN}https://app.netbird.io/setup-keys ${RESET}"
    echo ""
    read -rp "  Setup Key (Enter - пропустить): " NB_KEY

    if [ -n "${NB_KEY:-}" ]; then
        sudo tee /etc/systemd/system/netbird.service > /dev/null <<EOF
[Unit]
Description=NetBird VPN
After=network-online.target

[Service]
Type=simple
Restart=always
ExecStartPre=-/usr/bin/podman rm -f netbird
ExecStart=/usr/bin/podman run --name netbird --rm \
    --privileged \
    --network host \
    --device /dev/net/tun:/dev/net/tun \
    --label io.containers.autoupdate=registry \
    -v /var/lib/netbird:/etc/netbird:Z \
    -e NB_SETUP_KEY=$NB_KEY \
    -e NB_MANAGEMENT_URL=https://api.netbird.io:443   \
    docker.io/netbirdio/netbird:latest
ExecStop=/usr/bin/podman stop -t 10 netbird

[Install]
WantedBy=multi-user.target
EOF
        sudo systemctl daemon-reload
        sudo systemctl enable netbird.service 2>/dev/null || true

        if sudo systemctl start netbird.service; then
            print_success "NetBird запущен"
            sleep 8
            if sudo podman ps --format "{{.Names}}" | grep -q "^netbird$"; then
                print_info "Логи NetBird:"
                sudo podman logs netbird 2>&1 | tail -3
            fi
        else
            print_error "Ошибка NetBird"
        fi
    else
        print_info "NetBird пропущен"
    fi
fi

# =============== CRON ===============
print_step "Настройка cron"
( crontab -l 2>/dev/null | grep -v "infra" || true; echo "*/5 * * * * $BIN_DIR/infra status > /dev/null 2>&1 || true" ) | crontab - 2>/dev/null || true

# =============== САМОУДАЛЕНИЕ ===============
print_step "Завершение установки"

# Удаляем сам скрипт если он существует и не является уже установленным infra
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
if [ -f "$SCRIPT_PATH" ] && [ "$SCRIPT_PATH" != "$BIN_DIR/infra" ] && [ "$SCRIPT_PATH" != "/usr/local/bin/infra" ]; then
    print_info "Удаление установочного скрипта..."
    rm -f "$SCRIPT_PATH"
    print_success "Скрипт удалён"
fi

# =============== ИТОГ ===============
print_header "ГОТОВО"
echo -e "${NEON_GREEN}●${RESET} Gitea:      ${NEON_CYAN}http://$SERVER_IP:3000${RESET}"
echo -e "${NEON_GREEN}●${RESET} TorrServer: ${NEON_CYAN}http://$SERVER_IP:8090${RESET}"
echo -e "${NEON_GREEN}●${RESET} Dockge:     ${NEON_CYAN}http://$SERVER_IP:5001${RESET}"
echo -e "
Управление: ${NEON_CYAN}infra status|start|stop|logs <сервис>${RESET}"
echo -e "Обновление: ${NEON_CYAN}infra update${RESET} (auto: каждые 5 мин)"
echo -e "Очистка:    ${NEON_CYAN}infra clear${RESET}"
echo -e "Бэкап:      ${NEON_CYAN}infra backup-setup${RESET} → ${NEON_CYAN}infra backup${RESET}"
echo -e "Восстановление: ${NEON_CYAN}infra backup-restore${RESET} (restic) | ${NEON_CYAN}infra restore-local${RESET} (tar.gz)"
echo -e "Директория: ${NEON_CYAN}$INFRA_DIR${RESET} (владелец: $CURRENT_USER)"
