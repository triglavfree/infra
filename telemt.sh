#!/bin/bash
#===============================================================================
# Telemt MTProto Proxy Deployment Script for Ubuntu Server 24.04.4 LTS
#
# Telemt - MTProxy на Rust + Tokio с продвинутым TLS Fronting
# https://github.com/telemt/telemt
#
# Установка:
#   curl -s https://raw.githubusercontent.com/triglavfree/infra/main/telemt.sh | bash
#
# Автоматический режим:
#   TELEMT_DOMAIN=my.server.com bash
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

# Settings
TELEMT_PORT="${TELEMT_PORT:-443}"
TELEMT_SECRET="${TELEMT_SECRET:-}"
TELEMT_DOMAIN="${TELEMT_DOMAIN:-}"
TLS_MASK_DOMAIN="${TLS_MASK_DOMAIN:-www.microsoft.com}"
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
# Check if running interactively
#===============================================================================
is_interactive() {
    [[ -t 0 && -t 1 ]]
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
# Generate secret
#===============================================================================
generate_secret() {
    openssl rand -hex 16
}

#===============================================================================
# Get public IP
#===============================================================================
get_public_ip() {
    curl -s --max-time 5 -4 ifconfig.me 2>/dev/null || \
    curl -s --max-time 5 -4 icanhazip.com 2>/dev/null || \
    echo "UNKNOWN"
}

#===============================================================================
# Setup DuckDNS
#===============================================================================
setup_duckdns() {
    if [[ "${USE_DUCKDNS}" != "true" ]] || [[ -z "${DUCKDNS_DOMAIN}" ]] || [[ -z "${DUCKDNS_TOKEN}" ]]; then
        return 0
    fi

    log_info "Setting up DuckDNS..."

    curl -s "https://www.duckdns.org/update?domains=${DUCKDNS_DOMAIN}&token=${DUCKDNS_TOKEN}&ip=$(get_public_ip)"

    cat > /etc/cron.d/duckdns << EOF
*/5 * * * * root curl -s "https://www.duckdns.org/update?domains=${DUCKDNS_DOMAIN}&token=${DUCKDNS_TOKEN}&ip=\$(curl -s -4 ifconfig.me)" > /dev/null 2>&1
EOF

    chmod 644 /etc/cron.d/duckdns
    TELEMT_DOMAIN="${DUCKDNS_DOMAIN}.duckdns.org"

    log_ok "DuckDNS configured: ${TELEMT_DOMAIN}"
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

RUN apk add --no-cache ca-certificates tzdata

RUN addgroup -g 1000 telemt && \
    adduser -u 1000 -G telemt -s /bin/sh -D telemt

ARG TARGETARCH
RUN arch=$(echo ${TARGETARCH} | sed 's/amd64/x86_64/;s/arm64/aarch64/') && \
    libc=$(ldd --version 2>&1 | grep -iq musl && echo musl || echo gnu) && \
    wget -q "https://github.com/telemt/telemt/releases/latest/download/telemt-${arch}-linux-${libc}.tar.gz" \
    -O /tmp/telemt.tar.gz && \
    tar -xzf /tmp/telemt.tar.gz -C /usr/local/bin && \
    chmod +x /usr/local/bin/telemt && \
    rm /tmp/telemt.tar.gz

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
# Create configuration
#===============================================================================
create_config() {
    local secret="$1"
    local tls_domain="$2"
    local port="$3"

    log_info "Creating configuration..."

    mkdir -p "${CONFIG_DIR}"

    cat > "${CONFIG_FILE}" << EOF
# Telemt Configuration
# https://github.com/telemt/telemt

[general]

[general.modes]
classic = false
secure = false
tls = true

[[server.listeners]]
ip = "0.0.0.0"
port = ${port}

[censorship]
tls_domain = "${tls_domain}"

[access.users]
user = "${secret}"

[server]
workers = 4
max_connections = 8192

[server.timeouts]
connect = 30
idle = 300
EOF

    chmod 600 "${CONFIG_FILE}"
    log_ok "Configuration created"
}

#===============================================================================
# Create Quadlet
#===============================================================================
create_quadlet() {
    local port="$1"

    log_info "Creating Quadlet..."

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
NoNewPrivileges=true
DropCapability=ALL
AddCapability=NET_BIND_SERVICE
MemoryMax=256M
CPUQuota=25%
Ulimit=nofile=65536:65536

[Service]
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    log_ok "Quadlet created"
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
        log_warn "No firewall detected"
    fi
}

#===============================================================================
# Start service
#===============================================================================
start_service() {
    log_info "Starting Telemt..."

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

    local ee_secret="ee${secret}"
    local tme_link="https://t.me/proxy?server=${host}&port=${port}&secret=${ee_secret}"
    local tg_link="tg://proxy?server=${host}&port=${port}&secret=${ee_secret}"

    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║          TELEMT MTPROXY DEPLOYMENT COMPLETE!              ║${NC}"
    echo -e "${GREEN}╠════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}Server:${NC}      ${YELLOW}${host}${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}Port:${NC}        ${YELLOW}${port}${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}Secret:${NC}      ${YELLOW}${secret}${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}TLS Mask:${NC}    ${YELLOW}${tls_domain}${NC}"
    echo -e "${GREEN}╠════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}               ${CYAN}CONNECTION LINK${NC}                            ${GREEN}║${NC}"
    echo -e "${GREEN}╠════════════════════════════════════════════════════════════╣${NC}"
    echo ""
    echo -e "  ${tme_link}"
    echo ""
    echo -e "${GREEN}╠════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  ${YELLOW}Status:${NC}  systemctl status telemt                       ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${YELLOW}Logs:${NC}    journalctl -u telemt -f                       ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${YELLOW}Restart:${NC} systemctl restart telemt                     ${GREEN}║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    cat > "${CONFIG_DIR}/connection-info.txt" << EOF
TELEMT MTPROXY
==============

Server:  ${host}
Port:    ${port}
Secret:  ${secret}

Connection Link:
${tme_link}

Config: ${CONFIG_FILE}
EOF
}

#===============================================================================
# Interactive setup
#===============================================================================
interactive_setup() {
    local public_ip
    public_ip=$(get_public_ip)

    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║       TELEMT MTPROXY SETUP WIZARD                      ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "Your public IP: ${YELLOW}${public_ip}${NC}"
    echo ""

    if [[ -z "${TELEMT_DOMAIN}" ]]; then
        read -rp "Enter domain (or Enter for IP): " domain_input
        TELEMT_DOMAIN="${domain_input:-${public_ip}}"
    fi

    if [[ -z "${TELEMT_SECRET}" ]]; then
        local generated_secret
        generated_secret=$(generate_secret)
        read -rp "Secret [${generated_secret}]: " secret_input
        TELEMT_SECRET="${secret_input:-${generated_secret}}"
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

    # Auto-detect non-interactive mode (curl | bash)
    if ! is_interactive; then
        echo -e "${YELLOW}Non-interactive mode detected${NC}"
        echo ""

        if [[ -z "${TELEMT_DOMAIN}" ]]; then
            TELEMT_DOMAIN=$(get_public_ip)
        fi
        if [[ -z "${TELEMT_SECRET}" ]]; then
            TELEMT_SECRET=$(generate_secret)
        fi

        echo -e "Server:  ${YELLOW}${TELEMT_DOMAIN}${NC}"
        echo -e "Port:    ${YELLOW}${TELEMT_PORT}${NC}"
        echo -e "Secret:  ${YELLOW}${TELEMT_SECRET}${NC}"
        echo -e "TLS:     ${YELLOW}${TLS_MASK_DOMAIN}${NC}"
        echo ""
    else
        interactive_setup
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

    log_ok "Done!"
}

main "$@"
