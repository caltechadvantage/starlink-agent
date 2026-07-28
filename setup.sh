#!/usr/bin/env bash

cur_dir="$( cd "$(dirname "$0")" ; pwd -P )"

# Load fleet/device settings (e.g. DTS_NGROK_AUTHTOKEN) if present.
# .env is gitignored. Vars are passed explicitly to the sudo'd ngrok step
# below (not via sudo -E, which default Pi sudoers often rejects).
if [ -f "${cur_dir}/.env" ]; then
    set -a; . "${cur_dir}/.env"; set +a
    echo "Loaded ${cur_dir}/.env"
fi

sudo apt update -y
sudo apt install -y libtiff-dev libwebp-dev python3-dev qt6-base-dev qt6-base-dev-tools libqt6gui6 libqt6widgets6 libqt6core6

# Installing grpcurl
wget https://github.com/fullstorydev/grpcurl/releases/download/v1.9.1/grpcurl_1.9.1_linux_arm64.tar.gz
tar -xzf grpcurl_1.9.1_linux_arm64.tar.gz
sudo mv grpcurl /usr/local/bin/
rm grpcurl_1.9.1_linux_arm64.tar.gz

# Installing mongodb
wget -qO - https://www.mongodb.org/static/pgp/server-4.4.asc | sudo apt-key add -
echo "deb [ arch=amd64,arm64 ] https://repo.mongodb.org/apt/ubuntu focal/mongodb-org/4.4 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-4.4.list
sudo apt update -y
sudo apt install -y mongodb-org
sudo systemctl enable mongod
sudo systemctl start mongod

sudo pip3 install --break-system-packages -U pip
sudo pip3 install --break-system-packages -r requirements.txt

# Clear desktop and install splash video/screen
bash ${cur_dir}/scripts/clear_desktop.sh
bash ${cur_dir}/scripts/install_splash.sh

# Enable I2C
echo "dtparam=i2c_arm=on" | sudo tee -a /boot/firmware/config.txt

# Disable virtual keyboard
sudo raspi-config nonint do_squeekboard S3

# Enable Auto Start
sudo apt install -y screen
sudo cp ${cur_dir}/scripts/pl_start.sh /opt/
sudo sed -i -- "s/DIR/${cur_dir////\\/}/g" /opt/pl_start.sh
mkdir -p ~/.config/autostart
cat > ~/.config/autostart/pl.desktop <<EOL
[Desktop Entry]
Type=Application
Exec=bash /opt/pl_start.sh
EOL

# Remote access (ngrok) — auto-configured when an authtoken is available.
# Prefix is derived from the device serial, so no per-device input is needed.
if [ -n "${DTS_NGROK_AUTHTOKEN:-}" ]; then
    echo "Setting up ngrok remote access..."
    # Pass settings explicitly (reliable under default sudoers; empty values
    # fall back to the script's own defaults via ${VAR:-default}).
    sudo DTS_NON_INTERACTIVE=1 \
         DTS_NGROK_AUTHTOKEN="${DTS_NGROK_AUTHTOKEN}" \
         DTS_NGROK_PREFIX="${DTS_NGROK_PREFIX:-}" \
         DTS_SSH_TCP_ADDR="${DTS_SSH_TCP_ADDR:-}" \
         DTS_NGROK_DOMAIN="${DTS_NGROK_DOMAIN:-}" \
         DTS_ENABLE_SCREEN="${DTS_ENABLE_SCREEN:-}" \
         bash ${cur_dir}/scripts/setup_ngrok.sh
else
    echo "Skipping ngrok setup — add DTS_NGROK_AUTHTOKEN to ${cur_dir}/.env to enable."
fi
