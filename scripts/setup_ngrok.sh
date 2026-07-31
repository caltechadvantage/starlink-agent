#!/bin/bash
#
# Setup ngrok remote-access for the Starlink Raspberry Pi build.
#
# Installs ngrok (ARM) plus the four tunnel backends and generates
# ~/.config/ngrok/ngrok.yml with per-device URLs. The Python app
# (utils/rpc_control.py) starts/stops the tunnels on demand via ThingsBoard RPC,
# so this script only installs + configures; it does NOT start ngrok.
#
# Interactive:      bash scripts/setup_ngrok.sh
# Non-interactive:  DTS_NON_INTERACTIVE=1 DTS_NGROK_PREFIX=rpi-spokane \
#                   DTS_SSH_TCP_ADDR=1.tcp.ngrok.io:12345 bash scripts/setup_ngrok.sh

set -u

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()      { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()     { echo -e "${RED}[ERROR]${NC} $1"; }
step()    { echo -e "\n${CYAN}>>> $1${NC}\n"; }

# Supply the ngrok account authtoken via the environment (never commit it):
#   export DTS_NGROK_AUTHTOKEN=xxxxxxxx
NGROK_AUTHTOKEN="${DTS_NGROK_AUTHTOKEN:-}"
NGROK_DOMAIN="${DTS_NGROK_DOMAIN:-ngrok.gigabonding.com}"

# The app runs as the desktop/kiosk user; the ngrok config must live in THAT
# user's home so the running process (utils/rpc_control.py) can read it.
APP_USER="${SUDO_USER:-$USER}"
APP_HOME="$(getent passwd "$APP_USER" | cut -d: -f6)"
NGROK_CONFIG="$APP_HOME/.config/ngrok/ngrok.yml"

require_sudo() {
    if [ "$(id -u)" != "0" ]; then
        err "Run with sudo: sudo -E bash scripts/setup_ngrok.sh"
        exit 1
    fi
}

# Derive a unique, stable URL prefix from the Pi's serial so every device gets
# its own subdomains with zero input (works with the *.DOMAIN wildcard).
derive_prefix() {
    local ser
    ser="$(awk '/^Serial/ {print $3}' /proc/cpuinfo 2>/dev/null)"
    ser="${ser: -8}"
    [ -z "$ser" ] && ser="unknown"
    echo "rpi-${ser}"
}

# --- Step 1: collect per-device settings --------------------------------------
get_config() {
    step "Step 1: Device configuration"
    if [ "${DTS_NON_INTERACTIVE:-0}" = "1" ]; then
        NGROK_PREFIX="${DTS_NGROK_PREFIX:-$(derive_prefix)}"
        SSH_TCP_ADDR="${DTS_SSH_TCP_ADDR:-}"
        info "Non-interactive: prefix=$NGROK_PREFIX ssh=$SSH_TCP_ADDR"
        return 0
    fi
    local default_prefix; default_prefix="$(derive_prefix)"
    read -p "Device URL prefix [${default_prefix}]: " NGROK_PREFIX
    NGROK_PREFIX="${NGROK_PREFIX:-$default_prefix}"
    read -p "Reserved SSH TCP address (host:port, blank = random each start): " SSH_TCP_ADDR
}

# --- Step 2: install ngrok (official apt repo, auto-selects ARM arch) ---------
install_ngrok() {
    step "Step 2: Installing ngrok"
    if command -v ngrok >/dev/null 2>&1; then
        ok "ngrok already installed: $(ngrok version 2>/dev/null | head -n1)"
    else
        info "Adding ngrok apt repository..."
        curl -sSL https://ngrok-agent.s3.amazonaws.com/ngrok.asc \
            | tee /etc/apt/trusted.gpg.d/ngrok.asc >/dev/null
        echo "deb https://ngrok-agent.s3.amazonaws.com buster main" \
            > /etc/apt/sources.list.d/ngrok.list
        apt-get update -y && apt-get install -y ngrok || { err "ngrok install failed"; exit 1; }
        ok "ngrok installed: $(ngrok version 2>/dev/null | head -n1)"
    fi
}

# --- Step 3: tunnel backends --------------------------------------------------
install_backends() {
    step "Step 3: Installing tunnel backends (ttyd, cockpit, openssh, noVNC)"

    # pgrep/killall back the app's is_ngrok_running()/stop_ngrok(); ensure present.
    info "process tools (pgrep/killall)..."
    apt-get install -y procps psmisc >/dev/null 2>&1 || warn "could not install procps/psmisc"

    info "openssh-server (SSH tunnel)..."
    apt-get install -y openssh-server >/dev/null && systemctl enable --now ssh && ok "ssh ready"

    info "ttyd (web terminal on :7681)..."
    apt-get install -y ttyd >/dev/null 2>&1 || true
    if ! command -v ttyd >/dev/null 2>&1; then
        # Not packaged for this release/arch — fetch the static release binary
        # (same approach setup.sh uses for grpcurl).
        ttyd_arch=""
        case "$(uname -m)" in
            aarch64) ttyd_arch=aarch64 ;;
            armv7l)  ttyd_arch=armhf ;;
            armv6l)  ttyd_arch=arm ;;
            x86_64)  ttyd_arch=x86_64 ;;
        esac
        if [ -n "$ttyd_arch" ]; then
            info "ttyd not in apt; downloading static binary ($ttyd_arch)..."
            if wget -qO /usr/local/bin/ttyd \
                "https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.${ttyd_arch}"; then
                chmod +x /usr/local/bin/ttyd
            else
                rm -f /usr/local/bin/ttyd
                warn "ttyd download failed; web shell tunnel will be unavailable"
            fi
        else
            warn "no ttyd binary for $(uname -m); web shell tunnel unavailable"
        fi
    fi
    if command -v ttyd >/dev/null 2>&1; then
        cat > /etc/systemd/system/ttyd.service <<EOF
