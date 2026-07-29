#!/bin/bash

cur_dir="$( cd "$(dirname "$0")" ; pwd -P )"

# Hide top menu bar
echo "autohide=true" | tee -a ~/.config/wf-panel-pi.ini
echo "autohide_duration=0" | tee -a ~/.config/wf-panel-pi.ini

sudo sed -i '/^[^#].*wfrespawn wf-panel-pi/ s/^/# /' /etc/wayfire/defaults.ini

sudo cp ${cur_dir}/../scripts/desktop-items-0.conf /etc/xdg/pcmanfm/LXDE-pi/desktop-items-0.conf

# Remove SSH warning
sudo apt purge -y libpam-chksshpwd

# Remove login prompt
sudo systemctl disable getty@tty1

# Disable screen saver
echo "xset s off" | sudo tee -a /etc/xdg/lxsession/LXDE-pi/autostart
echo "@xset s noblank" | sudo tee -a /etc/xdg/lxsession/LXDE-pi/autostart
echo "xset -dpms" | sudo tee -a /etc/xdg/lxsession/LXDE-pi/autostart

# Disable some services to reduce booting time
sudo systemctl disable hciuart
echo "boot_delay=0" | sudo tee -a /boot/firmware/config.txt
echo "dtoverlay=disable-bt" | sudo tee -a /boot/firmware/config.txt
echo "hdmi_force_hotplug=1" | sudo tee -a /boot/firmware/config.txt

# Hide mouse cursor
sudo sed -i -- "s/#xserver-command=X/xserver-command=X -nocursor/" /etc/lightdm/lightdm.conf
# another solution to hide at the time of boot. No elegant but works
sudo mv /usr/share/icons/PiXflat/cursors/left_ptr /usr/share/icons/PiXflat/cursors/left_ptr.bak
