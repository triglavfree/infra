#!/bin/bash
#===============================================================================
# Telemt MTProto Proxy Deployment Script for Ubuntu Server 24.04.4 LTS
#
# Telemt - MTProxy на Rust + Tokio с продвинутым TLS Fronting
# https://github.com/telemt/telemt
#
# Особенности:
# - Полная маскировка под HTTPS (DPI видит настоящий TLS)
# - Transparent TCP Splice для клиентов без секрета
# - Мультипользовательский режим
# - Минимум компонентов для максимальной приватности
#===============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Logging
log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Paths
CONFIG_DIR="/etc/telemt"
QUADLET_DIR="/etc/containers/systemd"
CONFIG_FILE="${CONFIG_DIR}/telemt.toml"

# Settings (can be overridden via environment)
TELEMT_PORT="${TELEMT_PORT:-443}"
TELEMT_SECRET="${TELEMT_SECRET:-}"
TELEMT_DOMAIN="${TELEMT_DOMAIN:-}"
TLS_MASK_DOMAIN="${TLS_MASK_DOMAIN:-www.microsoft.com}"

# Optional: DuckDNS + ACME
USE_DUCKDNS="${USE_DUCKDNS:-false}"
DUCKDNS_DOMAIN="${DUCKDNS_DOMAIN:-}"
DUCKDNS_TOKEN="${DUCKDNS_TOKEN:-}"

#===============================================================================
# Check root
#===============================================================================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Run as root: sudo $0"
        exit 1
    fi
}

#===============================================================================
# Install dependencies
#===============================================================================
install_deps() {
    log_info "Updating system..."
    apt-get update -qq

    log_info "Installing packages..."
    apt-get install -y -qq \
        curl wget openssl jq podman crun fuse-overlayfs \
        ca-certificates

    log_ok "Dependencies installed"
}

#===============================================================================
# Configure Podman
#===============================================================================
configure_podman() {
    log_info "Configuring Podman..."

    mkdir -p /etc/containers

    cat > /etc/containers/storage.conf << 'EOF'
[storage]
driver = "overlay"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"

[storage.options]
overlay.mountopt = "nodev,metacopy=on"
EOF

    mkdir -p "${QUADLET_DIR}"
    log_ok "Podman configured"
}

#===============================================================================
# Generate secret (32 hex chars = 16 bytes)
#===============================================================================
generate_secret() {
    openssl rand -hex 16
}

#===============================================================================
# Get public IP
#===============================================================================
get_public_ip() {
    curl -s --max-time 5 ifconfig.me 2>/dev/null || \
    curl -s --max-time 5 icanhazip.com 2>/dev/null || \
    echo "UNKNOWN"
}

#===============================================================================
# Setup DuckDNS (optional)
#===============================================================================
setup_duckdns() {
    if [[ "${USE_DUCKDNS}" != "true" ]] || [[ -z "${DUCKDNS_DOMAIN}" ]] || [[ -z "${DUCKDNS_TOKEN}" ]]; then
        return 0
    fi

    log_info "Setting up DuckDNS..."

    # Update DuckDNS
    curl -s "https://www.duckdns.org/update?domains=${DUCKDNS_DOMAIN}&token=${DUCKDNS_TOKEN}&ip=$(get_public_ip)"

    # Create update cron
    cat > /etc/cron.d/duckdns << EOF
*/5 * * * * root curl -s "https://www.duckdns.org/update?domains=${DUCKDNS_DOMAIN}&token=${DUCKDNS_TOKEN}&ip=\$(curl -s ifconfig.me)" > /dev/null 2>&1
EOF

    chmod 644 /etc/cron.d/duckdns

    # Set domain
    TELEMT_DOMAIN="${DUCKDNS_DOMAIN}.duckdns.org"

    log_ok "DuckDNS configured: ${TELEMT_DOMAIN}"
}

#===============================================================================
# Setup ACME certificates (optional, for additional HTTPS services)
#===============================================================================
setup_acme() {
    if [[ "${USE_DUCKDNS}" != "true" ]] || [[ -z "${TELEMT_DOMAIN}" ]]; then
        return 0
    fi

    log_info "Installing acme.sh..."

    # Install acme.sh
    curl -sL https://get.acme.sh | sh -s email="admin@${TELEMT_DOMAIN}"

    # Wait for DNS propagation
    log_info "Waiting for DNS propagation..."
    sleep 30

    # Issue certificate using DuckDNS API
    export DuckDNS_Token="${DUCKDNS_TOKEN}"
    ~/.acme.sh/acme.sh --issue --dns dns_duckdns -d "${TELEMT_DOMAIN}"

    # Install certificate
    mkdir -p /etc/telemt/certs
    ~/.acme.sh/acme.sh --install-cert -d "${TELEMT_DOMAIN}" \
        --key-file       /etc/telemt/certs/key.pem \
        --fullchain-file /etc/telemt/certs/cert.pem \
        --reloadcmd      "echo 'Cert renewed'"

    log_ok "SSL certificate installed"
}

