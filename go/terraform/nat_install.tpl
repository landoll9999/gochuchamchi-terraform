#!/bin/bash

# AL2023 최신 이미지에는 iptables가 기본 설치돼 있지 않아서 먼저 설치
sudo dnf install -y iptables

echo "net.ipv4.ip_forward = 1" | sudo tee -a /etc/sysctl.d/99-custom-nat.conf
sudo sysctl -p /etc/sysctl.d/99-custom-nat.conf
IFACE=$(ip route show default | awk '/default/ {print $5}')
sudo iptables -t nat -A POSTROUTING -o $IFACE -j MASQUERADE
