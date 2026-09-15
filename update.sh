#!/usr/bin/env bash
#
# Update the DTS Router Monitor (Starlink) on a deployed Raspberry Pi.
#
# Usage:  bash ./update.sh [branch|tag|commit]     (default: main)
# Logs:   ~/.dts-update.log
#
# The release is staged next to the install as <install>.new, checked, then
# swapped in with the running version kept as <install>.prev. The kiosk
# launcher puts .prev back if the new agent keeps crashing after the update.
#
# Byte layout. Agents 1.7.0 to 1.10.1 ran this script from the install folder
# and copied the new release over it while it was running. Bash then carries on
# reading the new file at byte 4041 (1.7.0, 1.8.0) or 4346 (1.9.0 to 1.10.1).
# The lines that start at exactly those bytes hand the run over to this script.
# Keep them there: tests/test_update_script.py fails if they move.
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
######################################
[ -n "${dl_url:-}" ] && exec bash "$cur_dir/update.sh" --after-legacy-copy "${target:-main}"
###############################################################################
###############################################################################
###################################################
[ -n "${dl_url:-}" ] && exec bash "$cur_dir/update.sh" --after-legacy-copy "${target:-main}"

# ---- A normal run starts here ------------------------------------------------
set -u
set -o pipefail
# Step 6 restarts ttyd, which kills a run started from the ttyd web shell with
# SIGHUP before it reports back. Ignore HUP so the run finishes either way.
trap '' HUP

# Run from a private copy. Installing a release replaces this file, and bash
# reads a script as it goes, so a change underneath would change the run.
if [ -z "${DTS_UPDATE_COPY:-}" ]; then
    home="$(cd "$(dirname "$0")" && pwd -P)" || exit 1
    copy="$(mktemp -t dts-update.XXXXXX)" || exit 1
    cp "$0" "$copy" || exit 1
    DTS_UPDATE_COPY="$copy" DTS_UPDATE_HOME="$home" exec bash "$copy" "$@"
fi

app_home="$DTS_UPDATE_HOME"
staging="${app_home}.new"
previous="${app_home}.prev"
log_file="${HOME}/.dts-update.log"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC} $1"  | tee -a "$log_file"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"   | tee -a "$log_file"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$log_file"; }
err()   { echo -e "${RED}[ERROR]${NC} $1"  | tee -a "$log_file"; }
step()  { echo -e "\n${CYAN}>>> $1${NC}\n" | tee -a "$log_file"; }

# ---- Dashboard status reporter ------------------------------------------------
# Straight to ThingsBoard's HTTP telemetry endpoint: the agent is about to go
# away. Silent no-op on a unit with no token.
TB_URL="$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); from settings import TB_SERVER_URL; print(TB_SERVER_URL)' "$app_home" 2>/dev/null)"
TB_TOKEN="$(python3 -c 'import json,os; print(json.load(open(os.path.expanduser("~/.pl/config.json"))).get("tb_token",""))' 2>/dev/null)"

publish_status() {
    [ -z "${TB_URL:-}" ] && return 0
    [ -z "${TB_TOKEN:-}" ] && return 0
    curl -fsS -m 5 -X POST -H 'Content-Type: application/json' \
        -d "$1" "${TB_URL}/api/v1/${TB_TOKEN}/telemetry" >/dev/null 2>&1 || true
}

# Report a failure to the dashboard, then exit with the given code.
fail() {
    publish_status "{\"update_status\":\"failed\",\"update_error\":\"$1\"}"
    exit "$2"
}

# ---- One update at a time ------------------------------------------------------
# A second run while one is going (a double click, two people, a retry) would
# copy and pip-install over the first. /dev/shm is emptied on reboot, so a lock
# left by a power cut does not block the next update; a lock whose process is
# gone is taken over.
lock_root="${DTS_UPDATE_LOCK_ROOT:-/dev/shm}"
[ -d "$lock_root" ] || lock_root="${TMPDIR:-/tmp}"
lock="$lock_root/dts-update.lock"
if ! mkdir "$lock" 2>/dev/null; then
    holder="$(cat "$lock/pid" 2>/dev/null || true)"
    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
        warn "Another update is already running (pid $holder); leaving it to finish."
        rm -f "$DTS_UPDATE_COPY"
        exit 0
    fi
    rm -rf "$lock"
    mkdir "$lock" 2>/dev/null || { err "Could not take the update lock at $lock."; exit 1; }
