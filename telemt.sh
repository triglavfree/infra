#!/bin/bash
#===============================================================================
# MTProto Proxy + Telegram Bot Deployment Script for Ubuntu Server 24.04.4 LTS
# Based on: MTG (https://github.com/9seconds/mtg)
#           Telemt (https://github.com/telemt/telemt)
#           Habr Article: https://habr.com/ru/articles/994934/
#
# Author: Auto-generated deployment script
# Version: 1.0.0
# License: MIT
#===============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Configuration variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="/etc/mtproto"
QUADLET_DIR="/etc/containers/systemd"
DATA_DIR="/var/lib/mtproto"

# Default settings (can be overridden via environment or config file)
MTG_VERSION="${MTG_VERSION:-2.1.4}"
MTG_PORT="${MTG_PORT:-443}"
MTG_DOMAIN="${MTG_DOMAIN:-}"  # Will be prompted if not set
TELEGRAM_BOT_TOKEN="${TEGRAM_BOT_TOKEN:-}"
TELEGRAM_ADMIN_ID="${TELEGRAM_ADMIN_ID:-}"

# Fake TLS domains (popular sites for DPI evasion)
FAKE_TLS_DOMAINS=(
    "www.google.com"
    "www.youtube.com"
    "www.cloudflare.com"
    "www.microsoft.com"
    "www.amazon.com"
    "www.apple.com"
    "www.facebook.com"
    "www.twitter.com"
    "www.instagram.com"
    "www.github.com"
)

#-------------------------------------------------------------------------------
# Check if running as root
#-------------------------------------------------------------------------------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

#-------------------------------------------------------------------------------
# Detect system architecture
#-------------------------------------------------------------------------------
detect_arch() {
    local arch
    arch=$(uname -m)
    case $arch in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l)  echo "arm" ;;
        *)       log_error "Unsupported architecture: $arch"; exit 1 ;;
    esac
}

#-------------------------------------------------------------------------------
# Install required packages
#-------------------------------------------------------------------------------
install_dependencies() {
    log_info "Updating system packages..."
    apt-get update -qq

    log_info "Installing required packages..."
    apt-get install -y -qq \
        curl \
        wget \
        gnupg2 \
        ca-certificates \
        jq \
        openssl \
        git \
        podman \
        podman-compose \
        crun \
        fuse-overlayfs

    log_success "Dependencies installed successfully"
}

#-------------------------------------------------------------------------------
# Configure Podman for rootless mode (optional)
#-------------------------------------------------------------------------------
configure_podman() {
    log_info "Configuring Podman..."

    # Enable lingering for podman containers
    mkdir -p /etc/systemd/system/podman.service.d
    cat > /etc/systemd/system/podman.service.d/override.conf << 'EOF'
[Service]
TasksMax=infinity
EOF

    # Configure storage
    mkdir -p /etc/containers
    cat > /etc/containers/storage.conf << 'EOF'
[storage]
driver = "overlay"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"

[storage.options]
overlay.mountopt = "nodev,metacopy=on"
EOF

    # Reload systemd
    systemctl daemon-reload

    log_success "Podman configured successfully"
}

#-------------------------------------------------------------------------------
# Install Quadlet (comes with newer podman versions)
#-------------------------------------------------------------------------------
install_quadlet() {
    log_info "Setting up Quadlet for systemd integration..."

    # Create Quadlet directory
    mkdir -p "${QUADLET_DIR}"

    # Verify Quadlet is available
    if command -v quadlet &> /dev/null; then
        log_success "Quadlet is available"
    else
        log_info "Quadlet binary not found separately, using built-in Podman Quadlet"
    fi

    # Create directories for user quadlets
    mkdir -p /root/.config/containers/systemd
}

#-------------------------------------------------------------------------------
# Generate secret key for MTProto
#-------------------------------------------------------------------------------
generate_secret() {
    log_info "Generating MTProto secret key..."

    # Generate 32-byte hex secret
    local secret
    secret=$(openssl rand -hex 16)

    echo "${secret}"
}

