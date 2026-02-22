#!/bin/bash
set -euo pipefail

# =============================================================================
# INFRASTRUCTURE CLEANUP v1.1
# =============================================================================
# Полная очистка без переустановки Ubuntu Server 24.04
# Включает удаление самого скрипта cleanup по завершении
# =============================================================================

NEON_RED='\033[38;5;203m'
NEON_YELLOW='\033[38;5;220m'
NEON_GREEN='\033[38;5;84m'
NEON_CYAN='\033[38;5;81m'
SOFT_WHITE='\033[38;5;252m'
MUTED_GRAY='\033[38;5;245m'
BOLD='\033[1m'
RESET='\033[0m'

SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_NAME="$(basename "$0")"

print_header() {
    echo ""
    echo -e "${NEON_RED}${BOLD}▸ $1${RESET}"
    echo ""
}

print_step() { echo -e "  ${NEON_CYAN}→${RESET} ${SOFT_WHITE}$1${RESET}"; }
print_success() { echo -e "  ${NEON_GREEN}✓${RESET} $1"; }
print_warning() { echo -e "  ${NEON_YELLOW}⚡${RESET} $1"; }
print_info() { echo -e "  ${MUTED_GRAY}ℹ $1${RESET}"; }

CURRENT_USER="${SUDO_USER:-$(whoami)}"
CURRENT_HOME="$(getent passwd "$CURRENT_USER" 2>/dev/null | cut -d: -f6)"
CURRENT_UID=$(id -u "$CURRENT_USER")

echo ""
echo -e "${NEON_RED}${BOLD}╔════════════════════════════════════════════════╗${RESET}"
echo -e "${NEON_RED}${BOLD}║     INFRASTRUCTURE CLEANUP v1.1                ║${RESET}"
echo -e "${NEON_RED}${BOLD}╚════════════════════════════════════════════════╝${RESET}"
echo ""

echo -e "${NEON_YELLOW}⚠ ВНИМАНИЕ:${RESET} ${SOFT_WHITE}Это удалит:${RESET}"
echo ""
echo -e "  • Все контейнеры Podman (gitea, torrserver, netbird, runner)"
echo -e "  • Все образы Podman"
echo -e "  • Все volumes в $CURRENT_HOME/infra/volumes"
echo -e "  • Все systemd user-сервисы (gitea, torrserver, runner)"
echo -e "  • Системный сервис netbird"
echo -e "  • Cron задачи healthcheck и backup"
echo -e "  • CLI утилиту 'infra' и alias 'i'"
echo -e "  • Restic репозиторий и пароли"
echo -e "  • UFW правила (будут сброшены)"
echo -e "  • Настройки sysctl и модули ядра"
echo -e "  • Скрипт infra.sh"
echo ""
echo -e "${NEON_YELLOW}⚠ СОХРАНЯТСЯ:${RESET}"
echo -e "  • Установленные пакеты (podman, ufw и т.д.)"
echo -e "  • SSH настройки"
echo -e "  • Другие системные настройки"
echo ""

read -rp "$(echo -e "${NEON_RED}Вы уверены? Введите 'yes' для продолжения:${RESET} ")" CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo ""
    echo -e "${NEON_YELLOW}Отменено.${RESET}"
    exit 0
fi

echo ""
echo -e "${NEON_RED}${BOLD}НАЧИНАЕМ ОЧИСТКУ...${RESET}"
echo ""

# =============== 1. ОСТАНОВКА СЕРВИСОВ ===============
print_header "1. Остановка всех сервисов"

export XDG_RUNTIME_DIR="/run/user/$CURRENT_UID"

# Останавливаем user сервисы
print_step "Остановка user сервисов..."
systemctl --user stop gitea torrserver gitea-runner 2>/dev/null || true
systemctl --user disable gitea torrserver gitea-runner 2>/dev/null || true
print_success "User сервисы остановлены"

# Останавливаем netbird
print_step "Остановка NetBird..."
sudo systemctl stop netbird 2>/dev/null || true
sudo systemctl disable netbird 2>/dev/null || true
print_success "NetBird остановлен"

# =============== 2. УДАЛЕНИЕ КОНТЕЙНЕРОВ ===============
print_header "2. Удаление контейнеров"

print_step "Удаление всех контейнеров..."
podman rm -f gitea torrserver gitea-runner netbird 2>/dev/null || true
sudo podman rm -f netbird 2>/dev/null || true
print_success "Контейнеры удалены"

print_step "Удаление всех образов..."
podman rmi -f $(podman images -q) 2>/dev/null || true
sudo podman rmi -f $(sudo podman images -q) 2>/dev/null || true
print_success "Образы удалены"

print_step "Очистка Podman..."
podman system prune -f 2>/dev/null || true
sudo podman system prune -f 2>/dev/null || true
print_success "Podman очищен"

# =============== 3. УДАЛЕНИЕ SYSTEMD СЕРВИСОВ ===============
print_header "3. Удаление systemd сервисов"