fi
echo $$ > "$lock/pid"

work="$(mktemp -d -t dts-update-work.XXXXXX)" || exit 1
cleanup() { rm -rf "$lock" "$work" "$staging" "$DTS_UPDATE_COPY"; }
trap cleanup EXIT

if [ -f "$app_home/.env" ]; then
    # shellcheck disable=SC1091
    set -a; . "$app_home/.env"; set +a
fi

mode="install"
target="${1:-main}"
if [ "${1:-}" = "--after-legacy-copy" ]; then
    # Handed over by an old update.sh that already copied the release over the
    # install in place. There is nothing to stage and no previous copy to keep.
    mode="legacy"
    target="${2:-main}"
    rm -rf "${TMPDIR:-/tmp}"/starlink-agent.*
fi
cd "$app_home" || fail install_missing 1
info "DTS Router Monitor update started $(date '+%Y-%m-%d %H:%M:%S') ($mode, target $target)"
ver_before="$(cat "$app_home/VERSION" 2>/dev/null || echo unknown)"
ver_after="$ver_before"
build="$app_home"

# --- Step 1: download and stage ---------------------------------------------------
if [ "$mode" = "install" ]; then
    step "Step 1: Downloading and staging the new agent"
    publish_status '{"update_status":"pulling"}'
    url="https://codeload.github.com/${DTS_DIST_REPO:-caltechadvantage/starlink-agent}/tar.gz/${target}"
    info "Fetching $url"
    curl -fsSL --max-time 300 -o "$work/agent.tgz" "$url" >>"$log_file" 2>&1 \
        || { err "Download failed ($url). Check $log_file."; fail download_failed 2; }
    mkdir -p "$work/x" && tar xzf "$work/agent.tgz" -C "$work/x" >>"$log_file" 2>&1 \
        || { err "Could not extract the archive."; fail extract_failed 2; }
    rm -rf "$staging" "${app_home}.failed"
    # codeload unpacks to <repo>-<ref>; glob it, since a tag ref drops the "v".
    cp -a "$(echo "$work/x"/*/)" "$staging" >>"$log_file" 2>&1 \
        || { err "Could not stage the new agent."; fail stage_failed 2; }
    [ -f "$app_home/.env" ] && cp -p "$app_home/.env" "$staging/.env"
    if [ ! -f "$staging/settings.py" ] \
       || { [ ! -f "$staging/main.py" ] && ! ls "$staging"/py*/main.pyc >/dev/null 2>&1; }; then
        err "The downloaded build has no settings.py or main entry point."
        fail incomplete_build 2
    fi
    ver_after="$(cat "$staging/VERSION" 2>/dev/null || echo unknown)"
    build="$staging"
    ok "Staged $ver_after in $staging"
fi

# --- Step 2: Python deps ------------------------------------------------------------
# Before the swap: if this fails the running install is untouched.
step "Step 2: Refreshing Python dependencies"
if sudo pip3 install --break-system-packages -r "$build/requirements.txt" >>"$log_file" 2>&1; then
    ok "requirements.txt is satisfied"
else
    err "pip install failed. Check $log_file."
    fail pip_install_failed 3
fi

# --- Step 3: compiled UI ------------------------------------------------------------
# Only on a source checkout. A compiled dist ships the UI prebuilt.
step "Step 3: Recompiling UI files"
if [ -f "$build/ui/compile_ui.py" ]; then
    python3 "$build/ui/compile_ui.py" >>"$log_file" 2>&1 \
        && ok "UI compiled" || warn "compile_ui.py error (see $log_file). Continuing."
else
    info "Compiled dist - UI ships prebuilt, nothing to recompile."
fi

# --- Step 3b: kiosk launcher -----------------------------------------------------
# Refreshed before the swap so the launcher that can roll back is already in
# place if power is lost halfway through it.
step "Step 3b: Refreshing the kiosk launcher"
if [ -f "$build/scripts/pl_start.sh" ]; then
    if sudo cp "$build/scripts/pl_start.sh" /opt/pl_start.sh >>"$log_file" 2>&1 \
       && sudo sed -i -- "s/DIR/${app_home////\\/}/g" /opt/pl_start.sh >>"$log_file" 2>&1; then
        ok "/opt/pl_start.sh refreshed"
    else
        warn "could not refresh /opt/pl_start.sh; the kiosk keeps its current launcher"
    fi