#===============================================================================
# Build Telemt container image
#===============================================================================
build_telemt_image() {
    log_info "Building Telemt container image..."

    local tmpdir
    tmpdir=$(mktemp -d)

    cat > "${tmpdir}/Containerfile" << 'EOF'
FROM docker.io/library/alpine:3.19

LABEL maintainer="Telemt MTProxy"
LABEL description="MTProxy with advanced TLS fronting"

# Install dependencies
RUN apk add --no-cache ca-certificates tzdata

# Create user
RUN addgroup -g 1000 telemt && \
    adduser -u 1000 -G telemt -s /bin/sh -D telemt

# Download Telemt
ARG TARGETARCH
RUN arch=$(echo ${TARGETARCH} | sed 's/amd64/x86_64/;s/arm64/aarch64/') && \
    libc=$(ldd --version 2>&1 | grep -iq musl && echo musl || echo gnu) && \
    wget -q "https://github.com/telemt/telemt/releases/latest/download/telemt-${arch}-linux-${libc}.tar.gz" \
    -O /tmp/telemt.tar.gz && \
    tar -xzf /tmp/telemt.tar.gz -C /usr/local/bin && \
    chmod +x /usr/local/bin/telemt && \
    rm /tmp/telemt.tar.gz

# Create directories
RUN mkdir -p /etc/telemt /var/lib/telemt && \
    chown -R telemt:telemt /etc/telemt /var/lib/telemt

USER telemt
WORKDIR /home/telemt

EXPOSE 443/tcp

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD pgrep telemt || exit 1

ENTRYPOINT ["/usr/local/bin/telemt"]
CMD ["/etc/telemt/telemt.toml"]
EOF

    podman build \
        --build-arg TARGETARCH="$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')" \
        -t localhost/telemt:latest \
        "${tmpdir}"

    rm -rf "${tmpdir}"
    log_ok "Telemt image built"
}

#===============================================================================
# Create Telemt configuration
#===============================================================================
create_config() {
    local secret="$1"
    local tls_domain="$2"
    local port="$3"

    log_info "Creating Telemt configuration..."

    mkdir -p "${CONFIG_DIR}"

    cat > "${CONFIG_FILE}" << EOF
# Telemt Configuration
# https://github.com/telemt/telemt

# === General Settings ===
[general]
# ad_tag = ""  # Uncomment and set from @mtproxybot for channel promotion

[general.modes]
classic = false
secure = false
tls = true  # TLS mode with SNI fronting (ee prefix)

# === Server Settings ===
[[server.listeners]]
ip = "0.0.0.0"
port = ${port}

# === Anti-Censorship & TLS Masking ===
[censorship]
# Domain for TLS fronting - DPI sees legitimate HTTPS to this domain
# Recommended: popular sites with TLS 1.3
tls_domain = "${tls_domain}"

# === Users with Secret Keys ===
[access.users]
# Format: "username" = "32_hex_chars_secret"
# Add more users as needed
user = "${secret}"

# === Performance ===
[server]
workers = 4
max_connections = 8192

# === Timeouts ===
[server.timeouts]
connect = 30
idle = 300
EOF

    chmod 600 "${CONFIG_FILE}"
    log_ok "Configuration created: ${CONFIG_FILE}"
}

#===============================================================================
# Create Quadlet unit
#===============================================================================
create_quadlet() {
    local port="$1"

    log_info "Creating Quadlet unit..."

    cat > "${QUADLET_DIR}/telemt.container" << EOF
[Unit]
Description=Telemt MTProto Proxy
After=network.target network-online.target
Wants=network-online.target
Documentation=https://github.com/telemt/telemt

[Container]
Image=localhost/telemt:latest
ContainerName=telemt

PublishPort=${port}:${port}/tcp

Volume=/etc/telemt:/etc/telemt:ro,Z

Environment=TZ=UTC
Environment=RUST_LOG=info

# Security
NoNewPrivileges=true
DropCapability=ALL
AddCapability=NET_BIND_SERVICE

# Limits
MemoryMax=256M
CPUQuota=25%

# Limits for connections
Ulimit=nofile=65536:65536

[Service]
Restart=always
RestartSec=10
TimeoutStartSec=120
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target default.target
EOF

    log_ok "Quadlet created: ${QUADLET_DIR}/telemt.container"
}

