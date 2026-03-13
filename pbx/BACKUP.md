# Backup Guide — LAN PBX (Asterisk PJSIP) on Docker Compose

This guide explains how to back up and restore your **LAN-only Asterisk PBX** deployment created by `deploy_lan_pbx.sh`.

It assumes your deployment layout is:

- `<INSTALL_PATH>/docker-compose.yml`
- `<INSTALL_PATH>/log/` (Asterisk logs)
- `<INSTALL_PATH>/bin/` helper scripts
- `<CONFIG_PATH>/` Asterisk configuration (mounted into the container as `/etc/asterisk`)

> If you used defaults, `INSTALL_PATH=/opt/lan-pbx` and `CONFIG_PATH=/opt/lan-pbx/config`.

---

## What to back up

At minimum, back up:

1. **Configuration**: `<CONFIG_PATH>/`  
   This includes `pjsip.conf`, `extensions.conf`, `rtp.conf`, and all per-user files under `pjsip.d/`.
2. **Compose file**: `<INSTALL_PATH>/docker-compose.yml`
3. (Optional) **Logs**: `<INSTALL_PATH>/log/`

You do **not** need to back up the container image itself — it can be pulled again during restore.

---

## Recommended: consistent backup procedure

For small LAN deployments, a “stop → archive → start” backup is simple and consistent.

### 1) Stop the PBX (brief downtime)

```bash
cd <INSTALL_PATH>
docker compose down
```

### 2) Create a timestamped archive

```bash
TS=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR=~/pbx-backups
mkdir -p "$BACKUP_DIR"

# Archive config + compose file (+ logs optional)
tar -czf "$BACKUP_DIR/lan-pbx-$TS.tgz" \
  -C "<INSTALL_PATH>" docker-compose.yml \
  -C "<CONFIG_PATH>" . \
  -C "<INSTALL_PATH>" log

echo "Created: $BACKUP_DIR/lan-pbx-$TS.tgz"
```

> If logs are large and you don’t want them in backups, remove the last line `-C "<INSTALL_PATH>" log`.

### 3) Start the PBX again

```bash
cd <INSTALL_PATH>
docker compose up -d
```

---

## Zero-downtime(ish) backup (best-effort)

If you want to avoid downtime, you can archive config while running (config changes are rare). This is usually fine for a LAN PBX, but it is not as “consistent” as stopping.

```bash
TS=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR=~/pbx-backups
mkdir -p "$BACKUP_DIR"

tar -czf "$BACKUP_DIR/lan-pbx-$TS.tgz" \
  -C "<INSTALL_PATH>" docker-compose.yml \
  -C "<CONFIG_PATH>" .

echo "Created: $BACKUP_DIR/lan-pbx-$TS.tgz"
```

---

## Restore procedure (new server or same server)

### 1) Prepare folders

Create your target install/config directories (match your previous paths if possible):

```bash
sudo mkdir -p <INSTALL_PATH>
sudo mkdir -p <CONFIG_PATH>
```

### 2) Extract the backup

```bash
cd <INSTALL_PATH>
# Replace with your actual backup file
sudo tar -xzf ~/pbx-backups/lan-pbx-YYYYmmdd-HHMMSS.tgz \
  -C <INSTALL_PATH> --no-same-owner

# If your archive included config contents as '.' you may need to move them:
# The backup command above stored <CONFIG_PATH> content without the top folder.
# So extract config content explicitly if needed:
# sudo tar -xzf <backup>.tgz -C <CONFIG_PATH> --no-same-owner
```

**Common restore pattern (recommended):** keep two archives (one for install file, one for config) to avoid ambiguity:

```bash
# Example split backups (if you choose to do that):
# tar -czf install.tgz -C <INSTALL_PATH> docker-compose.yml
# tar -czf config.tgz   -C <CONFIG_PATH> .

# Restore:
# sudo tar -xzf install.tgz -C <INSTALL_PATH> --no-same-owner
# sudo tar -xzf config.tgz  -C <CONFIG_PATH> --no-same-owner
```

### 3) Start the stack

```bash
cd <INSTALL_PATH>
docker compose up -d
```

### 4) Validate

```bash
# Check container
docker ps --filter name=lan-pbx-asterisk

# Show registered devices (after clients re-register)
docker exec -it lan-pbx-asterisk asterisk -rx "pjsip show contacts"
```

---

## Backup hygiene & tips

- Keep backups **off the server** (NAS, external disk, or another host).
- Use strong file permissions:

```bash
chmod 600 ~/pbx-backups/*.tgz
```

- Consider rotating backups (keep last N):

```bash
ls -1t ~/pbx-backups/lan-pbx-*.tgz | tail -n +11 | xargs -r rm -f
```

---