[Unit]
Description=ttyd web terminal
After=network.target
[Service]
ExecStart=$(command -v ttyd) -p 7681 -i 127.0.0.1 -W login
Restart=always
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload && systemctl enable --now ttyd && ok "ttyd ready on 127.0.0.1:7681"
    fi

    info "cockpit (web admin on :9090)..."
    apt-get install -y cockpit >/dev/null 2>&1 && {
        mkdir -p /etc/cockpit
        # Cockpit serves HTTPS w/ self-signed cert and rejects cross-origin by
        # default. Allow plain HTTP from localhost + trust the ngrok origin so
        # the tunnel works without cert juggling.
        cat > /etc/cockpit/cockpit.conf <<EOF
[WebService]
AllowUnencrypted = true
Origins = https://${NGROK_PREFIX}-admin.${NGROK_DOMAIN} wss://${NGROK_PREFIX}-admin.${NGROK_DOMAIN}
EOF
        systemctl enable --now cockpit.socket && systemctl restart cockpit.socket && ok "cockpit ready on :9090"
    } || warn "cockpit install skipped"

    info "noVNC + websockify (screen on :6080)..."
    # wayvnc captures the Wayland session (Pi OS Bookworm default).
    apt-get install -y novnc websockify wayvnc >/dev/null 2>&1 && ok "noVNC packages installed" \
        || warn "noVNC packages skipped (wayvnc may be unavailable on older OS)"
    if [ "${DTS_ENABLE_SCREEN:-0}" = "1" ]; then
        install_screen_autostart
        info "Screen mirror enabled (wayvnc). Takes effect on reboot."
    else
        info "Screen mirror disabled. Enable with DTS_ENABLE_SCREEN=1 in .env."
    fi
}

