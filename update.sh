#!/usr/bin/env bash
#
# Update the DTS Router Monitor (Starlink) on a deployed Raspberry Pi.
#
# Safe to re-run on a working unit. Pulls the latest agent code,
# refreshes Python deps + compiled UI, and re-runs the remote-access
# install so units that pre-date the wayvnc/ttyd switch get those
# tunnels added without a full ./setup.sh.
#
# Usage:    bash ./update.sh
# Logs:     ~/.dts-update.log (kept on disk for support)
# Reboot:   the systemd-managed remote-access tunnels restart in place,
#           but the on-screen agent runs from the desktop autostart —
#           reboot once at the end of an update window to pick up new
#           Python code on the touchscreen UI.

set -u
set -o pipefail

cur_dir="$( cd "$(dirname "$0")" && pwd -P )"
log_file="${HOME}/.dts-update.log"

# Colored helpers — match setup_ngrok.sh's style so an operator
# reading the two transcripts side by side sees the same thing.
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC} $1"  | tee -a "$log_file"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"   | tee -a "$log_file"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$log_file"; }
err()   { echo -e "${RED}[ERROR]${NC} $1"  | tee -a "$log_file"; }
step()  { echo -e "\n${CYAN}>>> $1${NC}\n" | tee -a "$log_file"; }

info "DTS Router Monitor update started $(date '+%Y-%m-%d %H:%M:%S')"
info "Working directory: $cur_dir"

# Load fleet/device .env (DTS_NGROK_AUTHTOKEN, prefix overrides, etc.).
# Same pattern as setup.sh so an existing install keeps working.
if [ -f "$cur_dir/.env" ]; then
    info "Loading $cur_dir/.env"
    # shellcheck disable=SC1091
    set -a; . "$cur_dir/.env"; set +a
fi

# --- Step 1: download latest code --------------------------------------------
# Tarball from the public dist repo, not `git pull`: the source repo is
# private and a deployed unit has no credentials for it. Pass a branch, tag,
# or commit as $1 to pin a build (default main).
step "Step 1: Downloading latest agent code"
DIST_REPO="${DTS_DIST_REPO:-caltechadvantage/starlink-agent}"
target="${1:-main}"
ver_before="$(cat "$cur_dir/VERSION" 2>/dev/null || echo unknown)"
info "Before: $ver_before"

tmp_tgz="$(mktemp -t starlink-agent.XXXXXX.tar.gz)"
tmp_dir="$(mktemp -d -t starlink-agent.XXXXXX)"
trap 'rm -rf "$tmp_tgz" "$tmp_dir"' EXIT

dl_url="https://codeload.github.com/${DIST_REPO}/tar.gz/${target}"
info "Fetching ${dl_url}"
curl -fsSL --max-time 300 -o "$tmp_tgz" "$dl_url" >>"$log_file" 2>&1 \
    || { err "download failed ($dl_url). Check $log_file."; exit 2; }
tar xzf "$tmp_tgz" -C "$tmp_dir" >>"$log_file" 2>&1 \
    || { err "could not extract the archive."; exit 2; }
# codeload unpacks to <repo>-<ref>; glob it, since a tag ref drops the "v".
cp -r "$(echo "$tmp_dir"/*/)". "$cur_dir/" >>"$log_file" 2>&1 \
    || { err "failed to copy the new agent into $cur_dir."; exit 2; }

ver_after="$(cat "$cur_dir/VERSION" 2>/dev/null || echo unknown)"
if [ "$ver_before" = "$ver_after" ]; then
    info "Already at the latest version ($ver_after) - refreshing system parts anyway."
else
    ok  "Updated code: $ver_before -> $ver_after"
fi

# --- Step 2: Python deps ------------------------------------------------------
step "Step 2: Refreshing Python dependencies"
if sudo pip3 install --break-system-packages -r "$cur_dir/requirements.txt" >>"$log_file" 2>&1; then
    ok "requirements.txt is satisfied"
else
    err "pip install failed. Check $log_file."
    exit 3
fi

# --- Step 3: compiled UI ------------------------------------------------------
# Only on a source checkout. A compiled dist ships the UI prebuilt and has no
# .ui sources or compile_ui.py to rebuild from.
step "Step 3: Recompiling UI files"
if [ -f "$cur_dir/ui/compile_ui.py" ]; then
    python3 "$cur_dir/ui/compile_ui.py" >>"$log_file" 2>&1 \
        && ok "UI compiled" || warn "compile_ui.py error (see $log_file). Continuing."
else
    info "Compiled dist - UI ships prebuilt, nothing to recompile."
fi

# --- Step 4: remote-access install (ttyd + wayvnc + noVNC + ngrok) -----------
# Re-runs setup_ngrok.sh, which is fully idempotent: apt-installed
# packages get checked, the ttyd systemd unit is rewritten, ngrok.yml
# regenerates with the same per-device subdomains. This is what lets a
# unit predating the wayvnc/ttyd switch pick up those tunnels without
# a full ./setup.sh re-run.
step "Step 4: Refreshing remote-access components"
if [ -z "${DTS_NGROK_AUTHTOKEN:-}" ]; then
    warn "DTS_NGROK_AUTHTOKEN is not set in .env - skipping remote-access refresh."
    warn "Remote-access tunnels (ttyd / wayvnc / noVNC) won't be installed/updated."
else
    if [ ! -f "$cur_dir/scripts/setup_ngrok.sh" ]; then
        err "scripts/setup_ngrok.sh not found. Cannot refresh remote-access stack."
        err "Pull a newer version of the agent and re-run ./update.sh."
        exit 4
    fi
    if sudo DTS_NON_INTERACTIVE=1 \
            DTS_NGROK_AUTHTOKEN="${DTS_NGROK_AUTHTOKEN}" \
            DTS_NGROK_PREFIX="${DTS_NGROK_PREFIX:-}" \
            DTS_SSH_TCP_ADDR="${DTS_SSH_TCP_ADDR:-}" \
            DTS_NGROK_DOMAIN="${DTS_NGROK_DOMAIN:-}" \
            DTS_ENABLE_SCREEN="${DTS_ENABLE_SCREEN:-}" \
            DTS_VNC_PASSWORD="${DTS_VNC_PASSWORD:-}" \
            bash "$cur_dir/scripts/setup_ngrok.sh" >>"$log_file" 2>&1; then
        ok "Remote-access stack is current"
    else
        warn "setup_ngrok.sh reported an error (see $log_file). Continuing."
    fi
fi

# --- Step 5: restart anything that runs under systemd ------------------------
# The Python agent itself is launched by the desktop autostart, so a
# systemctl restart won't reach it; that's what the reboot prompt at
# the end is for. ttyd IS managed by systemd, so cycle it now.
step "Step 5: Restarting systemd-managed components"
if systemctl list-unit-files 2>/dev/null | grep -q '^ttyd\.service'; then
    if sudo systemctl restart ttyd 2>>"$log_file"; then
        ok "ttyd restarted"
    else
        warn "ttyd restart failed; check journalctl -u ttyd"
    fi
else
    info "ttyd service not installed (expected on units without .env auth token)"
fi

# Splash screen (existed pre-this-script) - refresh if updated.
if systemctl list-unit-files 2>/dev/null | grep -q '^splashscreen\.service'; then
    sudo systemctl restart splashscreen 2>>"$log_file" || warn "splashscreen restart failed"
fi

# --- Done --------------------------------------------------------------------
step "Update complete"
info "Code: $ver_before -> $ver_after"
info "Log file: $log_file"
ok   "REBOOT THE PI to fully reload the touchscreen agent:  sudo reboot"
exit 0
