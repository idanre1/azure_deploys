# Upgrade Guide — LAN PBX (Asterisk PJSIP) on Docker Compose

This guide covers safe ways to upgrade your **Asterisk PBX container image** and apply configuration changes.

Your deployment uses Docker Compose with an Asterisk image (example: `andrius/asterisk:stable`).

---

## Upgrade strategy (recommended)

1. **Back up first** (see `BACKUP.md`).
2. **Pull the new image**.
3. **Restart the service with the new image**.
4. **Validate** (registrations + test call).

For LAN-only PBX setups (no trunks), upgrades are usually straightforward.

---

## 1) Check your current image version

From the host:

```bash
docker ps --filter name=lan-pbx-asterisk --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
```

Inside Asterisk CLI, you can also check the Asterisk version:

```bash
docker exec -it lan-pbx-asterisk asterisk -rx "core show version"
```

---

## 2) Standard upgrade (pull + recreate)

### Option A: minimal downtime upgrade (recommended)

```bash
cd <INSTALL_PATH>

# 1) Pull the latest tag referenced in docker-compose.yml
docker compose pull

# 2) Recreate container with the new image
#    --no-deps because you typically only run one service here
#    --force-recreate ensures it swaps the container even if config is unchanged
docker compose up -d --no-deps --force-recreate
```

### Option B: “clean” upgrade (down + up)

This introduces a slightly longer downtime but is very clean:

```bash
cd <INSTALL_PATH>
docker compose down
docker compose pull
docker compose up -d
```

---

## 3) Pinning versions (recommended for stability)

Instead of tracking a moving tag like `stable`, pin a specific version tag in `docker-compose.yml`.

Example (edit `<INSTALL_PATH>/docker-compose.yml`):

```yaml
services:
  asterisk:
    image: andrius/asterisk:22.5.2_debian-trixie
```

Then:

```bash
cd <INSTALL_PATH>
docker compose pull
docker compose up -d --no-deps --force-recreate
```

**Why pin?**
- Reproducibility and easier rollback.

---

## 4) Rollback

If something breaks after an upgrade:

1) Revert the image tag in `docker-compose.yml` to the previous known-good tag.
2) Recreate the container:

```bash
cd <INSTALL_PATH>
docker compose pull
docker compose up -d --no-deps --force-recreate
```

If config was changed and you need to revert it too, restore from backup.

---

## 5) Upgrading configuration (no image change)

For many changes you only need a reload, not a container restart.

### Reload PJSIP + dialplan

```bash
docker exec -it lan-pbx-asterisk asterisk -rx "pjsip reload"
docker exec -it lan-pbx-asterisk asterisk -rx "dialplan reload"
```

### When a restart is recommended

- You changed network bindings or docker published ports.
- You changed transports significantly (e.g., switching ports).
- You changed container-level environment/volume mappings.

In those cases:

```bash
cd <INSTALL_PATH>
docker compose up -d --no-deps --force-recreate
```

---

## 6) Post-upgrade validation checklist

1. **Container healthy / running**

```bash
docker ps --filter name=lan-pbx-asterisk
```

2. **Asterisk version prints**

```bash
docker exec -it lan-pbx-asterisk asterisk -rx "core show version"
```

3. **PJSIP endpoints exist**

```bash
docker exec -it lan-pbx-asterisk asterisk -rx "pjsip show endpoints"
```

4. **Clients re-register**

```bash
docker exec -it lan-pbx-asterisk asterisk -rx "pjsip show contacts"
```

5. **Test a call** (e.g., `1001` → `1002`) and confirm audio.

---

## 7) Notes for automation

If you want to automate safe upgrades:
- Run a backup job.
- Pull + recreate container.
- Run a short health check (Asterisk version, PJSIP endpoints, test registration).

---
