# openvpn server
https://www.cyberciti.biz/faq/howto-setup-openvpn-server-on-ubuntu-linux-14-04-or-16-04-lts/
- Use `openvpn.sh` to instal a freshly new server to serve as vpn
- Then add firewall inbound ports
  - https tcp 443
  - openvpn udp 1194
# server address
```
network address space 10.8.0.0/24
vpn gateway 10.8.0.1
```
# download client
https://openvpn.net/client/client-connect-vpn-for-windows/
# add split-tunnel to config file
```
route 10.8.0.0 255.255.255.0
route-nopull
```
