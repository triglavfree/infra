#!/bin/bash
set -uo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
CLIENT_IP=""
SSH_PORT=22
LOG_FILE="/tmp/server-setup-$(date +%Y%m%d-%H%M%S).log"
BACKUP_DIR=""
RUN_ID=$(date +%s)

exec > >(tee -a "$LOG_FILE") 2>&1

# =============== ЦВЕТА ===============
setup_colors() {
    BOLD='\033[1m'; RESET='\033[0m'
    BLUE='\033[1;34m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'
    RED='\033[1;31m'; CYAN='\033[1;36m'; GRAY='\033[1;90m'
    WHITE='\033[1;37m'; MAGENTA='\033[1;35m'
}
setup_colors

# =============== ФУНКЦИИ ВЫВОДА ===============
header() {
    echo -e "\n${BLUE}════════════════════════════════════════════════════════════${RESET}"
    echo -e "${WHITE}  $1${RESET}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════${RESET}"
}

step() { echo -e "\n${CYAN}▶ ${BOLD}$1${RESET}"; }
ok() { echo -e "  ${GREEN}✓ $1${RESET}"; }
warn() { echo -e "  ${YELLOW}⚠ $1${RESET}"; }
err() { echo -e "  ${RED}✗ $1${RESET}" >&2; }
info() { echo -e "  ${CYAN}ℹ $1${RESET}"; }

kv() {
    local key="$1"
    local val="$2"
    local col="${3:-$WHITE}"
    printf "  ${GRAY}%-20s${RESET} ${col}%s${RESET}\n" "$key:" "$val"
}

# =============== СПИННЕР ===============
SPINNER_PID=""

start_spinner() {
    local msg="$1"
    local chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    tput civis 2>/dev/null || echo -ne "\033[?25l" || true
    while kill -0 $$ 2>/dev/null; do
        printf "\r  ${CYAN}%s${RESET} %s" "${chars:$i:1}" "$msg"
        i=$(( (i + 1) % 10 ))
        sleep 0.08
    done &
    SPINNER_PID=$!
}

stop_spinner() {
    local status="${1:-done}"
    local msg="$2"
    if [ -n "$SPINNER_PID" ] && kill -0 "$SPINNER_PID" 2>/dev/null; then
        kill "$SPINNER_PID" 2>/dev/null
        wait "$SPINNER_PID" 2>/dev/null
    fi
    tput cnorm 2>/dev/null || echo -ne "\033[?25h" || true
    printf "\r"
    case "$status" in
        success) echo -e "  ${GREEN}✓${RESET} $msg" ;;
        error) echo -e "  ${RED}✗${RESET} $msg" ;;
        warning) echo -e "  ${YELLOW}⚠${RESET} $msg" ;;
        *) echo -e "  ${CYAN}ℹ${RESET} $msg" ;;
    esac
}

cleanup() {
    [ -n "$SPINNER_PID" ] && kill "$SPINNER_PID" 2>/dev/null || true
    tput cnorm 2>/dev/null || echo -ne "\033[?25h" || true
    
    if [ $? -eq 0 ]; then
        step "Очистка"
        find /root -maxdepth 1 -name "backup_[0-9]*" -type d -exec rm -rf {} + 2>/dev/null
        ok "Бэкапы удалены"
        rm -f "$LOG_FILE" 2>/dev/null
        [ -f "$SCRIPT_PATH" ] && [ "$SCRIPT_PATH" != "/bin/bash" ] && rm -f "$SCRIPT_PATH" 2>/dev/null && ok "Скрипт удалён"
    else
        warn "Ошибки — файлы сохранены"
        info "Лог: $LOG_FILE"
    fi
}
trap cleanup EXIT

# =============== ОПРЕДЕЛЕНИЕ ПОЛЬЗОВАТЕЛЯ ===============
detect_target_user() {
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        TARGET_USER="$SUDO_USER"
    else
        TARGET_USER="$(whoami)"
    fi
    # Получаем домашнюю директорию пользователя
    TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
    if [ -z "$TARGET_HOME" ]; then
        err "Не удалось определить домашнюю папку для пользователя $TARGET_USER"
        exit 1
    fi
    ok "Целевой пользователь: $TARGET_USER (домашняя папка: $TARGET_HOME)"
}

