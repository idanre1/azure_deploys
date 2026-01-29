#!/usr/bin/env bash
set -euo pipefail
# pipefail -euo: early script failure with mandating pipe failures for any command failing inside them

# deploy_ollama_service.sh
# Creates and configures systemd services for Ollama (server + warmup) with CPU performance tweaks.
# Requires: systemd-based Linux, root privileges.
# wget https://github.com/idanre1/azure_deploys/raw/refs/heads/main/ai_local/deploy_ollama_service.sh; chmod +x deploy_ollama_service.sh

usage() {
  cat <<'USAGE'
Usage: sudo ./deploy_ollama_service.sh [options]

Options:
  --base-model NAME        Base model to pull and derive from (default: llama3.1:8b-instruct-q4_K_M)
  --profile-name NAME      Name for the derived model profile (default: cpu-opt)
  --num-ctx N              Context window tokens (default: 4096)
  --threads N              Threads for OMP/GGML/OLLAMA (default: nproc)
  --port P                 Port to bind on localhost (default: 11434)
  --hugepages N            Configure vm.nr_hugepages (persistent). 0 = skip (default: 0)
  --install-ollama         Install Ollama using official install script if missing
  --no-warmup              Do not create/enable warmup service
  --temperature T          Temperature (written into Modelfile) (default: 0.7)
  --top-p P                Top-p (written into Modelfile) (default: 0.9)
  --top-k K                Top-k (written into Modelfile) (default: 40)
  --repeat-penalty R       Repeat penalty (written into Modelfile) (default: 1.1)
  --keep-alive DURATION    Keep-alive for server (e.g. 5m, 1h) (optional)
  --force-recreate         Always recreate the derived model profile
  -h, --help               Show this help

Examples:
  sudo ./deploy_ollama_service.sh --install-ollama

  sudo ./deploy_ollama_service.sh \
    --base-model llama3.1:8b-instruct-q4_K_M \
    --profile-name llama3.1-8b-cpu-opt \
    --num-ctx 4096 \
    --threads 2 \
    --port 11434 \
    --hugepages 1024 \
    --install-ollama \
    --force-recreate

USAGE
}
# maybe 4096 hughpages???

require_root() {
  if [[ ${EUID:-$UID} -ne 0 ]]; then
    echo "[ERROR] Please run as root (use sudo)." >&2
    exit 1
  fi
}

check_systemd() {
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "[ERROR] systemctl not found. This script requires systemd." >&2
    exit 1
  fi
}

BASE_MODEL="llama3.1:8b-instruct-q4_K_M"
PROFILE_NAME="cpu-opt"
NUM_CTX=4096
THREADS="$(nproc)"
PORT=11434
HUGEPAGES=0
INSTALL_OLLAMA=0
WARMUP=1
TEMP=0.7
TOPP=0.9
TOPK=40
REPEAT_PENALTY=1.1
KEEP_ALIVE=""
FORCE_RECREATE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-model) BASE_MODEL="$2"; shift 2;;
    --profile-name) PROFILE_NAME="$2"; shift 2;;
    --num-ctx) NUM_CTX="$2"; shift 2;;
    --threads) THREADS="$2"; shift 2;;
    --port) PORT="$2"; shift 2;;
    --hugepages) HUGEPAGES="$2"; shift 2;;
    --install-ollama) INSTALL_OLLAMA=1; shift;;
    --no-warmup) WARMUP=0; shift;;
    --temperature) TEMP="$2"; shift 2;;
    --top-p) TOPP="$2"; shift 2;;
    --top-k) TOPK="$2"; shift 2;;
    --repeat-penalty) REPEAT_PENALTY="$2"; shift 2;;
    --keep-alive) KEEP_ALIVE="$2"; shift 2;;
    --force-recreate) FORCE_RECREATE=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "[ERROR] Unknown argument: $1" >&2; usage; exit 1;;
  esac
 done

require_root
check_systemd

# Optionally install Ollama
if [[ $INSTALL_OLLAMA -eq 1 ]]; then
  if ! command -v ollama >/dev/null 2>&1; then
    echo "[INFO] Installing Ollama..."
    curl -fsSL https://ollama.com/install.sh | sh
  else
    echo "[INFO] Ollama already installed. Skipping installation."
  fi
fi

# Verify ollama binary path
if ! command -v ollama >/dev/null 2>&1; then
  echo "[ERROR] ollama not found. Use --install-ollama or install manually." >&2
  exit 1
fi
OLLAMA_BIN="$(command -v ollama)"

