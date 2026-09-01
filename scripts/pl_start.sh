#!/bin/bash

# Launcher for the bridge GUI, run from the autostart .desktop entry.
# setup.sh copies this to /opt/pl_start.sh and sed-replaces the placeholder
# below with the install dir. That sed is a plain substring replace, so no
# name here may contain the placeholder token - hence APP_HOME.
#
# A compiled dist ships no .py: main.pyc lives under a per-interpreter dir
# (py39/py311/py313), since bytecode is not portable across Python minors.
#
# Two modes. With no arguments it opens the detached screen session the kiosk
# lives in and hands off to itself. With --supervise it is already inside that
# session, and keeps the app running.

SELF="$(readlink -f "$0")"

APP_HOME="DIR"
cd "$APP_HOME" || exit 1

RESTART_LOG="$HOME/.pl/agent-restarts.log"

PYVER="$(python3 -c 'import sys; print("py%d%d" % sys.version_info[:2])')"

if [ -f main.py ]; then
    RUN_TARGET="main.py"
    RUN_PYPATH="$APP_HOME"
elif [ -f "$PYVER/main.pyc" ]; then
    RUN_TARGET="$PYVER/main.pyc"
    RUN_PYPATH="$APP_HOME/$PYVER:$APP_HOME"
else
    echo "ERROR: no main.py or $PYVER/main.pyc in $APP_HOME" >&2
    exit 1
fi

if [ "$1" = "--supervise" ]; then
    export DISPLAY=:0.0
    # Source .env so QT_QPA_PLATFORM (xcb, needed for the screen mirror) and
    # other provisioned vars reach the kiosk. The compiled-dist launcher,
    # unlike run.sh, has no other place to apply them.
    if [ -f "$APP_HOME/.env" ]; then
        set -a
        . "$APP_HOME/.env"
        set +a
    fi
    export PYTHONPATH="$RUN_PYPATH"
    mkdir -p "$(dirname "$RESTART_LOG")"

    # main.py catches exceptions on its own main thread and rebuilds the
    # window in process. That cannot help when the process itself dies: a
    # segfault, an abort out of Qt, the OOM killer, or anything raised in the
    # constructor before the event loop is running. Those left the screen
    # blank until someone power cycled the unit.
    #
    # Back off after repeated fast exits so a kit that cannot start at all
    # does not spin on it, and record every restart so the reason is
    # findable afterwards.
    fails=0
    while true; do
        started=$(date +%s)
        python3 "$RUN_TARGET"
        rc=$?
        ran=$(( $(date +%s) - started ))
        if [ "$ran" -lt 30 ]; then
            fails=$(( fails + 1 ))
        else
            fails=0
        fi
        if [ "$fails" -ge 5 ]; then
            delay=60
        else
            delay=5
        fi
        echo "$(date '+%Y-%m-%d %H:%M:%S') agent exited rc=$rc after ${ran}s," \
             "consecutive fast exits=$fails, restarting in ${delay}s" \
             | tee -a "$RESTART_LOG"
        sleep "$delay"
    done
fi

echo "Starting main GUI application ($RUN_TARGET)..."
screen -mS pl -d
screen -S pl -X stuff "bash $SELF --supervise\\r"
