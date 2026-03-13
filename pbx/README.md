# LAN-Only SIP PBX (Asterisk PJSIP) — Docker Compose

This project deploys a **LAN-only SIP PBX** using **Asterisk (PJSIP)** inside **Docker Compose**, suitable for running SIP clients on a single subnet with extension-to-extension calling.

It is designed for:
- **No Internet exposure**: ports are bound to a specific LAN interface IP (e.g., `192.168.1.10`).
- **Simple extension dialing**: wildcard dialplan pattern (e.g., `_1XXX` matches `1000–1999`).
- **Easy user management**: one config file per user under `pjsip.d/`, with reload (no restart).

---

## 1) Setup

### Prerequisites

- Ubuntu host
- `docker` and `docker compose` installed and working

> The Asterisk container image used by the deployment is `andrius/asterisk` (pulled from Docker Hub). citeturn1search13

---

### Quick start

1. Copy the deployment script onto your server (example name):

```bash
chmod +x deploy_lan_pbx.sh
```

2. Run the deployment (example: bind to LAN IP and use `_1XXX` extensions):

```bash
sudo ./deploy_lan_pbx.sh \
  --bind-ip 192.168.1.10 \
  --pattern 1XXX \
  --transport udp \
  --concurrent-calls 20
```

3. Add a couple of users:

```bash
/opt/lan-pbx/bin/add-user.sh 1001 'StrongPassword1!'
/opt/lan-pbx/bin/add-user.sh 1002 'StrongPassword2!'
```

4. Configure your SIP clients (Zoiper/Linphone/desk phones):

- **Server/Registrar**: `192.168.1.10`
- **Port**: `5060`
- **Username/Auth ID**: `1001` (or `1002`)
- **Password**: the password you set

5. Call between extensions (e.g., dial `1002` from `1001`).

---

### Configuration parameters (script options)

The deployment script supports these parameters:

- `--concurrent-calls N` : used to infer a safe **RTP UDP port range** to publish.
- `--transport udp|tcp|both` : whether to publish SIP over UDP, TCP, or both.
- `--pattern PATTERN` : dialplan wildcard pattern **without** `_` (the script adds it).
- `--install-path PATH` : where the compose file, logs, and helper scripts are placed.
- `--config-path PATH` : where Asterisk config files live (defaults to `<install-path>/config`).
- `--bind-ip IP` : host interface IP to bind SIP/RTP ports to (LAN-only behavior).

---

### RTP ports sizing (how it works)

Asterisk uses:
- **SIP signaling** (commonly port `5060`)
- **RTP media** via a UDP port range (commonly a block like `10000–20000` depending on deployment) citeturn1search10turn1search13

The script computes an RTP range from `N` (concurrent calls) with headroom so you don’t have to guess.

---

## 2) User management & admin commands

### Directory structure

After deployment, you’ll have:

- `<INSTALL_PATH>/docker-compose.yml`
- `<INSTALL_PATH>/log/` (Asterisk logs)
- `<INSTALL_PATH>/bin/` helper scripts
- `<CONFIG_PATH>/` Asterisk configs:

```text
<CONFIG_PATH>/
  pjsip.conf
  pjsip.d/
    1001.conf
    1002.conf
  extensions.conf
  rtp.conf
```

The `pjsip.conf` includes all users via `#include pjsip.d/*.conf`. Asterisk supports `#include` (and `#tryinclude`) to split large configs into manageable files and even include entire directories via wildcard. citeturn2search26

---

### How wildcard dialing works

Asterisk dialplan pattern matching:
- Patterns **start with `_`**
- `X` matches any digit `0–9`, `Z` matches `1–9`, `N` matches `2–9` citeturn4search50

So `_1XXX` matches `1000–1999`. citeturn4search50turn4search57

The deployed dialplan uses a single rule:

```ini
[from-internal]
exten => _1XXX,1,Dial(PJSIP/${EXTEN},30)
 same => n,Hangup()
```

This avoids needing a dialplan line per extension, while still keeping user definitions per-file in `pjsip.d/`.

---

### Add a user

Use the helper:

```bash
<INSTALL_PATH>/bin/add-user.sh 1003 'StrongPassword3!'
```

What it does:
- Creates `<CONFIG_PATH>/pjsip.d/1003.conf`
- Reloads PJSIP and the dialplan (no container restart)

**Why reload works:** Asterisk can reload dialplan changes via `dialplan reload` without disrupting service. citeturn4search55

---

### Remove a user

```bash
<INSTALL_PATH>/bin/del-user.sh 1003
```

This deletes `<CONFIG_PATH>/pjsip.d/1003.conf` and reloads.

---

### Common admin commands

#### Enter the Asterisk CLI

```bash
docker exec -it lan-pbx-asterisk asterisk -rvvv
```

#### Show configured PJSIP objects

PJSIP configuration is composed of objects like **endpoint**, **auth**, and **aor**. citeturn2search28

Run:

```bash
docker exec -it lan-pbx-asterisk asterisk -rx "pjsip show endpoints"
docker exec -it lan-pbx-asterisk asterisk -rx "pjsip show aors"
docker exec -it lan-pbx-asterisk asterisk -rx "pjsip show auths"
```

#### Show currently registered devices

```bash
docker exec -it lan-pbx-asterisk asterisk -rx "pjsip show contacts"
```

#### Reload config after manual edits

```bash
docker exec -it lan-pbx-asterisk asterisk -rx "pjsip reload"
docker exec -it lan-pbx-asterisk asterisk -rx "dialplan reload"
```

#### View container logs

```bash
docker logs -f lan-pbx-asterisk
```

---

### Troubleshooting quick checks

1. **No registration?**
   - Confirm client uses the right server IP/port and correct username/password.
   - Check registrations with `pjsip show contacts`.
2. **No audio / one-way audio?**
   - Verify RTP range in `rtp.conf` matches the Docker published UDP range.
3. **Pattern doesn’t match?**
   - Ensure your `--pattern` uses Asterisk pattern characters (`X`, `N`, `Z`, ranges in `[]`) and the dialplan rule begins with `_`. citeturn4search50

---

## Appendix: Customizing config layout

If you grow beyond a few users, keep configs clean by continuing to add per-user files under `pjsip.d/` and optionally splitting additional dialplan logic into more included files. Asterisk’s `#include`/`#tryinclude` constructs exist specifically to break large configs into smaller pieces. citeturn2search26