#===============================================================================
# Configure firewall
#===============================================================================
configure_firewall() {
    local port="$1"

    log_info "Configuring firewall..."

    if command -v ufw &> /dev/null; then
        ufw allow "${port}/tcp" comment 'Telemt MTProxy'
        log_ok "UFW: port ${port} allowed"
    elif command -v firewall-cmd &> /dev/null; then
        firewall-cmd --permanent --add-port="${port}/tcp"
        firewall-cmd --reload
        log_ok "Firewalld: port ${port} allowed"
    else
        log_warn "No firewall detected. Open port ${port} manually if needed."
    fi
}

#===============================================================================
# Start service
#===============================================================================
start_service() {
    log_info "Starting Telemt service..."

    systemctl daemon-reload
    systemctl enable --now telemt

    sleep 2

    if systemctl is-active --quiet telemt; then
        log_ok "Telemt is running"
    else
        log_error "Telemt failed to start"
        journalctl -u telemt --no-pager -n 20
        exit 1
    fi
}

#===============================================================================
# Show connection info
#===============================================================================
show_connection_info() {
    local secret="$1"
    local host="$2"
    local port="$3"
    local tls_domain="$4"

    # Generate connection links
    # TLS mode uses 'ee' prefix for secret
    local ee_secret="ee${secret}"

    local tg_link="tg://proxy?server=${host}&port=${port}&secret=${ee_secret}"
    local tme_link="https://t.me/proxy?server=${host}&port=${port}&secret=${ee_secret}"

    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║          TELEMT MTPROXY DEPLOYMENT COMPLETE!              ║${NC}"
    echo -e "${GREEN}╠════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}                                                            ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}Server:${NC}      ${YELLOW}${host}${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}Port:${NC}        ${YELLOW}${port}${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}Secret:${NC}      ${YELLOW}${secret}${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}TLS Mask:${NC}    ${YELLOW}${tls_domain}${NC}"
    echo -e "${GREEN}║${NC}                                                            ${GREEN}║${NC}"
    echo -e "${GREEN}╠════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}               ${CYAN}CONNECTION LINKS${NC}                          ${GREEN}║${NC}"
    echo -e "${GREEN}╠════════════════════════════════════════════════════════════╣${NC}"
    echo ""
    echo -e "  ${BLUE}Direct Link (tap in Telegram):${NC}"
    echo -e "  ${tme_link}"
    echo ""
    echo -e "  ${BLUE}tg:// protocol:${NC}"
    echo -e "  ${tg_link}"
    echo ""
    echo -e "${GREEN}╠════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}               ${CYAN}USAGE INSTRUCTIONS${NC}                         ${GREEN}║${NC}"
    echo -e "${GREEN}╠════════════════════════════════════════════════════════════╣${NC}"
    echo ""
    echo -e "  ${YELLOW}1.${NC} Send the link above to yourself in Telegram"
    echo -e "  ${YELLOW}2.${NC} Tap the link to connect"
    echo -e "  ${YELLOW}3.${NC} Or: Settings → Data & Storage → Proxy → Add Proxy"
    echo ""
    echo -e "${GREEN}╠════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}               ${CYAN}MANAGEMENT COMMANDS${NC}                         ${GREEN}║${NC}"
    echo -e "${GREEN}╠════════════════════════════════════════════════════════════╣${NC}"
    echo ""
    echo -e "  ${YELLOW}Status:${NC}  systemctl status telemt"
    echo -e "  ${YELLOW}Logs:${NC}    journalctl -u telemt -f"
    echo -e "  ${YELLOW}Restart:${NC} systemctl restart telemt"
    echo -e "  ${YELLOW}Stop:${NC}     systemctl stop telemt"
    echo ""
    echo -e "${GREEN}╠════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}               ${CYAN}PRIVACY FEATURES${NC}                            ${GREEN}║${NC}"
    echo -e "${GREEN}╠════════════════════════════════════════════════════════════╣${NC}"
    echo ""
    echo -e "  ${YELLOW}✓${NC} TLS Fronting - DPI sees legitimate HTTPS to ${tls_domain}"
    echo -e "  ${YELLOW}✓${NC} Transparent TCP Splice - undetectable by crawlers"
    echo -e "  ${YELLOW}✓${NC} No bot, no extra services - minimal attack surface"
    echo -e "  ${YELLOW}✓${NC} Rust memory safety - no buffer overflows"
    echo ""
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Save to file
    cat > "${CONFIG_DIR}/connection-info.txt" << EOF
=====================================
TELEMT MTPROTOXY CONNECTION INFO
=====================================

Server:  ${host}
Port:    ${port}
Secret:  ${secret}
TLS Mask: ${tls_domain}

CONNECTION LINKS:
-----------------

Click to connect:
${tme_link}

tg:// protocol:
${tg_link}

HOW TO CONNECT:
---------------
1. Send the link above to yourself in Telegram
2. Tap the link to connect
3. Or: Settings → Data & Storage → Proxy → Add Proxy

CONFIG FILE: ${CONFIG_FILE}
LOGS: journalctl -u telemt -f

Generated: $(date)
EOF

    log_ok "Connection info saved to ${CONFIG_DIR}/connection-info.txt"
}

