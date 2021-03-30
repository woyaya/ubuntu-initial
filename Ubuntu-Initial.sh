#!/bin/bash

. config

LOG_LEVEL=${LOG_LEVEL:-2}
DBG(){
[ "$DEBUG" = "1" ] && echo "$@"
}
LOG(){
	[ $LOG_LEVEL -ge 4 ] && echo "${EXEC}: $@"
}
INF(){
	[ $LOG_LEVEL -ge 3 ] && echo "${EXEC}: $@"
}
WRN(){
	[ $LOG_LEVEL -ge 2 ] && {
		LOG "$@"
		logger -s "${EXEC}: $@"
	}
}
ERR(){
	[ $LOG_LEVEL -ge 1 ] && WRN "$@"
	exit 1
}

IPTABLE_CHAIN_NAME=SERVER_PORTS
IPTABLES_INIT(){
	set +e
	while true
	do
		local index=`iptables -L INPUT -n --line-numbers | head -n 1 | grep $IPTABLE_CHAIN_NAME | awk '{print $1}'`
		[ -z "$index" ] && break
		iptables -D INPUT $index
	done
	iptables -F $IPTABLE_CHAIN_NAME 2>/dev/null
	iptables -D $IPTABLE_CHAIN_NAME 2>/dev/null
	#Create new chain
	iptables -N $IPTABLE_CHAIN_NAME
	index=`iptables -L INPUT -n --line-numbers | tail -n 1 | awk '{print $1}'`
	[ "$index" -le "1" ] && index="" || index=`expr $index "-" 1`
	iptables -I INPUT $index -j $IPTABLE_CHAIN_NAME
}
IPTABLES_ADD_PORT(){
	set -e
	iptables -A $IPTABLE_CHAIN_NAME -p tcp --dport $1 -m state --state NEW -j ACCEPT 
}

INSTALL(){
	INF "Install $@"
	apt install -y $@
}

USER=`whoami`
[ "$USER" != "root" ] && ERR "Run as root"

#
CURR=`pwd`
ETHER=`ip route list default | sed 's/.* dev //;s/ .*//'`
DBG "Current dir: $CURR, Default ether: $ETHER"

#set -e
INF "Apt update"
apt update
# Install
INSTALL command-not-found
INSTALL tmux vim cron
INSTALL tree file
INSTALL git git-extras
INSTALL net-tools
INSTALL rsync
INSTALL iputils-ping

# Setting
[ -n "$TIMEZONE" ] && {
	INF "Update timezone to $TIMEZONE"
	timedatectl set-timezone $TIMEZONE
}

#Zerotier
[ -n "$ZEROTIER_NETWORKID" ] && {
	INF "Process with zerotier"
	ZEROTIER=`which zerotier-cli`
	[ -z "$ZEROTIER" ] && {
		curl -s https://install.zerotier.com | sudo bash
		INF "Waiting zerotier ready"
		sleep 3
	}
	NETWORK=`zerotier-cli info | grep ONLINE`
	[ -z "$NETWORK" ] && {
		INF "Join to network: $ZEROTIER_NETWORKID"
		zerotier-cli join $ZEROTIER_NETWORKID
	}
}


# dynv6
[ -n "$DYNV6_TOKEN" -a -n "$DYNV6_HOSTS" ] && {
	mkdir -p git
	cd git
	set -e
	rm -rf dynv6
	git clone https://github.com/woyaya/dynv6
	cp -rf dynv6/dynv6 /usr/bin/
	chmod 754 /usr/bin/dynv6
	set +e
	[ "$DYNV6_WITH_IPV6" = "1" ] && IPVER="-6" || IPVER="-4"
	crontab -l 2>/dev/null | grep -v "/usr/bin/dynv6" >crontab.org
	echo "*/5 * * * * /usr/bin/dynv6 -i $ETHER $IPVER -t $DYNV6_TOKEN $DYNV6_HOSTS" >>crontab.org
	crontab crontab.org
	rm -rf crontab.org
	cd  $CURR
}

# shadowsocks
[ -n "$SHADOWSOCKS_PORT" -a -n "$SHADOWSOCKS_PASSWD" ] && {
	apt install -y shadowsocks-libev
	METHOD=${SHADOWSOCKS_METHOD:-chacha20-ietf-poly1305}
	cat <<EOF >/etc/shadowsocks-libev/config.json
{
	"server":["::1", "0.0.0.0"],
	"mode":"tcp_and_udp",
	"server_port":${SHADOWSOCKS_PORT},
	"password":"$SHADOWSOCKS_PASSWD",
	"timeout":60,
	"method":"$METHOD"
}  
EOF
	/etc/init.d/shadowsocks-libev restart
	#iptables
	#iptables -I INPUT 6 -p tcp --dport 443 -j ACCEPT 
}

# apache PHP
INSTALL apache2 libapache2-mod-php
set -e
VER=${PHPVER:-7.4}
INSTALL php${VER} php${VER}-mbstring php${VER}-cli php${VER}-common php${VER}-json php${VER}-mbstring php${VER}-readline php${VER}-xml
set +e
a2enmod rewrite
a2enmod ssl
a2enmod proxy_http
a2enmod proxy_wstunnel
a2ensite 
systemctl restart apache2