#-------------------------------------------------------------------------------
# Build MTG container image
#-------------------------------------------------------------------------------
build_mtg_image() {
    log_info "Building MTG container image..."

    local arch
    arch=$(detect_arch)

    # Create temporary build directory
    local build_dir
    build_dir=$(mktemp -d)

    # Create Containerfile
    cat > "${build_dir}/Containerfile" << 'CONTAINERFILE'
FROM docker.io/library/alpine:3.19

# Install dependencies
RUN apk add --no-cache ca-certificates tzdata

# Create non-root user
RUN addgroup -g 1000 mtg && \
    adduser -u 1000 -G mtg -s /bin/sh -D mtg

# Download and install MTG
ARG MTG_VERSION
ARG TARGETARCH
RUN wget -q "https://github.com/9seconds/mtg/releases/download/v${MTG_VERSION}/mtg-${MTG_VERSION}-linux-${TARGETARCH}.tar.gz" \
    -O /tmp/mtg.tar.gz && \
    tar -xzf /tmp/mtg.tar.gz -C /usr/local/bin && \
    chmod +x /usr/local/bin/mtg && \
    rm /tmp/mtg.tar.gz

# Create directories
RUN mkdir -p /etc/mtg /var/lib/mtg && \
    chown -R mtg:mtg /etc/mtg /var/lib/mtg

USER mtg
WORKDIR /home/mtg

EXPOSE 443

ENTRYPOINT ["/usr/local/bin/mtg"]
CMD ["run", "/etc/mtg/config.toml"]
CONTAINERFILE

    # Build the image
    podman build \
        --build-arg MTG_VERSION="${MTG_VERSION}" \
        --build-arg TARGETARCH="${arch}" \
        -t localhost/mtg:latest \
        -t "localhost/mtg:${MTG_VERSION}" \
        "${build_dir}"

    # Cleanup
    rm -rf "${build_dir}"

    log_success "MTG container image built successfully"
}

#-------------------------------------------------------------------------------
# Create MTG configuration file
#-------------------------------------------------------------------------------
create_mtg_config() {
    local secret="$1"
    local fake_tls_domain="$2"
    local port="$3"

    log_info "Creating MTG configuration..."

    mkdir -p "${CONFIG_DIR}"

    cat > "${CONFIG_DIR}/config.toml" << EOF
# MTG Configuration File
# Generated by deploy-mtproto.sh

# Secret configuration
secret = "${secret}"

# Network settings
port = ${port}

# Fake TLS configuration (for DPI evasion)
# This makes the proxy traffic look like regular HTTPS to the specified domain
[security]
# Use Fake TLS for better obfuscation
fake-tls = true
fake-tls-domain = "${fake_tls_domain}"

# Padding settings to make traffic look more natural
padding-min = 16
padding-max = 256

# Performance settings
[performance]
# Number of workers
workers = 4

# Buffer sizes
read-buffer = 65536
write-buffer = 65536

# Connection limits
max-connections = 8192
EOF

    chmod 600 "${CONFIG_DIR}/config.toml"

    log_success "MTG configuration created at ${CONFIG_DIR}/config.toml"
}

#-------------------------------------------------------------------------------
# Create Quadlet unit file for MTG
#-------------------------------------------------------------------------------
create_mtg_quadlet() {
    log_info "Creating Quadlet unit file for MTG..."

    cat > "${QUADLET_DIR}/mtg.container" << 'EOF'
[Unit]
Description=MTProto Proxy (MTG)
After=network.target network-online.target
Wants=network-online.target
Documentation=https://github.com/9seconds/mtg

[Container]
Image=localhost/mtg:latest
ContainerName=mtg
HostName=mtg-proxy

# Ports
PublishPort=443:443/tcp

# Volumes
Volume=/etc/mtg:/etc/mtg:ro,Z
Volume=/var/lib/mtg:/var/lib/mtg:rw,Z

# Environment
Environment=TZ=UTC

# Security
NoNewPrivileges=true
DropCapability=ALL
AddCapability=NET_BIND_SERVICE

# Resource limits
MemoryMax=512M
MemoryHigh=400M
CPUQuota=50%

# Health check
HealthCmd=/usr/local/bin/mtg healthcheck /etc/mtg/config.toml
HealthInterval=30s
HealthTimeout=10s
HealthRetries=3
HealthStartPeriod=10s

# Auto-update (optional, disabled by default)
# Pull=always

[Service]
Restart=always
RestartSec=10
TimeoutStartSec=300
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target default.target
EOF

    log_success "Quadlet unit file created at ${QUADLET_DIR}/mtg.container"
}