#===============================================================================
# Interactive setup
#===============================================================================
interactive_setup() {
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║       TELEMT MTPROXY SETUP WIZARD                      ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Get domain/IP
    local public_ip
    public_ip=$(get_public_ip)

    echo -e "Your public IP: ${YELLOW}${public_ip}${NC}"
    echo ""

    if [[ -z "${TELEMT_DOMAIN}" ]]; then
        read -rp "Enter domain (or press Enter to use IP): " domain_input
        TELEMT_DOMAIN="${domain_input:-${public_ip}}"
    fi

    # Get port
    if [[ -z "${TELEMT_PORT}" ]]; then
        read -rp "Port [443]: " port_input
        TELEMT_PORT="${port_input:-443}"
    fi

    # Get secret
    if [[ -z "${TELEMT_SECRET}" ]]; then
        local generated_secret
        generated_secret=$(generate_secret)
        read -rp "Secret [${generated_secret}]: " secret_input
        TELEMT_SECRET="${secret_input:-${generated_secret}}"
    fi

    # Get TLS mask domain
    echo ""
    echo "Select TLS masking domain (DPI will see HTTPS to this site):"
    echo "  1) www.microsoft.com (recommended)"
    echo "  2) www.google.com"
    echo "  3) www.apple.com"
    echo "  4) www.cloudflare.com"
    echo "  5) www.amazon.com"
    echo "  6) Custom domain"
    echo ""
    read -rp "Selection [1]: " tls_choice

    case "${tls_choice:-1}" in
        1) TLS_MASK_DOMAIN="www.microsoft.com" ;;
        2) TLS_MASK_DOMAIN="www.google.com" ;;
        3) TLS_MASK_DOMAIN="www.apple.com" ;;
        4) TLS_MASK_DOMAIN="www.cloudflare.com" ;;
        5) TLS_MASK_DOMAIN="www.amazon.com" ;;
        6) read -rp "Enter domain: " TLS_MASK_DOMAIN ;;
        *) TLS_MASK_DOMAIN="www.microsoft.com" ;;
    esac

    # DuckDNS option
    echo ""
    read -rp "Setup DuckDNS for dynamic DNS? [y/N]: " duckdns_choice
    if [[ "${duckdns_choice,,}" =~ ^y ]]; then
        USE_DUCKDNS="true"
        read -rp "DuckDNS subdomain (without .duckdns.org): " DUCKDNS_DOMAIN
        read -rp "DuckDNS token: " DUCKDNS_TOKEN
    fi
}

#===============================================================================
# Main
#===============================================================================
main() {
    echo ""
    echo -e "${GREEN}Telemt MTProto Proxy Deployment${NC}"
    echo -e "${GREEN}For Ubuntu Server 24.04.4 LTS${NC}"
    echo ""

    check_root

    # Interactive or non-interactive
    if [[ "${1:-}" != "--non-interactive" ]]; then
        interactive_setup
    fi

    # Validate
    if [[ -z "${TELEMT_SECRET}" ]]; then
        TELEMT_SECRET=$(generate_secret)
    fi

    if [[ -z "${TELEMT_DOMAIN}" ]]; then
        TELEMT_DOMAIN=$(get_public_ip)
    fi

    log_info "Starting deployment..."
    echo ""

    install_deps
    configure_podman
    setup_duckdns
    build_telemt_image
    create_config "${TELEMT_SECRET}" "${TLS_MASK_DOMAIN}" "${TELEMT_PORT}"
    create_quadlet "${TELEMT_PORT}"
    configure_firewall "${TELEMT_PORT}"
    start_service

    show_connection_info "${TELEMT_SECRET}" "${TELEMT_DOMAIN}" "${TELEMT_PORT}" "${TLS_MASK_DOMAIN}"

    log_ok "Deployment complete!"
}

main "$@"
