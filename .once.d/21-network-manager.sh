#!/usr/bin/env sh

# NetworkManager tweaks

# don't wait on networking during startup
sudo systemctl disable NetworkManager-wait-online.service

# allow network-manager to manage wired devices from /etc/network/interfaces
CONF='/etc/NetworkManager/NetworkManager.conf'
KEY='managed'
OPTION='true'

# append required key if it doesn't exist
grep -q "$KEY" "$CONF" || echo "$KEY" | sudo tee -a "$CONF"
sed "/.*$KEY/c $KEY=$OPTION" < "$CONF" | sudo tee "$CONF"
sudo systemctl restart network-manager
