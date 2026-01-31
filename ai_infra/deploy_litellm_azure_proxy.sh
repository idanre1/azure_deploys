#!/usr/bin/env bash
set -euo pipefail

# ---------------------------
# Defaults (override via flags)
# ---------------------------
SERVICE_NAME="litellm"
SERVICE_USER="litellm"
APP_DIR="/opt/litellm/app"
CONF_DIR="/etc/litellm"
PORT="4000"

# Required (must be passed via flags)
AZURE_API_BASE=""
AZURE_API_KEY=""
AZURE_API_VERSION=""
MODEL_NAME=""
DEPLOYMENT=""   # e.g. azure/Phi-4-mini-instruct

usage() {
  cat <<USAGE
Usage: deploy_litellm_azure_proxy.sh \\
  --azure-api-base URL \\
  --azure-api-key KEY \\
  --azure-api-version VER \\
  --model-name NAME \\
  --deployment MODEL \\
  [--port 4000] [--service-name litellm] [--service-user litellm] \\
  [--app-dir /opt/litellm/app] [--config-dir /etc/litellm]

Examples:
  deploy_litellm_azure_proxy.sh \\
    --azure-api-base https://your-foundry.services.ai.azure.com \\
    --azure-api-key \$AZURE_KEY \\
    --azure-api-version 2024-05-01-preview \\
    --model-name phi-4-mini \\
    --deployment azure/Phi-4-mini-instruct

Flags:
  --azure-api-base       Azure resource base URL (not a /models path)
  --azure-api-key        Azure API key
  --azure-api-version    Azure API version, e.g. 2024-05-01-preview
  --model-name           Public name your clients use (alias exposed via LiteLLM)
  --deployment           Provider model string sent to LiteLLM, e.g. azure/Phi-4-mini-instruct
  --port                 LiteLLM proxy port (default: 4000)
  --service-name         Systemd unit name (default: litellm)
  --service-user         Unix user to run the service (default: litellm)
  --app-dir              Directory for the uv project/.venv (default: /opt/litellm/app)
  --config-dir           Directory for config/env files (default: /etc/litellm)
USAGE
}

# ---------------------------
# Parse CLI args
# ---------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --azure-api-base)     AZURE_API_BASE="$2"; shift 2 ;;
    --azure-api-key)      AZURE_API_KEY="$2"; shift 2 ;;
    --azure-api-version)  AZURE_API_VERSION="$2"; shift 2 ;;
    --model-name)         MODEL_NAME="$2"; shift 2 ;;
    --deployment)         DEPLOYMENT="$2"; shift 2 ;;
    --port)               PORT="$2"; shift 2 ;;
    --service-name)       SERVICE_NAME="$2"; shift 2 ;;
    --service-user)       SERVICE_USER="$2"; shift 2 ;;
    --app-dir)            APP_DIR="$2"; shift 2 ;;
    --config-dir)         CONF_DIR="$2"; shift 2 ;;
    -h|--help)            usage; exit 0 ;;
    *) echo "Unknown flag: $1"; usage; exit 1 ;;
  esac
done

# Validate required args
missing=()
[[ -z "$AZURE_API_BASE" ]]     && missing+=("--azure-api-base")
[[ -z "$AZURE_API_KEY" ]]      && missing+=("--azure-api-key")
[[ -z "$AZURE_API_VERSION" ]]  && missing+=("--azure-api-version")
[[ -z "$MODEL_NAME" ]]         && missing+=("--model-name")
[[ -z "$DEPLOYMENT" ]]         && missing+=("--deployment")

