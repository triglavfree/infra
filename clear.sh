#!/bin/bash
# =============================================================================
# INFRASTRUCTURE CLEANUP SCRIPT
# Полное удаление всей инфраструктуры
# =============================================================================

# Цвета для красивого вывода
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    PURPLE='\033[0;35m'
    GRAY='\033[1;30m'
    BOLD='\033[1m'
    NC='\033[0m' # No Color
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; PURPLE=''; GRAY=''; BOLD=''; NC=''
fi

# Иконки
ICON_OK="${GREEN}✓${NC}"
ICON_FAIL="${RED}✗${NC}"
ICON_WARN="${YELLOW}⚠${NC}"
ICON_INFO="${BLUE}ℹ${NC}"
ICON_ARROW="${CYAN}▸${NC}"

print_header() {
    echo ""
    echo -e "${GRAY}════════════════════════════════════════════════════${NC}"
    echo -e "${RED}${BOLD}  ПОЛНАЯ ОЧИСТКА ИНФРАСТРУКТУРЫ${NC}"
    echo -e "${GRAY}════════════════════════════════════════════════════${NC}"
    echo ""
}

print_step() {
    echo ""
    echo -e "${CYAN}${BOLD}▸${NC} ${BOLD}$1${NC}"
    echo -e "${GRAY}  ────────────────────────────────────────────────${NC}"
}

print_success() { echo -e "  ${ICON_OK} ${GREEN}$1${NC}"; }
print_error() { echo -e "  ${ICON_FAIL} ${RED}$1${NC}"; }
print_warning() { echo -e "  ${ICON_WARN} ${YELLOW}$1${NC}"; }
print_info() { echo -e "  ${ICON_INFO} ${BLUE}$1${NC}"; }

# Проверка прав
if [ "$EUID" -eq 0 ]; then
    print_error "Запускайте от обычного пользователя! (не от root)"
    exit 1
fi

# Подтверждение (без цветов в read)
print_header
echo -e "  ${RED}${BOLD}ВНИМАНИЕ!${NC} Это удалит:"
echo -e "  • Все контейнеры Podman (gitea, torrserver, gitea-runner, netbird)"
echo -e "  • Все Quadlet файлы и systemd сервисы"
echo -e "  • Все данные в ~/infra/ (по желанию)"
echo -e "  • Команду infra"
echo -e "  • Cron задачи"
echo ""
echo -e -n "  Вы уверены? Введите ${RED}${BOLD}yes${NC} для подтверждения: "
read CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo -e "  ${ICON_WARN} ${YELLOW}Очистка отменена${NC}"
    exit 0
fi

echo ""

# =============== ОСТАНОВКА СЕРВИСОВ ===============
print_step "Остановка сервисов"

# User сервисы
if systemctl --user is-active gitea >/dev/null 2>&1; then
    systemctl --user stop gitea 2>/dev/null
    print_success "Gitea остановлен"
else
    print_info "Gitea не запущен"
fi

if systemctl --user is-active torrserver >/dev/null 2>&1; then
    systemctl --user stop torrserver 2>/dev/null
    print_success "TorrServer остановлен"
else
    print_info "TorrServer не запущен"
fi

# System сервисы
if sudo systemctl is-active gitea-runner >/dev/null 2>&1; then
    sudo systemctl stop gitea-runner 2>/dev/null
    print_success "Gitea Runner остановлен"
else
    print_info "Gitea Runner не запущен"
fi

if sudo systemctl is-active netbird >/dev/null 2>&1; then
    sudo systemctl stop netbird 2>/dev/null
    print_success "NetBird остановлен"
else
    print_info "NetBird не запущен"
fi

# =============== УДАЛЕНИЕ КОНТЕЙНЕРОВ ===============
print_step "Удаление контейнеров"

# User контейнеры
if podman ps -a --format "{{.Names}}" 2>/dev/null | grep -q "systemd-gitea"; then
    podman rm -f systemd-gitea 2>/dev/null
    print_success "Контейнер Gitea удалён"
else
    print_info "Контейнер Gitea не найден"
fi

if podman ps -a --format "{{.Names}}" 2>/dev/null | grep -q "systemd-torrserver"; then
    podman rm -f systemd-torrserver 2>/dev/null
    print_success "Контейнер TorrServer удалён"
else
    print_info "Контейнер TorrServer не найден"
fi

# Root контейнеры
if sudo podman ps -a --format "{{.Names}}" 2>/dev/null | grep -q "gitea-runner"; then
    sudo podman rm -f gitea-runner 2>/dev/null
    print_success "Контейнер Gitea Runner удалён"
else
    print_info "Контейнер Gitea Runner не найден"
fi

if sudo podman ps -a --format "{{.Names}}" 2>/dev/null | grep -q "netbird"; then
    sudo podman rm -f netbird 2>/dev/null
    print_success "Контейнер NetBird удалён"
else
    print_info "Контейнер NetBird не найден"
fi

# =============== УДАЛЕНИЕ QUADLET ФАЙЛОВ ===============
print_step "Удаление Quadlet файлов"