else
    info "No scripts/pl_start.sh in this build - leaving the launcher alone."
fi

# --- Step 4: swap in the new release ---------------------------------------------
if [ "$mode" = "install" ]; then
    step "Step 4: Switching to the new agent"
    rm -rf "$previous"
    mv "$app_home" "$previous" >>"$log_file" 2>&1 \
        || { err "Could not move the current agent aside."; fail swap_failed 4; }
    if ! mv "$staging" "$app_home" >>"$log_file" 2>&1; then
        mv "$previous" "$app_home"
        err "Could not move the new agent into place; kept the current one."
        fail swap_failed 4
    fi
    cd "$app_home" || fail swap_failed 4
    # Tells the launcher an update just happened, so it may roll back.
    mkdir -p "$HOME/.pl" && date +%s > "$HOME/.pl/update-pending"
    ok "Code: $ver_before -> $ver_after (previous version kept in $previous)"
fi

# --- Step 5: remote-access install (ttyd + wayvnc + noVNC + ngrok) ---------------
# setup_ngrok.sh is idempotent, which is what lets a unit predating the
# wayvnc/ttyd switch pick up those tunnels without a full ./setup.sh.
step "Step 5: Refreshing remote-access components"
if [ -z "${DTS_NGROK_AUTHTOKEN:-}" ]; then
    warn "DTS_NGROK_AUTHTOKEN is not set in .env - skipping remote-access refresh."
elif [ ! -f "$app_home/scripts/setup_ngrok.sh" ]; then
    warn "scripts/setup_ngrok.sh not found - skipping remote-access refresh."
elif sudo DTS_NON_INTERACTIVE=1 \
        DTS_NGROK_AUTHTOKEN="${DTS_NGROK_AUTHTOKEN}" \
        DTS_NGROK_PREFIX="${DTS_NGROK_PREFIX:-}" \
        DTS_SSH_TCP_ADDR="${DTS_SSH_TCP_ADDR:-}" \
        DTS_NGROK_DOMAIN="${DTS_NGROK_DOMAIN:-}" \
        DTS_ENABLE_SCREEN="${DTS_ENABLE_SCREEN:-}" \
        DTS_VNC_PASSWORD="${DTS_VNC_PASSWORD:-}" \
        bash "$app_home/scripts/setup_ngrok.sh" >>"$log_file" 2>&1; then
    ok "Remote-access stack is current"
else
    warn "setup_ngrok.sh reported an error (see $log_file). Continuing."
fi

# --- Step 6: restart anything that runs under systemd ----------------------------
# The kiosk agent runs from the desktop autostart, not systemd; the reboot at
# the end is what loads it.
step "Step 6: Restarting systemd-managed components"
if systemctl list-unit-files 2>/dev/null | grep -q '^ttyd\.service'; then
    # Output to the log: this restart may pull the terminal out from under us.
    if sudo systemctl restart ttyd >>"$log_file" 2>&1; then
        ok "ttyd restarted"
    else
        warn "ttyd restart failed; check journalctl -u ttyd"
    fi
fi
if systemctl list-unit-files 2>/dev/null | grep -q '^splashscreen\.service'; then
    sudo systemctl restart splashscreen 2>>"$log_file" || warn "splashscreen restart failed"
fi

# --- Done ---------------------------------------------------------------------------
step "Update complete"
info "Code: $ver_before -> $ver_after"
info "Log file: $log_file"
publish_status "{\"update_status\":\"completed\",\"update_new_version\":\"${ver_after}\"}"

# Dashboard-triggered updates set DTS_UPDATE_REBOOT=1 and reboot here; a manual
# run just prints the reminder.
if [ "${DTS_UPDATE_REBOOT:-0}" = "1" ]; then
    ok "Rebooting to load the new agent..."
    sleep 3          # let the telemetry frame flush before we go down
    sudo reboot
else
    ok "REBOOT THE PI to fully reload the touchscreen agent:  sudo reboot"
fi
exit 0