# Configure huge pages if requested
if [[ "$HUGEPAGES" -gt 0 ]]; then
  echo "[INFO] Configuring huge pages: vm.nr_hugepages=$HUGEPAGES"
  sysctl -w vm.nr_hugepages="${HUGEPAGES}" >/dev/null
  echo "vm.nr_hugepages=${HUGEPAGES}" > /etc/sysctl.d/99-ollama-hugepages.conf
fi

# Pull base model
echo "[INFO] Pulling base model: ${BASE_MODEL}"
${OLLAMA_BIN} pull "${BASE_MODEL}"

# Create derived model profile via Modelfile
DERIVED_MODEL="${PROFILE_NAME}"
# If user provided a name without a tag, keep it; otherwise accept tags.
# We will create it exactly as given.

MODEL_DIR="/etc/ollama"
mkdir -p "${MODEL_DIR}"
MODELF="${MODEL_DIR}/Modelfile.${DERIVED_MODEL//\//_}"

cat > "${MODELF}" <<EOF
FROM ${BASE_MODEL}
PARAMETER num_ctx ${NUM_CTX}
PARAMETER temperature ${TEMP}
PARAMETER top_p ${TOPP}
PARAMETER top_k ${TOPK}
PARAMETER repeat_penalty ${REPEAT_PENALTY}
EOF

if [[ -n "${KEEP_ALIVE}" ]]; then
  echo "PARAMETER keep_alive ${KEEP_ALIVE}" >> "${MODELF}"
fi

# Decide whether to (re)create
if [[ $FORCE_RECREATE -eq 1 ]]; then
  echo "[INFO] Recreating derived model (forced): ${DERIVED_MODEL}"
  ${OLLAMA_BIN} create "${DERIVED_MODEL}" -f "${MODELF}"
else
  # If model doesn't exist, create it; otherwise leave as is
  if ! ${OLLAMA_BIN} list | awk '{print $1}' | grep -Fxq "${DERIVED_MODEL}"; then
    echo "[INFO] Creating derived model: ${DERIVED_MODEL}"
    ${OLLAMA_BIN} create "${DERIVED_MODEL}" -f "${MODELF}"
  else
    echo "[INFO] Derived model already exists: ${DERIVED_MODEL} (use --force-recreate to update)"
  fi
fi

# Create systemd service for Ollama
cat > /etc/systemd/system/ollama.service <<SERVICE
[Unit]
Description=Ollama LLM Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${OLLAMA_BIN} serve

Environment="HOME=/usr/share/ollama"

# CPU performance tuning
Environment=OMP_NUM_THREADS=${THREADS}
Environment=GGML_NUM_THREADS=${THREADS}
Environment=OLLAMA_NUM_THREADS=${THREADS}

# Bind to localhost only
Environment=OLLAMA_HOST=127.0.0.1:${PORT}

# Use huge pages if enabled in the system
Environment=GGML_USE_HUGEPAGES=1

Restart=always
RestartSec=3
LimitNOFILE=1048576
LimitNPROC=1048576

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
SERVICE

# Warmup service (optional)
if [[ $WARMUP -eq 1 ]]; then
  cat > /etc/systemd/system/ollama-warmup.service <<WARMUP
[Unit]
Description=Warm up Ollama model (${DERIVED_MODEL})
After=ollama.service
Requires=ollama.service

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 3
ExecStart=/bin/bash -lc '\
  ${OLLAMA_BIN} run ${DERIVED_MODEL} "warm up" 2>&1 || true'
TimeoutSec=1200

[Install]
WantedBy=multi-user.target
WARMUP
fi

systemctl daemon-reload
systemctl enable --now ollama

if [[ $WARMUP -eq 1 ]]; then
  systemctl enable ollama-warmup
  systemctl start ollama-warmup || true
fi

cat <<SUMMARY

[✓] Ollama service installed and started
    - Binary: ${OLLAMA_BIN}
    - Host:   127.0.0.1:${PORT}
    - Threads: ${THREADS}
    - HugePages: ${HUGEPAGES}
    - Systemd unit: /etc/systemd/system/ollama.service

[✓] Model profile created via Modelfile
    - Base model:   ${BASE_MODEL}
    - Derived name: ${DERIVED_MODEL}
    - Modelfile:    ${MODELF}
    - num_ctx:      ${NUM_CTX}

$( [[ $WARMUP -eq 1 ]] && echo "[✓] Warmup service installed (derived model=${DERIVED_MODEL})\n    - Unit: /etc/systemd/system/ollama-warmup.service" )

Run:
  ollama run ${DERIVED_MODEL}

Test local API:
  curl http://127.0.0.1:${PORT}/api/tags || true

SUMMARY