# User Quadlet
if [ -f "$HOME/.config/containers/systemd/gitea.container" ]; then
    rm -f "$HOME/.config/containers/systemd/gitea.container"
    print_success "Quadlet Gitea удалён"
else
    print_info "Quadlet Gitea не найден"
fi

if [ -f "$HOME/.config/containers/systemd/torrserver.container" ]; then
    rm -f "$HOME/.config/containers/systemd/torrserver.container"
    print_success "Quadlet TorrServer удалён"
else
    print_info "Quadlet TorrServer не найден"
fi

# System Quadlet
if [ -f "/etc/containers/systemd/gitea-runner.container" ]; then
    sudo rm -f "/etc/containers/systemd/gitea-runner.container"
    print_success "Quadlet Gitea Runner удалён"
else
    print_info "Quadlet Gitea Runner не найден"
fi

if [ -f "/etc/containers/systemd/netbird.container" ]; then
    sudo rm -f "/etc/containers/systemd/netbird.container"
    print_success "Quadlet NetBird удалён"
else
    print_info "Quadlet NetBird не найден"
fi

# =============== УДАЛЕНИЕ СГЕНЕРИРОВАННЫХ ЮНИТОВ ===============
print_step "Удаление сгенерированных systemd юнитов"

# User юниты
if [ -f "/run/systemd/generator/gitea.service" ]; then
    rm -f "/run/systemd/generator/gitea.service"
    print_success "Юнит Gitea удалён"
fi

if [ -f "/run/systemd/generator/torrserver.service" ]; then
    rm -f "/run/systemd/generator/torrserver.service"
    print_success "Юнит TorrServer удалён"
fi

# System юниты
if [ -f "/run/systemd/generator/gitea-runner.service" ]; then
    sudo rm -f "/run/systemd/generator/gitea-runner.service"
    print_success "Юнит Gitea Runner удалён"
fi

if [ -f "/run/systemd/generator/netbird.service" ]; then
    sudo rm -f "/run/systemd/generator/netbird.service"
    print_success "Юнит NetBird удалён"
fi

# =============== УДАЛЕНИЕ СТАРЫХ SYSTEMD ЮНИТОВ (на всякий случай) ===============
print_step "Удаление старых systemd юнитов"

# User
rm -f "$HOME/.config/systemd/user/gitea.service" 2>/dev/null
rm -f "$HOME/.config/systemd/user/torrserver.service" 2>/dev/null

# System
sudo rm -f "/etc/systemd/system/gitea-runner.service" 2>/dev/null
sudo rm -f "/etc/systemd/system/netbird.service" 2>/dev/null

print_success "Старые юниты удалены"

# =============== ПЕРЕЗАГРУЗКА SYSTEMD ===============
print_step "Перезагрузка systemd"

systemctl --user daemon-reload
sudo systemctl daemon-reload
sudo systemctl restart podman.socket

print_success "systemd перезагружен"

# =============== УДАЛЕНИЕ ДАННЫХ ===============
print_step "Удаление данных"

echo -e -n "  Удалить директорию ${CYAN}$HOME/infra${NC} со всеми данными? [y/N]: "
read DEL_DATA
if [[ "$DEL_DATA" =~ ^[Yy]$ ]]; then
    # Удаляем директорию infra
    rm -rf "$HOME/infra" 2>/dev/null
    print_success "Директория ~/infra удалена"
    
    # Удаляем данные runner и netbird
    sudo rm -rf "/var/lib/gitea-runner" 2>/dev/null
    sudo rm -rf "/var/lib/netbird" 2>/dev/null
    print_success "Системные данные удалены"
else
    print_info "Директория ~/infra сохранена"
fi

# =============== УДАЛЕНИЕ CLI ===============
print_step "Удаление CLI"

if [ -f "/usr/local/bin/infra" ]; then
    sudo rm -f "/usr/local/bin/infra"
    print_success "Команда infra удалена"
else
    print_info "Команда infra не найдена"
fi

# =============== ОЧИСТКА CRON ===============
print_step "Очистка cron"

crontab -l 2>/dev/null | grep -v "infra" | crontab - 2>/dev/null
print_success "Cron задачи очищены"

# =============== ИТОГ ===============
echo ""
echo -e "${GREEN}${BOLD}╔════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║         ОЧИСТКА УСПЕШНО ЗАВЕРШЕНА                  ║${NC}"
echo -e "${GREEN}${BOLD}╚════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${ICON_INFO} Проверка:"
echo -e "    ${GRAY}podman ps -a${NC}       # должен быть пустым"
echo -e "    ${GRAY}sudo podman ps -a${NC}  # должен быть пустым"
echo -e "    ${GRAY}ls -la ~/infra${NC}     # удалено (если выбрали)"
echo -e "    ${GRAY}infra${NC}              # команда не найдена"
echo ""
echo -e "  ${ICON_OK} ${GREEN}Система полностью очищена!${NC}"
echo -e "  ${ICON_ARROW} Можно запустить установку заново:"
echo -e "    ${CYAN}bash <(curl -s https://raw.githubusercontent.com/triglavfree/infra/main/infra.sh)${NC}"
echo ""