# User сервисы
print_step "Удаление user сервисов..."
sudo rm -f ~/.config/systemd/user/gitea.service
sudo rm -f ~/.config/systemd/user/gitea-runner.service
sudo rm -f ~/.config/systemd/user/torrserver.service
sudo rm -f ~/.config/containers/systemd/*.container 2>/dev/null || true
systemctl --user daemon-reload 2>/dev/null || true
print_success "User сервисы удалены"

# System сервис netbird
print_step "Удаление system сервиса NetBird..."
sudo rm -f /etc/systemd/system/netbird.service
sudo systemctl daemon-reload 2>/dev/null || true
print_success "System сервисы удалены"

# =============== 4. УДАЛЕНИЕ ДИРЕКТОРИЙ ===============
print_header "4. Удаление данных"

print_step "Удаление infra директории..."
rm -rf "$CURRENT_HOME/infra"
print_success "Директория $CURRENT_HOME/infra удалена"

print_step "Удаление NetBird конфигурации..."
sudo rm -rf /var/lib/netbird
print_success "NetBird конфигурация удалена"

# =============== 5. ОЧИСТКА CRON ===============
print_header "5. Очистка cron"

print_step "Удаление cron задач..."
(
    crontab -l 2>/dev/null | grep -v "healthcheck\|infra" || true
) | crontab - 2>/dev/null || true
print_success "Cron задачи удалены"

# =============== 6. УДАЛЕНИЕ CLI И ALIAS ===============
print_header "6. Удаление CLI"

print_step "Удаление симлинка infra..."
sudo rm -f /usr/local/bin/infra
print_success "Симлинк удалён"

print_step "Удаление alias и PATH из .bashrc..."
# Удаляем строки с infra из .bashrc
sed -i '/infra\/bin/d' "$CURRENT_HOME/.bashrc" 2>/dev/null || true
sed -i '/alias i=/d' "$CURRENT_HOME/.bashrc" 2>/dev/null || true
print_success ".bashrc очищен"

# =============== 7. СБРОС UFW ===============
print_header "7. Сброс фаервола"

print_step "Сброс UFW..."
sudo ufw --force reset 2>/dev/null || true
sudo ufw disable 2>/dev/null || true
print_success "UFW сброшен"

# =============== 8. УДАЛЕНИЕ СИСТЕМНЫХ НАСТРОЕК ===============
print_header "8. Удаление системных настроек"

print_step "Удаление sysctl настроек..."
sudo rm -f /etc/sysctl.d/99-netbird.conf
sudo sysctl --system 2>/dev/null || true
print_success "Sysctl настройки удалены"

print_step "Удаление модулей ядра..."
sudo rm -f /etc/modules-load.d/wireguard.conf
sudo modprobe -r wireguard 2>/dev/null || true
print_success "Модули ядра отключены"

# =============== 9. ОТКЛЮЧЕНИЕ LINGER ===============
print_header "9. Отключение linger"

print_step "Отключение linger..."
sudo loginctl disable-linger "$CURRENT_USER" 2>/dev/null || true
print_success "Linger отключён"

# =============== 10. ФИНАЛЬНАЯ ОЧИСТКА ===============
print_header "10. Финальная очистка"

print_step "Очистка временных файлов..."
rm -rf /tmp/netbird-* 2>/dev/null || true
rm -rf /tmp/infra-* 2>/dev/null || true
sudo rm -rf /run/user/$CURRENT_UID/netbird 2>/dev/null || true
print_success "Временные файлы удалены"

# =============== 11. УДАЛЕНИЕ СКРИПТА ===============
print_header "11. Самоудаление скрипта"

print_step "Удаление infra.sh..."
print_success "Скрипт будет удалён после завершения"

# =============== ИТОГ ===============
echo ""
echo -e "${NEON_GREEN}${BOLD}╔════════════════════════════════════════════════╗${RESET}"
echo -e "${NEON_GREEN}${BOLD}║     ОЧИСТКА ЗАВЕРШЕНА УСПЕШНО!                 ║${RESET}"
echo -e "${NEON_GREEN}${BOLD}╚════════════════════════════════════════════════╝${RESET}"
echo ""

echo -e "${SOFT_WHITE}Удалено:${RESET}"
echo -e "  ${NEON_GREEN}✓${RESET} Все контейнеры и образы Podman"
echo -e "  ${NEON_GREEN}✓${RESET} Все данные сервисов (gitea, torrserver, runner)"
echo -e "  ${NEON_GREEN}✓${RESET} NetBird VPN и его конфигурация"
echo -e "  ${NEON_GREEN}✓${RESET} Systemd сервисы"
echo -e "  ${NEON_GREEN}✓${RESET} Cron задачи"
echo -e "  ${NEON_GREEN}✓${RESET} CLI утилита 'infra'"
echo -e "  ${NEON_GREEN}✓${RESET} Restic репозиторий и бэкапы"
echo -e "  ${NEON_GREEN}✓${RESET} UFW правила"
echo -e "  ${NEON_GREEN}✓${RESET} Скрипт infra.sh"
echo ""

echo -e "${NEON_YELLOW}⚠ Что осталось (не тронуто):${RESET}"
echo -e "  • Установленные пакеты: podman, ufw, fail2ban и др."
echo -e "  • SSH настройки и ключи"
echo -e "  • Пользовательские данные в домашней директории"
echo -e "  • Системные настройки Ubuntu"
echo ""

echo -e "${NEON_CYAN}Для полного удаления пакетов выполните:${RESET}"
echo -e "  ${MUTED_GRAY}sudo apt remove --purge podman podman-docker ufw fail2ban${RESET}"
echo -e "  ${MUTED_GRAY}sudo apt autoremove --purge${RESET}"
echo ""

echo -e "${NEON_CYAN}Теперь можно заново запустить скрипт установки.${RESET}"
echo ""

# Самоудаление скрипта
rm -f infra.sh
