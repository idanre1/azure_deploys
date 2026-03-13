#!/usr/bin/env bash
set -euo pipefail

# How to run
# sudo bash deploy_lan_pbx.sh \
#  --concurrent-calls 20 \
#  --transport both \
#  --pattern 10XX \
#  --install-path /opt/lan-pbx \
#  --bind-ip 192.168.1.10

################################################################################
# LAN PBX (Asterisk PJSIP) - Docker Compose Deployment Script
#
# What you get:
# - Asterisk PBX running in Docker Compose.
# - LAN-only deployment (binds to a selected host IP; default auto-detected).
# - Modular, maintainable config:
#     <CONFIG_PATH>/
#       pjsip.conf            (base + templates + includes)
#       pjsip.d/*.conf        (one file per extension/user)
#       extensions.conf       (dialplan using wildcard pattern)
#       rtp.conf              (RTP port range)
#
# How dialing works (wildcard):
# - EXT_PATTERN is an Asterisk dialplan pattern WITHOUT the leading underscore.
#   Example: EXT_PATTERN="10XX" matches 1000-1099.
#   Dialplan uses: exten => _10XX,1,Dial(PJSIP/${EXTEN},30)
#
# How to add users (after deployment):
# - Use the helper script created by this deployment:
#     <INSTALL_PATH>/bin/add-user.sh 1001 'StrongPassword'
#   This will:
#   - create <CONFIG_PATH>/pjsip.d/1001.conf
#   - reload PJSIP + dialplan in Asterisk (no container restart)
#
# How to remove users:
#     <INSTALL_PATH>/bin/del-user.sh 1001
#   Then reloads.
#
# Useful operational commands:
# - Asterisk CLI:
#     docker exec -it lan-pbx-asterisk asterisk -rvvv
# - Show registered phones:
#     docker exec -it lan-pbx-asterisk asterisk -rx "pjsip show contacts"
# - Reload config (after manual edits):
#     docker exec -it lan-pbx-asterisk asterisk -rx "pjsip reload"
#     docker exec -it lan-pbx-asterisk asterisk -rx "dialplan reload"
#
# Notes on "dynamic add":
# - File-based config supports "add on the fly" by adding a file + reload.
# - For fully DB-driven provisioning at scale, Asterisk supports PJSIP Realtime,
#   but that adds DB/ODBC complexity and isn't necessary for this LAN-only PBX.
################################################################################

# -----------------------------
# Defaults (reasonable)
# -----------------------------
CONCURRENT_CALLS_DEFAULT=20
TRANSPORT_DEFAULT="udp"         # udp | tcp | both
EXT_PATTERN_DEFAULT="10XX"      # without leading underscore
INSTALL_PATH_DEFAULT="/opt/lan-pbx"
CONFIG_PATH_DEFAULT=""          # if empty => INSTALL_PATH/config
BIND_IP_DEFAULT=""              # if empty => auto-detect primary IPv4
SIP_PORT_DEFAULT=5060
RTP_START_DEFAULT=10000

# RTP port inference heuristic:
# - Typical calls need ~2 RTP ports per call (one per direction), but we add headroom.
# - We allocate max(200, 10 * N) ports to be conservative for a small LAN PBX.
#   For N=20 => 200 ports => 10000-10199
RTP_PORTS_MIN=200
RTP_PORTS_PER_CALL=10

# -----------------------------
# CLI parsing
# -----------------------------
CONCURRENT_CALLS="${CONCURRENT_CALLS_DEFAULT}"
TRANSPORT="${TRANSPORT_DEFAULT}"
EXT_PATTERN="${EXT_PATTERN_DEFAULT}"
INSTALL_PATH="${INSTALL_PATH_DEFAULT}"
CONFIG_PATH="${CONFIG_PATH_DEFAULT}"
BIND_IP="${BIND_IP_DEFAULT}"
SIP_PORT="${SIP_PORT_DEFAULT}"
RTP_START="${RTP_START_DEFAULT}"