#-------------------------------------------------------------------------------
# Create Telegram bot container
#-------------------------------------------------------------------------------
create_bot_container() {
    if [[ -z "${TELEGRAM_BOT_TOKEN}" ]]; then
        log_warn "Telegram bot token not provided, skipping bot container creation"
        return 0
    fi

    log_info "Creating Telegram bot container..."

    local build_dir
    build_dir=$(mktemp -d)

    # Create bot script
    cat > "${build_dir}/bot.py" << 'BOTSCRIPT'
#!/usr/bin/env python3
"""
Telegram Bot for MTG Proxy Management
"""
import os
import json
import logging
import asyncio
import subprocess
from datetime import datetime
from typing import Optional

from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import Application, CommandHandler, CallbackQueryHandler, ContextTypes

# Configure logging
logging.basicConfig(
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    level=logging.INFO
)
logger = logging.getLogger(__name__)

# Configuration
BOT_TOKEN = os.environ.get('BOT_TOKEN')
ADMIN_IDS = [int(x) for x in os.environ.get('ADMIN_IDS', '').split(',') if x]
PROXY_HOST = os.environ.get('PROXY_HOST', 'localhost')
PROXY_PORT = int(os.environ.get('PROXY_PORT', 443))
CONFIG_PATH = '/etc/mtg/config.toml'

def is_admin(user_id: int) -> bool:
    """Check if user is admin."""
    return user_id in ADMIN_IDS or len(ADMIN_IDS) == 0

async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Handle /start command."""
    user_id = update.effective_user.id
    if not is_admin(user_id):
        await update.message.reply_text("Access denied. You are not authorized.")
        return

    keyboard = [
        [InlineKeyboardButton("Status", callback_data="status")],
        [InlineKeyboardButton("Get Connection Info", callback_data="info")],
        [InlineKeyboardButton("Restart Proxy", callback_data="restart")],
        [InlineKeyboardButton("Statistics", callback_data="stats")],
    ]
    reply_markup = InlineKeyboardMarkup(keyboard)

    await update.message.reply_text(
        "*MTG Proxy Management Bot*\n\n"
        "Welcome! Use the buttons below to manage your proxy.",
        reply_markup=reply_markup,
        parse_mode='Markdown'
    )

async def cmd_status(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Handle /status command."""
    user_id = update.effective_user.id
    if not is_admin(user_id):
        await update.message.reply_text("Access denied.")
        return

    try:
        # Check if container is running
        result = subprocess.run(
            ['podman', 'container', 'inspect', '-f', '{{.State.Status}}', 'mtg'],
            capture_output=True, text=True, timeout=10
        )
        status = result.stdout.strip() if result.returncode == 0 else "unknown"

        status_emoji = "OK" if status == "running" else "ERROR"

        await update.message.reply_text(
            f"*Proxy Status*\n\n"
            f"State: `{status}`\n"
            f"Host: `{PROXY_HOST}`\n"
            f"Port: `{PROXY_PORT}`",
            parse_mode='Markdown'
        )
    except Exception as e:
        await update.message.reply_text(f"Error getting status: `{str(e)}`", parse_mode='Markdown')

async def cmd_info(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Handle /info command - generate connection link."""
    user_id = update.effective_user.id
    if not is_admin(user_id):
        await update.message.reply_text("Access denied.")
        return

    try:
        # Read config to get secret
        secret = None
        with open(CONFIG_PATH, 'r') as f:
            content = f.read()
            for line in content.split('\n'):
                if line.startswith('secret = '):
                    secret = line.split('"')[1]
                    break

        if not secret:
            await update.message.reply_text("Could not read secret from config")
            return

        # Generate proxy link
        # Format: tg://proxy?server=HOST&port=PORT&secret=SECRET
        proxy_link = f"tg://proxy?server={PROXY_HOST}&port={PROXY_PORT}&secret={secret}"

        # Also generate t.me format
        tme_link = f"https://t.me/proxy?server={PROXY_HOST}&port={PROXY_PORT}&secret={secret}"

        await update.message.reply_text(
            "*Connection Information*\n\n"
            f"Server: `{PROXY_HOST}`\n"
            f"Port: `{PROXY_PORT}`\n"
            f"Secret: `{secret}`\n\n"
            f"*Direct Link:*\n`{proxy_link}`\n\n"
            f"*Click Link:*\n{tme_link}",
            parse_mode='Markdown'
        )
    except Exception as e:
        await update.message.reply_text(f"Error: `{str(e)}`", parse_mode='Markdown')

async def cmd_restart(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Handle /restart command."""
    user_id = update.effective_user.id
    if not is_admin(user_id):
        await update.message.reply_text("Access denied.")
        return

    try:
        result = subprocess.run(
            ['systemctl', 'restart', 'mtg'],
            capture_output=True, text=True, timeout=30
        )

        if result.returncode == 0:
            await update.message.reply_text("Proxy restarted successfully!")
        else:
            await update.message.reply_text(f"Restart failed: `{result.stderr}`", parse_mode='Markdown')
    except Exception as e:
        await update.message.reply_text(f"Error: `{str(e)}`", parse_mode='Markdown')

async def cmd_stats(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Handle /stats command."""
    user_id = update.effective_user.id
    if not is_admin(user_id):
        await update.message.reply_text("Access denied.")
        return

    try:
        # Get container stats
        result = subprocess.run(
            ['podman', 'stats', '--no-stream', '--format', 'json', 'mtg'],
            capture_output=True, text=True, timeout=10
        )

        if result.returncode == 0:
            stats = json.loads(result.stdout)
            if stats:
                s = stats[0]
                await update.message.reply_text(
                    "*Proxy Statistics*\n\n"
                    f"CPU: `{s.get('CPU', 'N/A')}`\n"
                    f"Memory: `{s.get('MemUsage', 'N/A')}`\n"
                    f"Network IO: `{s.get('NetIO', 'N/A')}`\n"
                    f"Block IO: `{s.get('BlockIO', 'N/A')}`\n"
                    f"PIDs: `{s.get('PIDs', 'N/A')}`",
                    parse_mode='Markdown'
                )
            else:
                await update.message.reply_text("No stats available")
        else:
            await update.message.reply_text(f"Error getting stats: `{result.stderr}`", parse_mode='Markdown')
    except Exception as e:
        await update.message.reply_text(f"Error: `{str(e)}`", parse_mode='Markdown')

async def button_callback(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Handle button callbacks."""
    query = update.callback_query
    await query.answer()

    user_id = update.effective_user.id
    if not is_admin(user_id):
        await query.edit_message_text("Access denied.")
        return

    data = query.data

    if data == "status":
        await cmd_status(update, context)
    elif data == "info":
        await cmd_info(update, context)
    elif data == "restart":
        await cmd_restart(update, context)
    elif data == "stats":
        await cmd_stats(update, context)

async def cmd_help(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Handle /help command."""
    await update.message.reply_text(
        "*Available Commands*\n\n"
        "/start - Open control panel\n"
        "/status - Check proxy status\n"
        "/info - Get connection info\n"
        "/restart - Restart proxy\n"
        "/stats - View statistics\n"
        "/help - Show this help",
        parse_mode='Markdown'
    )

def main():
    """Run the bot."""
    if not BOT_TOKEN:
        logger.error("BOT_TOKEN environment variable is required!")
        return

    app = Application.builder().token(BOT_TOKEN).build()

    app.add_handler(CommandHandler("start", cmd_start))
    app.add_handler(CommandHandler("status", cmd_status))
    app.add_handler(CommandHandler("info", cmd_info))
    app.add_handler(CommandHandler("restart", cmd_restart))
    app.add_handler(CommandHandler("stats", cmd_stats))
    app.add_handler(CommandHandler("help", cmd_help))
    app.add_handler(CallbackQueryHandler(button_callback))

    logger.info("Starting bot...")
    app.run_polling(allowed_updates=Update.ALL_TYPES)

if __name__ == '__main__':
    main()
BOTSCRIPT

    # Create requirements
    cat > "${build_dir}/requirements.txt" << 'EOF'
python-telegram-bot>=20.0
EOF

    # Create Containerfile for bot
    cat > "${build_dir}/Containerfile" << 'EOF'
FROM docker.io/library/python:3.12-slim

WORKDIR /app

RUN pip install --no-cache-dir python-telegram-bot>=20.0

COPY bot.py .

RUN useradd -m -u 1000 botuser && \
    chown -R botuser:botuser /app

USER botuser

CMD ["python", "bot.py"]
EOF

    # Build image
    podman build -t localhost/mtg-bot:latest "${build_dir}"

    # Cleanup
    rm -rf "${build_dir}"

    # Create bot quadlet
    cat > "${QUADLET_DIR}/mtg-bot.container" << EOF
[Unit]
Description=MTG Telegram Bot
After=network.target network-online.target mtg.service
Requires=mtg.service
Documentation=https://github.com/9seconds/mtg

[Container]
Image=localhost/mtg-bot:latest
ContainerName=mtg-bot

# Environment
Environment=BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
Environment=ADMIN_IDS=${TELEGRAM_ADMIN_ID}
Environment=PROXY_HOST=${MTG_DOMAIN:-localhost}
Environment=PROXY_PORT=${MTG_PORT}

# Volumes
Volume=/etc/mtg:/etc/mtg:ro,Z
Volume=/run/podman/podman.sock:/run/podman/podman.sock:rw

# Security
NoNewPrivileges=true
DropCapability=ALL

# Resource limits
MemoryMax=128M

[Service]
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    log_success "Telegram bot container created"
}

#-------------------------------------------------------------------------------
# Generate connection QR code and info
#-------------------------------------------------------------------------------
generate_connection_info() {
    local secret="$1"
    local domain="$2"
    local port="$3"

    log_info "Generating connection information..."

    local proxy_link="tg://proxy?server=${domain}&port=${port}&secret=${secret}"
    local tme_link="https://t.me/proxy?server=${domain}&port=${port}&secret=${secret}"

    cat > "${CONFIG_DIR}/connection-info.txt" << EOF
====================================
MTProto Proxy Connection Information
====================================

Server: ${domain}
Port: ${port}
Secret: ${secret}

Direct Link (for Telegram app):
${proxy_link}

Click-to-Connect Link:
${tme_link}

Setup Instructions:
1. Copy the link above
2. Send it to yourself in Telegram
3. Click the link to connect
4. Alternatively: Settings > Data and Storage > Proxy Settings > Add Proxy

For command-line setup:
mtg run /etc/mtg/config.toml

Generated at: $(date)
====================================
EOF

    log_success "Connection info saved to ${CONFIG_DIR}/connection-info.txt"
}

#-------------------------------------------------------------------------------
# Configure firewall
#-------------------------------------------------------------------------------
configure_firewall() {
    log_info "Configuring firewall..."

    if command -v ufw &> /dev/null; then
        ufw allow "${MTG_PORT}/tcp" comment 'MTProto Proxy'
        log_success "UFW rule added for port ${MTG_PORT}"
    elif command -v firewall-cmd &> /dev/null; then
        firewall-cmd --permanent --add-port="${MTG_PORT}/tcp"
        firewall-cmd --reload
        log_success "Firewalld rule added for port ${MTG_PORT}"
    else
        log_warn "No firewall detected. Please manually open port ${MTG_PORT}/tcp"
    fi
}

#-------------------------------------------------------------------------------
# Enable and start services
#-------------------------------------------------------------------------------
enable_services() {
    log_info "Enabling and starting services..."

    # Reload systemd to pick up quadlet files
    systemctl daemon-reload

    # Enable and start MTG
    systemctl enable --now mtg

    # Check if bot should be started
    if [[ -n "${TELEGRAM_BOT_TOKEN}" ]]; then
        systemctl enable --now mtg-bot
    fi

    log_success "Services started successfully"
}

#-------------------------------------------------------------------------------
# Show status and connection info
#-------------------------------------------------------------------------------
show_status() {
    local secret="$1"
    local domain="$2"
    local port="$3"

    echo ""
    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN}   MTProto Proxy Deployment Complete!${NC}"
    echo -e "${GREEN}======================================${NC}"
    echo ""
    echo -e "Server: ${YELLOW}${domain}${NC}"
    echo -e "Port: ${YELLOW}${port}${NC}"
    echo -e "Secret: ${YELLOW}${secret}${NC}"
    echo ""
    echo -e "${BLUE}Connection Link:${NC}"
    echo -e "https://t.me/proxy?server=${domain}&port=${port}&secret=${secret}"
    echo ""
    echo -e "${BLUE}Service Status:${NC}"
    systemctl status mtg --no-pager -l || true
    echo ""
    echo -e "${BLUE}Useful Commands:${NC}"
    echo "  View logs:     journalctl -u mtg -f"
    echo "  Restart:       systemctl restart mtg"
    echo "  Stop:          systemctl stop mtg"
    echo "  Status:        systemctl status mtg"
    echo ""
    echo -e "${BLUE}Configuration files:${NC}"
    echo "  Config: ${CONFIG_DIR}/config.toml"
    echo "  Quadlet: ${QUADLET_DIR}/mtg.container"
    echo "  Connection: ${CONFIG_DIR}/connection-info.txt"
    echo ""
}

#-------------------------------------------------------------------------------
# Interactive configuration
#-------------------------------------------------------------------------------
interactive_config() {
    echo -e "${GREEN}MTProto Proxy Setup Wizard${NC}"
    echo "================================"
    echo ""

    # Get domain/IP
    if [[ -z "${MTG_DOMAIN}" ]]; then
        read -rp "Enter your server domain or IP address: " MTG_DOMAIN
    fi

    # Get port
    if [[ -z "${MTG_PORT}" ]]; then
        read -rp "Enter port for MTProto proxy [443]: " MTG_PORT
        MTG_PORT="${MTG_PORT:-443}"
    fi

    # Select Fake TLS domain
    echo ""
    echo "Select a Fake TLS domain (for DPI evasion):"
    PS3="Enter selection [1]: "
    select fake_domain in "${FAKE_TLS_DOMAINS[@]}" "Custom domain"; do
        if [[ -n "${fake_domain}" ]]; then
            if [[ "${fake_domain}" == "Custom domain" ]]; then
                read -rp "Enter custom domain: " SELECTED_TLS_DOMAIN
            else
                SELECTED_TLS_DOMAIN="${fake_domain}"
            fi
            break
        fi
    done

    # Ask about Telegram bot
    echo ""
    read -rp "Do you want to set up the Telegram management bot? [y/N]: " setup_bot
    if [[ "${setup_bot,,}" =~ ^y ]]; then
        read -rp "Enter Telegram Bot Token: " TELEGRAM_BOT_TOKEN
        read -rp "Enter your Telegram User ID (for admin access): " TELEGRAM_ADMIN_ID
    fi
}

#-------------------------------------------------------------------------------
# Main deployment function
#-------------------------------------------------------------------------------
main() {
    echo ""
    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN}  MTProto Proxy Deployment Script${NC}"
    echo -e "${GREEN}  For Ubuntu Server 24.04.4 LTS${NC}"
    echo -e "${GREEN}======================================${NC}"
    echo ""

    check_root

    # Interactive or automated mode
    if [[ "${1:-}" != "--non-interactive" ]]; then
        interactive_config
    fi

    # Validate required settings
    if [[ -z "${MTG_DOMAIN}" ]]; then
        log_error "Server domain/IP is required. Set MTG_DOMAIN environment variable or run in interactive mode."
        exit 1
    fi

    # Generate secret if not provided
    MTG_SECRET="${MTG_SECRET:-$(generate_secret)}"
    SELECTED_TLS_DOMAIN="${SELECTED_TLS_DOMAIN:-www.google.com}"

    log_info "Starting deployment..."
    echo ""

    # Run deployment steps
    install_dependencies
    configure_podman
    install_quadlet
    build_mtg_image
    create_mtg_config "${MTG_SECRET}" "${SELECTED_TLS_DOMAIN}" "${MTG_PORT}"
    create_mtg_quadlet

    # Create bot if requested
    if [[ -n "${TELEGRAM_BOT_TOKEN}" ]]; then
        create_bot_container
    fi

    generate_connection_info "${MTG_SECRET}" "${MTG_DOMAIN}" "${MTG_PORT}"
    configure_firewall
    enable_services

    # Show final status
    show_status "${MTG_SECRET}" "${MTG_DOMAIN}" "${MTG_PORT}"

    log_success "Deployment completed successfully!"
}

#-------------------------------------------------------------------------------
# Run main function
#-------------------------------------------------------------------------------
main "$@"
