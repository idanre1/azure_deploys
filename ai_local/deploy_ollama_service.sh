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
  --model NAME           Model to warm up (default: llama3.1:8b-instruct-q4_K_M)
  --num-ctx N            Context window tokens (default: 4096)
  --threads N            Threads for OMP/GGML/OLLAMA (default: nproc)
  --port P               Port to bind on localhost (default: 11434)
  --hugepages N          Configure vm.nr_hugepages (persistent). 0 = skip (default: 0)
  --install-ollama       Install Ollama using official install script if missing
  --no-warmup            Do not create/enable warmup service
  --temperature T        Temperature for warmup run (default: 0.7)
  --top-p P              Top-p for warmup run (default: 0.9)
  -h, --help             Show this help

Example:
  sudo ./deploy_ollama_service.sh \
    --model llama3.1:8b-instruct-q4_K_M \
    --num-ctx 4096 \
    --threads 2 \
    --port 11434 \
    --hugepages 1024 \
    --install-ollama
USAGE
}

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

MODEL="llama3.1:8b-instruct-q4_K_M"
NUM_CTX=4096
THREADS="$(nproc)"
PORT=11434
HUGEPAGES=0
INSTALL_OLLAMA=0
WARMUP=1
TEMP=0.7
TOPP=0.9

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) MODEL="$2"; shift 2;;
    --num-ctx) NUM_CTX="$2"; shift 2;;
    --threads) THREADS="$2"; shift 2;;
    --port) PORT="$2"; shift 2;;
    --hugepages) HUGEPAGES="$2"; shift 2;;
    --install-ollama) INSTALL_OLLAMA=1; shift;;
    --no-warmup) WARMUP=0; shift;;
    --temperature) TEMP="$2"; shift 2;;
    --top-p) TOPP="$2"; shift 2;;
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

# Create systemd service for Ollama
cat > /etc/systemd/system/ollama.service <<SERVICE
[Unit]
Description=Ollama LLM Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${OLLAMA_BIN} serve

# CPU performance tuning
Environment=OMP_NUM_THREADS=${THREADS}
Environment=GGML_NUM_THREADS=${THREADS}
Environment=OLLAMA_NUM_THREADS=${THREADS}

# Bind to localhost only
Environment=OLLAMA_HOST=127.0.0.1:${PORT}

# Optional: use huge pages if configured via sysctl
Environment=GGML_USE_HUGEPAGES=1

# Stability & limits
Restart=always
RestartSec=3
LimitNOFILE=1048576
LimitNPROC=1048576

# Security hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
SERVICE

# Create warmup service (optional)
if [[ $WARMUP -eq 1 ]]; then
  cat > /etc/systemd/system/ollama-warmup.service <<WARMUP
[Unit]
Description=Warm up Ollama model
After=ollama.service
Requires=ollama.service

[Service]
Type=oneshot
# Give the server a moment to bind
ExecStartPre=/bin/sleep 3
# Run a short prompt to load weights and JIT kernels, discard output
ExecStart=/bin/bash -lc '\
  ${OLLAMA_BIN} run ${MODEL} --num_ctx ${NUM_CTX} --temperature ${TEMP} --top_p ${TOPP} -p "warm up" >/dev/null 2>&1 || true'
TimeoutSec=600

[Install]
WantedBy=multi-user.target
WARMUP
fi

# Apply systemd changes and start services
systemctl daemon-reload
systemctl enable --now ollama

if [[ $WARMUP -eq 1 ]]; then
  systemctl enable ollama-warmup
  # Start warmup now (it will also run on next boot)
  systemctl start ollama-warmup || true
fi

# Summary
cat <<SUMMARY

[✓] Ollama service installed and started
    - Binary: ${OLLAMA_BIN}
    - Host:   127.0.0.1:${PORT}
    - Threads: ${THREADS}
    - HugePages: ${HUGEPAGES}
    - Systemd unit: /etc/systemd/system/ollama.service

$( [[ $WARMUP -eq 1 ]] && echo "[✓] Warmup service installed (model=${MODEL}, num_ctx=${NUM_CTX})
    - Unit: /etc/systemd/system/ollama-warmup.service" )

Manage services:
  sudo systemctl status ollama
  sudo systemctl restart ollama
  sudo systemctl status ollama-warmup

Test locally:
  curl http://127.0.0.1:${PORT}/api/tags || true

Security note:
  Ollama is bound to localhost only. Use an SSH tunnel or reverse proxy if you need remote access.

SUMMARY