# =============== ФУНКЦИИ ===============
detect_ip() {
    step "Определение вашего IP"
    CLIENT_IP=""
    
    if [ -n "${SSH_CONNECTION:-}" ]; then
        CLIENT_IP=$(echo "$SSH_CONNECTION" | awk '{print $1}')
    elif [ -n "${SSH_CLIENT:-}" ]; then
        CLIENT_IP=$(echo "$SSH_CLIENT" | awk '{print $1}')
    else
        CLIENT_IP=$(who am i 2>/dev/null | awk '{print $5}' | tr -d '()' || echo "")
    fi
    
    if [ -n "$CLIENT_IP" ] && [[ "$CLIENT_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ok "Ваш IP: $CLIENT_IP"
        return 0
    fi
    
    warn "Автоопределение не сработало"
    read -rp "  Введите ваш IP: " CLIENT_IP </dev/tty 2>/dev/null || CLIENT_IP=""
    
    if [ -n "$CLIENT_IP" ] && [[ "$CLIENT_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ok "IP: $CLIENT_IP"
        return 0
    fi
    
    err "IP не определён! SSH будет доступен с любого IP"
    CLIENT_IP="any"
    return 1
}

check_keys() {
    step "Проверка SSH-ключей для пользователя $TARGET_USER"
    local auth_keys="$TARGET_HOME/.ssh/authorized_keys"
    
    if [ -f "$auth_keys" ] && [ -s "$auth_keys" ]; then
        local n=$(grep -cE '^(ssh-(rsa|ed25519)|ecdsa)' "$auth_keys" 2>/dev/null || echo 0)
        if [ "$n" -gt 0 ]; then
            ok "SSH-ключей: $n"
            # Владелец и права должны быть правильными, но проверим
            chown -R "$TARGET_USER":"$TARGET_USER" "$TARGET_HOME/.ssh" 2>/dev/null || true
            chmod 700 "$TARGET_HOME/.ssh" 2>/dev/null || true
            chmod 600 "$auth_keys" 2>/dev/null || true
            return 0
        fi
    fi
    
    err "SSH-ключи не найдены в $auth_keys"
    echo -e "  ${YELLOW}Добавьте свой публичный ключ командой (выполните на локальной машине):${RESET}"
    echo -e "  ${GRAY}ssh-copy-id $TARGET_USER@<сервер>${RESET}"
    echo -e "  ${YELLOW}или вручную скопируйте ключ в $auth_keys${RESET}"
    exit 1
}

check_root() {
    step "Проверка прав"
    if [ "$EUID" -eq 0 ]; then
        ok "Запущено с правами root"
        detect_target_user
        return 0
    else
        err "Недостаточно прав. Запустите с sudo: sudo $0"
        exit 1
    fi
}

get_disk() {
    df / --output=source 2>/dev/null | tail -1 | sed 's/\/dev\///;s/[0-9]*$//'
}

disk_type() {
    local d="$1"
    [[ "$d" =~ ^nvme ]] && { echo "NVMe SSD"; return; }
    [ -f "/sys/block/$d/queue/rotational" ] && { [ "$(cat /sys/block/$d/queue/rotational 2>/dev/null)" = "0" ] && echo "SSD" || echo "HDD"; return; }
    echo "Unknown"
}

update_sys() {
    step "Обновление системы"
    
    local attempt=1
    while [ $attempt -le 3 ]; do
        start_spinner "Обновление списка пакетов (попытка $attempt/3)..."
        if timeout 60 bash -c 'DEBIAN_FRONTEND=noninteractive apt-get update -qq' 2>/dev/null; then
            stop_spinner "success" "Список пакетов обновлён"
            break
        fi
        stop_spinner "warning" "Попытка $attempt не удалась"
        sleep 2
        ((attempt++)) || true
    done
    
    start_spinner "Установка обновлений..."
    if DEBIAN_FRONTEND=noninteractive apt-get upgrade -yqq --no-install-recommends 2>/dev/null; then
        stop_spinner "success" "Обновления установлены"
    else
        stop_spinner "warning" "Частичные ошибки при обновлении"
    fi
    
    apt-get autoremove -yqq 2>/dev/null || true
    apt-get clean 2>/dev/null || true
    
    SYSTEM_STATUS=$(apt-get --just-print upgrade 2>/dev/null | grep -q "^Inst" && echo "доступны обновления" || echo "актуальна")
}

install_pkgs() {
    step "Установка пакетов"
    
    local pkgs=("net-tools" "ufw" "fail2ban")
    local installed=()
    
    start_spinner "Обновление кэша пакетов..."
    apt-get update -qq 2>/dev/null || true
    stop_spinner "success" "OK"
    
    for p in "${pkgs[@]}"; do
        dpkg -l 2>/dev/null | grep -q "^ii  $p " && continue
        start_spinner "Установка $p..."
        if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$p" 2>/dev/null; then
            installed+=("$p")
            stop_spinner "success" "$p установлен"
        else
            stop_spinner "warning" "Ошибка установки $p"
        fi
    done
    
    [ ${#installed[@]} -gt 0 ] && ok "Установлено: ${installed[*]}"
}

optimize() {
    step "Оптимизация ядра"
    
    if [ -f /etc/sysctl.d/99-max-performance.conf ] && grep -q "tcp_congestion_control = bbr" /etc/sysctl.d/99-max-performance.conf 2>/dev/null; then
        [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ] && { ok "BBR уже активен"; return 0; }
    fi
    
    start_spinner "Применение настроек ядра..."
    
    modprobe tcp_bbr 2>/dev/null || true
    echo "tcp_bbr" > /etc/modules-load.d/tcp-bbr.conf 2>/dev/null || true
    
    cat > /etc/sysctl.d/99-max-performance.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_mem = 786432 1048576 1572864
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65536
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_syncookies = 1
net.ipv4.ip_forward = 1
vm.swappiness = 30
vm.vfs_cache_pressure = 50
vm.dirty_background_ratio = 5
vm.dirty_ratio = 15
vm.overcommit_memory = 1
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
EOF
    
    sysctl -p /etc/sysctl.d/99-max-performance.conf >/dev/null 2>&1 || true
    stop_spinner "success" "Настройки применены"
}

setup_swap() {
    step "Настройка Swap"
    
    if swapon --show 2>/dev/null | grep -q '/swapfile'; then
        info "Swap уже активен"
        return 0
    fi
    
    local mem=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || echo "0")
    local sz=2048
    [ "$mem" -gt 2048 ] && sz=1024
    [ "$mem" -gt 4096 ] && sz=512
    
    start_spinner "Создание swap ${sz}MB..."
    
    rm -f /swapfile 2>/dev/null
    fallocate -l ${sz}M /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=$sz status=none 2>/dev/null
    
    chmod 600 /swapfile && mkswap /swapfile >/dev/null 2>&1 && swapon /swapfile 2>/dev/null && {
        grep -q '/swapfile' /etc/fstab 2>/dev/null || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        stop_spinner "success" "Swap ${sz}MB создан"
    } || {
        stop_spinner "error" "Ошибка создания swap"
        rm -f /swapfile 2>/dev/null
        return 1
    }
}

harden_ssh() {
    step "Настройка SSH"
    local sshd_config="/etc/ssh/sshd_config"
    
    # Проверяем, не настроен ли уже
    if grep -q "^PasswordAuthentication no" "$sshd_config" 2>/dev/null && \
       grep -q "^PermitRootLogin no" "$sshd_config" 2>/dev/null && \
       grep -q "^AllowUsers.*$TARGET_USER" "$sshd_config" 2>/dev/null; then
        info "SSH уже настроен безопасно для пользователя $TARGET_USER"
        return 0
    fi
    
    start_spinner "Настройка SSH..."
    
    cp "$sshd_config" "${sshd_config}.backup.$RUN_ID" 2>/dev/null || true
    
    # Отключаем парольный вход для всех
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$sshd_config" 2>/dev/null || true
    sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' "$sshd_config" 2>/dev/null || true
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' "$sshd_config" 2>/dev/null || true
    sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$sshd_config" 2>/dev/null || true
    
    # Добавляем AllowUsers для целевого пользователя (если ещё нет)
    if ! grep -q "^AllowUsers.*$TARGET_USER" "$sshd_config" 2>/dev/null; then
        echo "AllowUsers $TARGET_USER" >> "$sshd_config"
    fi
    
    # Проверка конфигурации
    if ! sshd -t 2>/dev/null; then
        stop_spinner "error" "Ошибка в конфигурации SSH"
        return 1
    fi
    
    local srv="ssh"
    systemctl list-unit-files 2>/dev/null | grep -q '^sshd' && srv="sshd"
    systemctl reload "$srv" 2>/dev/null || systemctl restart "$srv" 2>/dev/null
    sleep 1
    
    if systemctl is-active --quiet "$srv" 2>/dev/null; then
        stop_spinner "success" "SSH настроен: вход только по ключу для пользователя $TARGET_USER, root запрещён"
    else
        stop_spinner "error" "SSH не запустился"
        return 1
    fi
}

setup_ufw() {
    step "Настройка фаервола"
    
    if ! command -v ufw >/dev/null 2>&1; then
        warn "UFW не установлен"
        return 0
    fi
    
    start_spinner "Настройка UFW..."
    
    # Удаляем старые правила SSH
    local old=$(ufw status numbered 2>/dev/null | grep -E ":$SSH_PORT|SSH" | grep -oP '^\[\s*\K\d+' 2>/dev/null || echo "")
    for n in $(echo "$old" | sort -rn 2>/dev/null); do 
        [ -n "$n" ] && yes | ufw delete "$n" >/dev/null 2>&1 || true
    done
    
    ufw status 2>/dev/null | grep -qi "active" || {
        ufw --force reset >/dev/null 2>&1 || true
        ufw default deny incoming >/dev/null 2>&1 || true
        ufw default allow outgoing >/dev/null 2>&1 || true
    }
    
    if [ -n "$CLIENT_IP" ] && [ "$CLIENT_IP" != "any" ]; then
        ufw allow from "$CLIENT_IP" to any port "$SSH_PORT" comment "SSH мой IP" >/dev/null 2>&1
    else
        ufw allow "$SSH_PORT/tcp" comment "SSH любой" >/dev/null 2>&1
    fi
    
    ufw --force enable >/dev/null 2>&1 || true
    
    if ufw status 2>/dev/null | grep -qi "active"; then
        stop_spinner "success" "UFW активен"
    else
        stop_spinner "warning" "UFW не удалось активировать"
    fi
}

setup_fail2ban() {
    step "Настройка Fail2Ban"
    
    if ! command -v fail2ban-server >/dev/null 2>&1; then
        warn "Fail2Ban не установлен"
        return 0
    fi
    
    start_spinner "Настройка Fail2Ban..."
    
    mkdir -p /etc/fail2ban/jail.d 2>/dev/null
    cat > /etc/fail2ban/jail.d/sshd.local 2>/dev/null <<EOF
[sshd]
enabled = true
port = $SSH_PORT
maxretry = 5
bantime = 1h
EOF
    
    systemctl restart fail2ban >/dev/null 2>&1 || true
    
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        stop_spinner "success" "Fail2Ban активен"
    else
        stop_spinner "warning" "Fail2Ban не запущен"
    fi
}

backup() {
    step "Бэкап конфигов"
    BACKUP_DIR="/root/backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR" 2>/dev/null || return 1
    cp /etc/ssh/sshd_config "$BACKUP_DIR/" 2>/dev/null
    cp /etc/fstab "$BACKUP_DIR/" 2>/dev/null
    ok "Бэкап создан: $BACKUP_DIR"
}

check_os() {
    step "Проверка ОС"
    [ -f /etc/os-release ] || { err "Неизвестная ОС"; exit 1; }
    source /etc/os-release
    [ "$ID" = "ubuntu" ] || warn "Тестировано на Ubuntu, у вас: $ID"
    ok "ОС: ${PRETTY_NAME:-$ID}"
}

# =============== ФИНАЛЬНАЯ СВОДКА ===============
summary() {
    clear 2>/dev/null || true
    header "НАСТРОЙКА ЗАВЕРШЕНА"
    
    local disk=$(get_disk)
    local dtype=$(disk_type "$disk")
    local bbr=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "нет")
    local qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "нет")
    local swap_mb=0; [ -f /swapfile ] && swap_mb=$(($(stat -c %s /swapfile 2>/dev/null) / 1024 / 1024))
    local swapp=$(sysctl -n vm.swappiness 2>/dev/null || echo "-")
    local files=$(sysctl -n fs.file-max 2>/dev/null || echo "-")
    local tfo=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo "-")
    local syn=$(sysctl -n net.ipv4.tcp_syncookies 2>/dev/null || echo "-")
    
    # СИСТЕМА
    echo -e "\n${MAGENTA}┌─ СИСТЕМА ─────────────────────────┐${RESET}"
    kv "ОС" "${PRETTY_NAME:-unknown}" "$WHITE"
    kv "Обновления" "$SYSTEM_STATUS" "$([ "$SYSTEM_STATUS" = "актуальна" ] && echo "$GREEN" || echo "$YELLOW")"
    [ -f /var/run/reboot-required ] && kv "Перезагрузка" "требуется" "$YELLOW" || kv "Перезагрузка" "не требуется" "$GREEN"
    
    # ОПТИМИЗАЦИИ
    echo -e "\n${MAGENTA}┌─ ОПТИМИЗАЦИИ ЯДРА ─────────────────┐${RESET}"
    [ "$bbr" = "bbr" ] && kv "TCP BBR" "включён ✓" "$GREEN" || kv "TCP BBR" "отключён" "$YELLOW"
    kv "Планировщик (qdisc)" "$qdisc" "$CYAN"
    kv "Тип диска" "$dtype ($disk)" "$WHITE"
    [ "$swap_mb" -gt 0 ] && kv "Swap файл" "${swap_mb} МБ ✓" "$GREEN" || kv "Swap файл" "отсутствует" "$YELLOW"
    kv "Swappiness" "$swapp" "$CYAN"
    kv "Файловые дескрипторы" "$files" "$CYAN"
    kv "TCP Fast Open" "$tfo" "$CYAN"
    [ "$syn" = "1" ] && kv "SYN Cookies" "включены ✓" "$GREEN" || kv "SYN Cookies" "отключены" "$YELLOW"
    
    # БЕЗОПАСНОСТЬ SSH
    echo -e "\n${MAGENTA}┌─ БЕЗОПАСНОСТЬ SSH ─────────────────┐${RESET}"
    kv "Порт" "$SSH_PORT" "$CYAN"
    kv "Аутентификация" "только SSH-ключи ✓" "$GREEN"
    kv "Парольный вход" "отключён ✓" "$GREEN"
    kv "Разрешённый пользователь" "$TARGET_USER ✓" "$GREEN"
    kv "Вход root" "запрещён ✓" "$GREEN"
    
    # ДОСТУП
    echo -e "\n${MAGENTA}┌─ КОНТРОЛЬ ДОСТУПА ─────────────────┐${RESET}"
    if [ -n "$CLIENT_IP" ] && [ "$CLIENT_IP" != "any" ]; then
        kv "Разрешён с IP" "$CLIENT_IP ✓" "$GREEN"
        kv "Другие IP" "заблокированы ✓" "$GREEN"
    else
        kv "Доступ" "с ЛЮБОГО IP" "$YELLOW"
        kv "Статус" "небезопасно!" "$YELLOW"
    fi
    
    # СЛУЖБЫ
    echo -e "\n${MAGENTA}┌─ СЛУЖБЫ БЕЗОПАСНОСТИ ──────────────┐${RESET}"
    local srv="ssh"; systemctl list-unit-files 2>/dev/null | grep -q '^sshd' && srv="sshd"
    systemctl is-active --quiet fail2ban 2>/dev/null && kv "Fail2Ban" "активен ✓" "$GREEN" || kv "Fail2Ban" "неактивен" "$YELLOW"
    ufw status 2>/dev/null | grep -qi "active" && kv "UFW" "активен ✓" "$GREEN" || kv "UFW" "неактивен" "$YELLOW"
    systemctl is-active --quiet "$srv" 2>/dev/null && kv "SSH сервер" "работает ✓" "$GREEN" || kv "SSH сервер" "ОШИБКА!" "$RED"
    
    # ВНИМАНИЕ
    echo -e "\n${YELLOW}┌─ ВАЖНО ─────────────────────────────┐${RESET}"
    echo -e "  ${WHITE}Подключайтесь только под пользователем:${RESET} ${GREEN}${BOLD}$TARGET_USER${RESET}"
    if [ -n "$CLIENT_IP" ] && [ "$CLIENT_IP" != "any" ]; then
        echo -e "  ${WHITE}Разрешённый IP:${RESET} ${GREEN}${BOLD}${CLIENT_IP}${RESET}"
        echo -e "  ${GRAY}ssh -p $SSH_PORT $TARGET_USER@<сервер>${RESET}"
    else
        echo -e "  ${YELLOW}Настройте ограничение по IP:${RESET}"
        echo -e "  ${GRAY}ufw allow from <IP> to any port $SSH_PORT${RESET}"
        echo -e "  ${GRAY}ufw delete allow $SSH_PORT/tcp${RESET}"
    fi
    
    [ -f /var/run/reboot-required ] && echo -e "\n  ${YELLOW}Требуется перезагрузка: reboot${RESET}"
    
    echo -e "${GREEN}└─────────────────────────────────────┘${RESET}"
    echo -e "${GREEN}           ✓ Готово!${RESET}"
}

# =============== MAIN ===============
main() {
    clear 2>/dev/null || true
    header "SERVER OPTIMIZER v4.3 (user-mode)"
    
    check_root
    detect_ip
    check_keys
    backup
    check_os
    update_sys
    install_pkgs
    optimize
    setup_swap
    harden_ssh
    setup_ufw
    setup_fail2ban
    summary
}

main "$@"
