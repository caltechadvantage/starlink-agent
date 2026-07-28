#!/bin/bash
#
# Mirror the physical touchscreen over VNC and bridge it to noVNC on
# 127.0.0.1:6080 — which the ngrok 'screen' tunnel points at.
#
# Runs from the desktop autostart so it inherits the Wayland session env
# (WAYLAND_DISPLAY/XDG_RUNTIME_DIR). Enable via .env: DTS_ENABLE_SCREEN=1.
# Pi OS Bookworm runs a Wayland compositor (labwc), so capture is via wayvnc;
# the local touchscreen keeps working alongside the live browser mirror.

cur_dir="$( cd "$(dirname "$0")/.." ; pwd -P )"
[ -f "${cur_dir}/.env" ] && { set -a; . "${cur_dir}/.env"; set +a; }

# Opt-in only.
[ "${DTS_ENABLE_SCREEN:-0}" = "1" ] || exit 0

LOG="$HOME/.pl/screen_share.log"
mkdir -p "$HOME/.pl"

# Pin capture to the DSI touchscreen: a phantom HDMI output (from
# hdmi_force_hotplug) can otherwise be grabbed first and mirror black.
# Match our own instance in the guard - rpi-connect runs a separate
# wayvnc on a unix socket that a plain "pgrep -x wayvnc" collides with.
if ! pgrep -f "wayvnc.*127.0.0.1 5900" >/dev/null 2>&1; then
    out="$(wlr-randr 2>/dev/null | grep -iE '^[[:alnum:]-]+ ' | awk '{print $1}' | grep -i DSI | head -1)"
    echo "$(date) starting wayvnc output=${out:-auto}" >>"$LOG"
    wayvnc ${out:+--output="$out"} 127.0.0.1 5900 >>"$LOG" 2>&1 &
fi

# Bridge noVNC (browser, 6080) -> VNC (5900); both localhost, ngrok adds TLS.
if ! pgrep -f "websockify.*6080" >/dev/null 2>&1; then
    websockify --web /usr/share/novnc 127.0.0.1:6080 127.0.0.1:5900 >>"$LOG" 2>&1 &
fi
