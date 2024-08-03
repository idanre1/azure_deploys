#!/bin/bash
#wget https://github.com/idanre1/azure_deploys/raw/main/openvpn.sh; chmod +x openvpn.sh; ./openvpn.sh

# echo "*** Detect IP"
# ipv4=`dig -4 TXT +short o-o.myaddr.l.google.com @ns1.google.com | tr -d '"'`

echo "*** Grab openvpn"
wget https://git.io/vpn -O openvpn-install.sh
sudo chmod +x openvpn-install.sh

echo "*** install openvpn"
printf "1\n\n1\ndefault\n\n" | sudo bash openvpn-install.sh