if (( ${#missing[@]} )); then
  echo "Missing required flags: ${missing[*]}"; usage; exit 1
fi

# ---------------------------
# Pre-flight checks
# ---------------------------
SUDO=""
if [[ $EUID -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    echo "This script needs root privileges. Install sudo or run as root."; exit 1
  fi
fi

$SUDO apt-get update -y
$SUDO apt-get install -y curl ca-certificates

# Install uv under SERVICE_USER in appdir/uv
# ---------------------------
# Create a uv-managed app and install litellm[proxy]
# ---------------------------
# Using `uv init` + `uv add` is the documented, stable way to create an isolated .venv and install packages.
UV_DIR="$APP_DIR/uv"
UV_BIN="$UV_DIR/uv"

# ---------------------------
# Users & directories
# ---------------------------
id -u "$SERVICE_USER" &>/dev/null || \
  $SUDO useradd --system --home "$APP_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"

$SUDO mkdir -p "$APP_DIR" "$CONF_DIR" "$UV_DIR"
$SUDO chown -R "$SERVICE_USER":"$SERVICE_USER" "$APP_DIR"
$SUDO chmod 755 "$APP_DIR"
$SUDO chmod 755 "$CONF_DIR"

echo "Checking uv"
if [[ ! -x "$UV_BIN" ]]; then
  echo "Installing Astral uv for ${SERVICE_USER}..."
  # Official installer for macOS/Linux:
  #   curl -LsSf https://astral.sh/uv/install.sh | sh
  $SUDO -u "$SERVICE_USER" UV_INSTALL_DIR="$UV_DIR" bash -lc "
    set -e
    curl -LsSf https://astral.sh/uv/install.sh | sh
  "
fi
echo "Checking uv...done ($UV_BIN)"
"$UV_BIN" --version

echo "UV init"
$SUDO -u "$SERVICE_USER" bash -lc "
  set -e
  if [[ ! -f '$APP_DIR/pyproject.toml' ]]; then
    cd '$UV_DIR'
    '$UV_BIN' init '$APP_DIR' >/dev/null
  fi
  cd '$APP_DIR'
  '$UV_BIN' add 'litellm[proxy]' >/dev/null
"
echo "UV init...done"

# ---------------------------
# Config + env files
# ---------------------------
ENV_FILE="$CONF_DIR/${SERVICE_NAME}.env"
CONFIG_FILE="$CONF_DIR/${SERVICE_NAME}.yaml"

$SUDO tee "$ENV_FILE" >/dev/null <<EOF
AZURE_API_BASE="$AZURE_API_BASE"
AZURE_API_KEY="$AZURE_API_KEY"
AZURE_API_VERSION="$AZURE_API_VERSION"
EOF
$SUDO chmod 600 "$ENV_FILE"
$SUDO chown root:root "$ENV_FILE"

# LiteLLM config:
# - model_list[].model_name is the user-facing alias
# - litellm_params.model is the provider model string. Values can be pulled from env via os.environ/.. prefix.
$SUDO tee "$CONFIG_FILE" >/dev/null <<YAML
model_list:
  - model_name: ${MODEL_NAME}
    litellm_params:
      model: ${DEPLOYMENT}
      api_base: os.environ/AZURE_API_BASE
      api_key: os.environ/AZURE_API_KEY
      api_version: os.environ/AZURE_API_VERSION
YAML
$SUDO chmod 644 "$CONFIG_FILE"
$SUDO chown root:root "$CONFIG_FILE"

# ---------------------------
# systemd unit
# ---------------------------
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
# EnvironmentFile= loads env vars; WantedBy=multi-user.target ensures auto-start at boot.
$SUDO tee "$SERVICE_PATH" >/dev/null <<EOF
[Unit]
Description=LiteLLM Proxy via uv (${SERVICE_NAME})
After=network-online.target
Wants=network-online.target

[Service]
User=${SERVICE_USER}
Group=${SERVICE_USER}
EnvironmentFile=${ENV_FILE}
WorkingDirectory=${APP_DIR}
ExecStart=${APP_DIR}/.venv/bin/litellm --config ${CONFIG_FILE} --port ${PORT}
Restart=on-failure
RestartSec=2
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ProtectHome=true
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

$SUDO systemctl daemon-reload
$SUDO systemctl enable --now "${SERVICE_NAME}.service"

# ---------------------------
# Smoke test
# ---------------------------
echo "Waiting 2s for ${SERVICE_NAME} to start..."
sleep 2
echo "Testing local /v1/chat/completions on port ${PORT} ..."

curl -sS http://127.0.0.1:4000/v1/models \                                                                         ─╯
  -H "Authorization: Bearer test-key"

curl -sS http://127.0.0.1:4000/v1/chat/completions \
  -H "Authorization: Bearer test-key" \
  -H "Content-Type: application/json" \
  -d '{
        "model": "phi-4-mini",
        "messages": [{"role":"user","content":"Smoke test: reply with OK."}],
        "max_tokens": 32,
        "temperature": 0.2
      }' | jq . || true

echo
echo "Done. View logs with:  journalctl -u ${SERVICE_NAME} -f"