# Install a desktop-autostart launcher that mirrors display :0 (the physical
# touchscreen) over VNC -> noVNC on 6080. Runs in the user's session so it has
# DISPLAY/XAUTHORITY; see scripts/screen_share.sh.
install_screen_autostart() {
    local repo_dir autostart_dir labwc_env theme t
    repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
    autostart_dir="$APP_HOME/.config/autostart"
    mkdir -p "$autostart_dir"
    cat > "$autostart_dir/dts-screen-share.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=DTS Screen Share
Exec=bash ${repo_dir}/scripts/screen_share.sh
X-GNOME-Autostart-enabled=true
EOF
    chown -R "$APP_USER":"$APP_USER" "$autostart_dir"
    ok "Screen mirror autostart installed (starts on next login/reboot)"

    # Give labwc a cursor theme so the pointer is visible in the noVNC mirror.
    # wayvnc renders the cursor into the stream (--render-cursor), but a
    # touch-only kiosk has no cursor image unless XCURSOR_THEME is set in
    # labwc's startup env. Idempotent; takes effect on the next reboot.
    theme=Adwaita
    for t in Adwaita PiXflat; do
        [ -d "/usr/share/icons/$t/cursors" ] && { theme="$t"; break; }
    done
    labwc_env="$APP_HOME/.config/labwc/environment"
    mkdir -p "$(dirname "$labwc_env")"
    touch "$labwc_env"
    sed -i '/^XCURSOR_/d' "$labwc_env"
    printf 'XCURSOR_THEME=%s\nXCURSOR_SIZE=24\n' "$theme" >> "$labwc_env"
    chown -R "$APP_USER":"$APP_USER" "$APP_HOME/.config/labwc"
    ok "Cursor theme ($theme) set for the screen mirror"
}

# --- Step 4: write ngrok.yml --------------------------------------------------
write_config() {
    step "Step 4: Writing $NGROK_CONFIG"
    if [ -z "$NGROK_AUTHTOKEN" ]; then
        err "No ngrok authtoken. Set it and re-run, e.g.:"
        err "  sudo -E DTS_NGROK_AUTHTOKEN=<token> bash scripts/setup_ngrok.sh"
        exit 1
    fi
    mkdir -p "$(dirname "$NGROK_CONFIG")"

    {
        echo 'version: "3"'
        echo 'agent:'
        echo "    authtoken: ${NGROK_AUTHTOKEN}"
        echo ''
        echo 'endpoints:'
        echo '  - name: ttyd'
        echo "    url: https://${NGROK_PREFIX}-shell.${NGROK_DOMAIN}"
        echo '    upstream:'
        echo '      url: http://127.0.0.1:7681'
        echo ''
        echo '  - name: cockpit'
        echo "    url: https://${NGROK_PREFIX}-admin.${NGROK_DOMAIN}"
        echo '    upstream:'
        echo '      url: http://127.0.0.1:9090'
        # Only advertise the screen tunnel when the mirror is actually
        # installed; otherwise it points at a dead :6080 and the browser
        # gets ERR_NGROK_8012.
        if [ "${DTS_ENABLE_SCREEN:-0}" = "1" ]; then
            echo ''
            echo '  - name: novnc'
            echo "    url: https://${NGROK_PREFIX}-screen.${NGROK_DOMAIN}"
            echo '    upstream:'
            echo '      url: http://127.0.0.1:6080'
        fi
        if [ -n "${SSH_TCP_ADDR:-}" ]; then
            echo ''
            echo '  - name: ssh'
            echo "    url: tcp://${SSH_TCP_ADDR}"
            echo '    upstream:'
            echo '      url: tcp://127.0.0.1:22'
        fi
    } > "$NGROK_CONFIG"

    chown -R "$APP_USER":"$APP_USER" "$(dirname "$NGROK_CONFIG")"
    ok "Config written and owned by $APP_USER"
    echo ""
    cat "$NGROK_CONFIG"
}

main() {
    echo ""; info "=== Starlink Pi ngrok setup ==="
    require_sudo
    get_config
    install_ngrok
    install_backends
    write_config
    echo ""
    ok "Setup complete."
    info "Tunnels are controlled on demand via the ThingsBoard 'Start ngrok' RPC button."
    info "Public URLs once started:"
    echo -e "  ${CYAN}Web shell:${NC}  https://${NGROK_PREFIX}-shell.${NGROK_DOMAIN}"
    echo -e "  ${CYAN}Admin:${NC}      https://${NGROK_PREFIX}-admin.${NGROK_DOMAIN}"
    echo -e "  ${CYAN}Screen:${NC}     https://${NGROK_PREFIX}-screen.${NGROK_DOMAIN}"
    [ -n "${SSH_TCP_ADDR:-}" ] && echo -e "  ${CYAN}SSH:${NC}        ssh ${APP_USER}@${SSH_TCP_ADDR%%:*} -p ${SSH_TCP_ADDR##*:}"
    echo ""
}

main
