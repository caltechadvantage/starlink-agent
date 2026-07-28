#!/bin/bash

# Launcher for the bridge GUI, run from the autostart .desktop entry.
# setup.sh copies this to /opt/pl_start.sh and sed-replaces the placeholder
# below with the install dir. That sed is a plain substring replace, so no
# name here may contain the placeholder token - hence APP_HOME.
#
# A compiled dist ships no .py: main.pyc lives under a per-interpreter dir
# (py39/py311/py313), since bytecode is not portable across Python minors.

APP_HOME="DIR"
cd "$APP_HOME" || exit 1

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

echo "Starting main GUI application ($RUN_TARGET)..."
screen -mS pl -d
screen -S pl -X stuff "export DISPLAY=:0.0\\r"
# Source .env so QT_QPA_PLATFORM (xcb, needed for the screen mirror) and other
# provisioned vars reach the kiosk. The compiled-dist launcher, unlike run.sh,
# has no other place to apply them.
screen -S pl -X stuff "[ -f $APP_HOME/.env ] && set -a && . $APP_HOME/.env && set +a\\r"
screen -S pl -X stuff "export PYTHONPATH=$RUN_PYPATH\\r"
screen -S pl -X stuff "cd $APP_HOME\\r"
screen -S pl -X stuff "python3 $RUN_TARGET\\r"
