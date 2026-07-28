#!/bin/bash

# Load environment variables if .env file exists
if [ -f ".env" ]; then
    source .env
    echo "Loaded environment variables from .env file"
fi

# Set fallback environment variables for Raspberry Pi (PySide6 compatible)
export QT_QPA_PLATFORM=${QT_QPA_PLATFORM:-eglfs}
export QT_QPA_EGLFS_PHYSICAL_WIDTH=${QT_QPA_EGLFS_PHYSICAL_WIDTH:-800}
export QT_QPA_EGLFS_PHYSICAL_HEIGHT=${QT_QPA_EGLFS_PHYSICAL_HEIGHT:-600}
export QT_AUTO_SCREEN_SCALE_FACTOR=${QT_AUTO_SCREEN_SCALE_FACTOR:-1}
export QT_API=${QT_API:-pyside6}
export QT_QPA_EGLFS_ALWAYS_SET_MODE=${QT_QPA_EGLFS_ALWAYS_SET_MODE:-1}
export QT_QPA_EGLFS_KMS_CONFIG=${QT_QPA_EGLFS_KMS_CONFIG:-/dev/dri/card0}
export QT_QPA_EGLFS_FORCE_32BIT=${QT_QPA_EGLFS_FORCE_32BIT:-1}
export QT_QPA_EGLFS_DISABLE_INPUT=${QT_QPA_EGLFS_DISABLE_INPUT:-1}
export DISPLAY=${DISPLAY:-:0}

echo "Starting Starlink Router Monitor with environment:"
echo "QT_QPA_PLATFORM: $QT_QPA_PLATFORM"
echo "QT_API: $QT_API"
echo "DISPLAY: $DISPLAY"

# Run the application
python3 main.py 