usage() {
  cat <<EOF
Usage: sudo $0 [options]

Options:
  -n, --concurrent-calls N     Concurrent calls target (default: ${CONCURRENT_CALLS_DEFAULT})
  -t, --transport MODE         udp | tcp | both (default: ${TRANSPORT_DEFAULT})
  -p, --pattern PATTERN        Extension wildcard pattern w/out '_' (default: ${EXT_PATTERN_DEFAULT})
                              Example: 10XX matches 1000-1099
  -i, --install-path PATH      Installation path (default: ${INSTALL_PATH_DEFAULT})
  -c, --config-path PATH       Config path (default: <install-path>/config)
  -b, --bind-ip IP             Bind SIP/RTP ports only on this host IP (default: auto-detect)
  --sip-port PORT              SIP port (default: ${SIP_PORT_DEFAULT})
  --rtp-start PORT             RTP start port (default: ${RTP_START_DEFAULT})
  -h, --help                   Show this help

Examples:
  sudo $0
  sudo $0 -n 20 -t both -p 10XX -i /opt/lan-pbx -b 192.168.1.10
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--concurrent-calls) CONCURRENT_CALLS="$2"; shift 2;;
    -t|--transport)        TRANSPORT="$2"; shift 2;;
    -p|--pattern)          EXT_PATTERN="$2"; shift 2;;
    -i|--install-path)     INSTALL_PATH="$2"; shift 2;;
    -c|--config-path)      CONFIG_PATH="$2"; shift 2;;
    -b|--bind-ip)          BIND_IP="$2"; shift 2;;
    --sip-port)            SIP_PORT="$2"; shift 2;;
    --rtp-start)           RTP_START="$2"; shift 2;;
    -h|--help)             usage; exit 0;;
    *) echo "Unknown option: $1"; usage; exit 1;;
  esac
done

# -----------------------------
# Validation
# -----------------------------
if ! [[ "${CONCURRENT_CALLS}" =~ ^[0-9]+$ ]] || [[ "${CONCURRENT_CALLS}" -le 0 ]]; then
  echo "ERROR: --concurrent-calls must be a positive integer"
  exit 1
fi

case "${TRANSPORT}" in
  udp|tcp|both) ;;
  *) echo "ERROR: --transport must be udp|tcp|both"; exit 1;;
esac

if [[ -z "${EXT_PATTERN}" ]]; then
  echo "ERROR: --pattern cannot be empty"
  exit 1
fi

if [[ -z "${CONFIG_PATH}" ]]; then
  CONFIG_PATH="${INSTALL_PATH}/config"
fi

# -----------------------------
# Auto-detect bind IP if needed
# -----------------------------
if [[ -z "${BIND_IP}" ]]; then
  # Choose first non-loopback IPv4 (simple + works on fresh Ubuntu)
  BIND_IP="$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
  if [[ -z "${BIND_IP}" ]]; then
    echo "ERROR: Could not auto-detect a global IPv4 address. Please provide --bind-ip."
    exit 1
  fi
fi

# -----------------------------
# Infer RTP port range from N
# -----------------------------
RTP_PORTS=$(( CONCURRENT_CALLS * RTP_PORTS_PER_CALL ))
if [[ "${RTP_PORTS}" -lt "${RTP_PORTS_MIN}" ]]; then
  RTP_PORTS="${RTP_PORTS_MIN}"
fi
RTP_END=$(( RTP_START + RTP_PORTS - 1 ))

# Ensure even start (often preferred for RTP allocations)
if (( RTP_START % 2 == 1 )); then
  RTP_START=$(( RTP_START + 1 ))
  RTP_END=$(( RTP_START + RTP_PORTS - 1 ))
fi

# -----------------------------
# Prepare directories
# -----------------------------
mkdir -p "${INSTALL_PATH}/"{bin,log}
mkdir -p "${CONFIG_PATH}/"{pjsip.d,extensions.d}

