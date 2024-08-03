# openvpn server
Use `openvpn.sh` to instal a freshly new server to serve as vpn
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
