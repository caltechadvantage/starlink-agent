#!/bin/bash

cur_dir="$( cd "$(dirname "$0")" ; pwd -P )"
user="$(id -u -n)"

sudo apt install -y fbi
sudo cp ${cur_dir}/../assets/splash.png /usr/share/plymouth/themes/pix/splash.png
sudo cp ${cur_dir}/../assets/splash.jpg /usr/share/rpd-wallpaper/fisherman.jpg
sudo cp ${cur_dir}/splashscreen.service /etc/systemd/system/splashscreen.service
sudo plymouth-set-default-theme --rebuild-initrd pix
sudo systemctl enable splashscreen