# -----------------------------
# Generate docker-compose.yml
# -----------------------------
COMPOSE_FILE="${INSTALL_PATH}/docker-compose.yml"
ASTERISK_IMAGE="andrius/asterisk:stable"
CONTAINER_NAME="lan-pbx-asterisk"

# Port bindings (bind to specific host IP to keep it LAN-only by interface selection)
PORT_LINES=()
PORT_LINES+=("      - \"${BIND_IP}:${SIP_PORT}:${SIP_PORT}/udp\"")
if [[ "${TRANSPORT}" == "tcp" || "${TRANSPORT}" == "both" ]]; then
  PORT_LINES+=("      - \"${BIND_IP}:${SIP_PORT}:${SIP_PORT}/tcp\"")
fi
PORT_LINES+=("      - \"${BIND_IP}:${RTP_START}-${RTP_END}:${RTP_START}-${RTP_END}/udp\"")

cat > "${COMPOSE_FILE}" <<EOF
services:
  asterisk:
    image: ${ASTERISK_IMAGE}
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    ports:
$(printf "%s\n" "${PORT_LINES[@]}")
    volumes:
      - ${CONFIG_PATH}:/etc/asterisk
      - ${INSTALL_PATH}/log:/var/log/asterisk
    environment:
      - TZ=Asia/Jerusalem
EOF

# -----------------------------
# Generate Asterisk configs
# -----------------------------
PJSIP_CONF="${CONFIG_PATH}/pjsip.conf"
EXTENSIONS_CONF="${CONFIG_PATH}/extensions.conf"
RTP_CONF="${CONFIG_PATH}/rtp.conf"

