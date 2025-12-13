#!/bin/bash
tput setaf 7 ; tput setab 4 ; tput bold ; printf '%35s%s%-20s\n' "TCP Tweaker 1.0" ; tput sgr0
SYSCTL_CONF="/etc/sysctl.d/99-vpn-optimizer.conf"
SYSCTL_MAIN_CONF="/etc/sysctl.conf"

mkdir -p /etc/sysctl.d
touch "$SYSCTL_CONF"
touch "$SYSCTL_MAIN_CONF"

sync_sysctl_conf() {
    cp "$SYSCTL_CONF" "$SYSCTL_MAIN_CONF"
}

apply_sysctl_changes() {
    sync_sysctl_conf
    sysctl --system "$@"
}

if [[ `grep -c "^#PH56" "$SYSCTL_CONF"` -eq 1 ]]
then
        echo ""
        echo "TCP Tweaker network settings have already been added to the system!"
	echo ""
	read -p "Do you want to remove TCP Tweaker settings? [y/n]: " -e -i n resposta0
        if [[ "$resposta0" = 'y' ]]; then
                grep -v "^#PH56
net.ipv4.tcp_window_scaling = 1
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 16384 16777216
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_slow_start_after_idle = 0" "$SYSCTL_CONF" > /tmp/syscl && mv /tmp/syscl "$SYSCTL_CONF"
                apply_sysctl_changes > /dev/null
		echo ""
		echo "TCP Tweaker network settings were successfully removed."
		echo ""
	exit
	else 
		echo ""
		exit
	fi
else
	echo ""
	echo "This is an experimental script. Use at your own risk!"
	echo "This script will change some network settings"
	echo "to reduce latency and improve speed."
	echo ""
	read -p "Proceed with installation? [y/n]: " -e -i n resposta
	if [[ "$resposta" = 'y' ]]; then
        echo ""
        echo "Modifying the following settings:"
        echo " " >> "$SYSCTL_CONF"
        echo "#PH56" >> "$SYSCTL_CONF"
        echo "net.ipv4.tcp_window_scaling = 1
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 16384 16777216
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_slow_start_after_idle = 0" >> "$SYSCTL_CONF"
        echo ""
        apply_sysctl_changes
		echo ""
		echo "TCP Tweaker network settings have been added successfully."
		echo ""
	else
		echo ""
		echo "Installation was canceled by the user!"
		echo ""
	fi
fi
exit