# pjsip.conf: base + templates + include users
cat > "${PJSIP_CONF}" <<EOF
;------------------------------------------------------------------------------
; PJSIP base configuration (LAN PBX)
; - Uses templates to reduce repetition
; - Includes per-user endpoint definitions from pjsip.d/*.conf
;------------------------------------------------------------------------------

[global]
type=global
user_agent=LAN-PBX

; --- Transports ---
[transport-udp]
type=transport
protocol=udp
bind=${BIND_IP}:${SIP_PORT}

EOF

if [[ "${TRANSPORT}" == "tcp" || "${TRANSPORT}" == "both" ]]; then
cat >> "${PJSIP_CONF}" <<EOF
[transport-tcp]
type=transport
protocol=tcp
bind=${BIND_IP}:${SIP_PORT}

EOF
fi

cat >> "${PJSIP_CONF}" <<'EOF'
; --- Templates ---
endpoint-common
type=endpoint
context=from-internal
disallow=all
allow=ulaw,alaw
direct_media=no
rewrite_contact=yes
rtp_symmetric=yes
force_rport=yes

auth-common
type=auth
auth_type=userpass

aor-common
type=aor
max_contacts=1
remove_existing=yes

; --- Include per-user endpoints ---
#include pjsip.d/*.conf
EOF

# rtp.conf: match published range
cat > "${RTP_CONF}" <<EOF
[general]
rtpstart=${RTP_START}
rtpend=${RTP_END}
EOF

# extensions.conf: wildcard dialing
# Note: Asterisk patterns require leading underscore, we add it here.
cat > "${EXTENSIONS_CONF}" <<EOF
;------------------------------------------------------------------------------
; Dialplan (LAN PBX)
; Wildcard extension pattern: _${EXT_PATTERN}
; Example: EXT_PATTERN=10XX means 1000-1099.
;------------------------------------------------------------------------------

[from-internal]
exten => _${EXT_PATTERN},1,Dial(PJSIP/\${EXTEN},30)
 same => n,Hangup()

; Optional: Echo test (*43)
exten => *43,1,Answer()
 same => n,Echo()
 same => n,Hangup()
EOF

# -----------------------------
# Helper scripts: add-user / del-user
# -----------------------------
ADD_USER="${INSTALL_PATH}/bin/add-user.sh"
DEL_USER="${INSTALL_PATH}/bin/del-user.sh"

cat > "${ADD_USER}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

EXT="\${1:-}"
PASS="\${2:-}"

if [[ -z "\${EXT}" || -z "\${PASS}" ]]; then
  echo "Usage: \$0 <extension> <password>"
  exit 1
fi

CONF_DIR="${CONFIG_PATH}/pjsip.d"
FILE="\${CONF_DIR}/\${EXT}.conf"

if [[ -f "\${FILE}" ]]; then
  echo "ERROR: Extension \${EXT} already exists: \${FILE}"
  exit 1
fi

cat > "\${FILE}" <<EOC
\${EXT}
auth=\${EXT}
aors=\${EXT}
callerid=User \${EXT} <\${EXT}>
; If using TCP transport by default for endpoints, you can set:
; transport=transport-tcp

\${EXT}
username=\${EXT}
password=\${PASS}

\${EXT}
EOC

echo "Created: \${FILE}"

# Reload Asterisk config (no restart)
docker exec -it ${CONTAINER_NAME} asterisk -rx "pjsip reload" >/dev/null
docker exec -it ${CONTAINER_NAME} asterisk -rx "dialplan reload" >/dev/null

echo "Reloaded Asterisk. Extension \${EXT} is ready to register."
EOF

cat > "${DEL_USER}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

EXT="\${1:-}"
if [[ -z "\${EXT}" ]]; then
  echo "Usage: \$0 <extension>"
  exit 1
fi

FILE="${CONFIG_PATH}/pjsip.d/\${EXT}.conf"
if [[ ! -f "\${FILE}" ]]; then
  echo "ERROR: Extension \${EXT} not found: \${FILE}"
  exit 1
fi

rm -f "\${FILE}"
echo "Removed: \${FILE}"

docker exec -it ${CONTAINER_NAME} asterisk -rx "pjsip reload" >/dev/null
docker exec -it ${CONTAINER_NAME} asterisk -rx "dialplan reload" >/dev/null

echo "Reloaded Asterisk. Extension \${EXT} removed."
EOF

chmod +x "${ADD_USER}" "${DEL_USER}"

# -----------------------------
# Bring up the stack
# -----------------------------
echo "============================================================"
echo "Deploying LAN PBX (Asterisk) with:"
echo "  Install path      : ${INSTALL_PATH}"
echo "  Config path       : ${CONFIG_PATH}"
echo "  Bind IP           : ${BIND_IP}"
echo "  SIP port          : ${SIP_PORT}"
echo "  Transport         : ${TRANSPORT}"
echo "  Concurrent calls  : ${CONCURRENT_CALLS}"
echo "  RTP port range    : ${RTP_START}-${RTP_END} (ports=${RTP_PORTS})"
echo "  Ext wildcard      : _${EXT_PATTERN}"
echo "============================================================"

docker compose -f "${COMPOSE_FILE}" up -d

echo
echo "PBX is up."
echo
echo "Next steps:"
echo "  1) Add users:"
echo "     ${ADD_USER} 1000 'StrongPasswordHere'"
echo "     ${ADD_USER} 1001 'StrongPasswordHere'"
echo
echo "  2) Configure your SIP clients:"
echo "     Server/Registrar: ${BIND_IP}"
echo "     Port           : ${SIP_PORT}"
echo "     User/Auth ID   : 1000"
echo "     Password       : StrongPasswordHere"
echo
echo "  3) Check registrations:"
echo "     docker exec -it ${CONTAINER_NAME} asterisk -rx \"pjsip show contacts\""
echo
echo "  4) Enter Asterisk CLI:"
echo "     docker exec -it ${CONTAINER_NAME} asterisk -rvvv"
echo
echo "Done."
