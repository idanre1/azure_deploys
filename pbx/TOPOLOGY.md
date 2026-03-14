# Complicated Network Topology Guide — LAN SIP PBX (Asterisk PJSIP) + Routers + VLANs

This guide adapts the earlier **simple single-subnet LAN PBX** methodology to a **more complicated topology**:

- A **main switch** with a **gateway** (L3 device / firewall / router). citeturn10search8turn10search12
- The **PBX server** is connected via its **own router** (often meaning the PBX is **behind NAT** unless that router is configured as pure routing/bridge). citeturn10search14
- **Client groups** connect to the main switch via **their own routers** (often meaning SIP clients are **behind NAT**). citeturn10search14
- Optionally, the PBX and/or clients are on **different VLANs** (requiring **inter‑VLAN routing** and typically ACL/firewall rules). citeturn10search8turn10search12

The focus remains the same: **internal registration + extension-to-extension calls** (no trunks, no GUI). citeturn10search14

---

## 1) Concepts (what changes when you add routers/VLANs)

### 1.1 VLANs: “separate L2 broadcast domains”

A VLAN splits a physical switch into multiple **separate broadcast domains**; traffic between VLANs requires **Layer‑3 routing** (router-on-a-stick, SVIs on an L3 switch, etc.). citeturn10search8turn10search12

**Implication for SIP:** phones in VLAN A and PBX in VLAN B will not communicate unless inter‑VLAN routing is enabled and permitted. citeturn10search8turn10search12

### 1.2 NAT: “addresses get rewritten; SIP/RTP get tricky”

If a router performs NAT between two segments, devices behind it present **translated addresses/ports** to the outside. Asterisk’s NAT guidance assumes the NAT device must forward SIP and RTP and that Asterisk must be told what is “local” vs “external.” citeturn10search14turn10search16

### 1.3 Private IPs and “outside world exposure”

If your PBX has an RFC1918 private IPv4 address (10/8, 172.16/12, 192.168/16), it is **not routable on the public Internet by default**. citeturn10search31turn10search29

Your PBX becomes reachable from “outside world” **only if** you explicitly publish it (e.g., WAN port-forwarding / public IP / VPN ingress). citeturn10search31turn10search29

---

## 2) Decide which of these 3 deployment modes you are in

You must first classify your topology, because configuration differs.

### Mode A — **Pure routing between segments (no NAT)** (best)

- VLANs/subnets are routed by the gateway/L3 switch.
- No NAT between phones and PBX.

This is the simplest for SIP: you mainly need routing + ACLs. citeturn10search8turn10search12

### Mode B — **PBX behind NAT** (you chose “port forward”) 

- PBX host lives in a private subnet behind its router.
- PBX router has a WAN interface on the main switch network.

You must **port-forward** SIP + RTP to the PBX and set `external_*`/`local_net` in PJSIP transport. citeturn10search14turn10search16

### Mode C — **Phones behind NAT (client routers)**

- Phones register outbound to PBX.
- NAT keepalives and contact rewriting matter.

Asterisk PJSIP endpoint NAT options (e.g., `rewrite_contact`, `force_rport`, `rtp_symmetric`, and `direct_media`) are commonly used to make this work. citeturn10search14turn10search16

> In real networks you may have **B + C simultaneously** (PBX behind NAT and phones behind NAT). citeturn10search14turn10search16

---

## 3) Network requirements checklist (what must be true)

### 3.1 Routing / reachability

- **PBX must be reachable** from each phone subnet/VLAN via routing or port-forwarding. citeturn10search8turn10search14
- If using VLANs, **inter‑VLAN routing must be enabled** (router-on-a-stick or L3 switch SVIs). citeturn10search12turn10search8

### 3.2 Allowed ports (inside LAN and/or via port-forward)

Asterisk needs:

- **SIP signaling**: typically `5060/UDP` (and optionally `5060/TCP` if you enable it). citeturn10search14turn1search13
- **RTP media**: a UDP port range (common examples use `10000–20000`; you can run smaller ranges sized to your call volume). citeturn10search14turn1search10

If the PBX is behind NAT, the NAT device must forward those ports to the PBX. citeturn10search14

### 3.3 “Not exposed to the Internet” rule

Keeping the PBX internal means:

- PBX stays on RFC1918 space and you do **not** create WAN port-forward rules from the Internet edge to SIP/RTP. citeturn10search31turn10search29

---

## 4) PBX behind NAT (Mode B): what to configure

### 4.1 Port forwarding on the PBX router

Forward **from PBX-router WAN (main switch side) → PBX host IP (behind PBX router):**

- `5060/UDP` (and `5060/TCP` if using TCP) citeturn10search14turn1search13
- `RTP_START–RTP_END/UDP` (your chosen range) citeturn10search14turn1search10

Asterisk’s NAT documentation explicitly uses the pattern “forward TCP/UDP 5060 and UDP 10000–20000” to the internal PBX. citeturn10search14

### 4.2 PJSIP transport NAT parameters

In `pjsip.conf`, set these under your transport:

- `local_net` — the PBX-side internal network behind the PBX router. citeturn10search14
- `external_signaling_address` — the PBX router’s WAN IP visible to phones (main-switch side). citeturn10search14
- `external_media_address` — same WAN IP for RTP rewriting. citeturn10search14

Example (replace with your IPs):

```ini
[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:5060

local_net=192.168.50.0/24
external_signaling_address=192.168.1.50
external_media_address=192.168.1.50
```

These are the specific transport settings Asterisk calls out as key for NAT rewriting behavior. citeturn10search14

### 4.3 Keep `direct_media=no` for NAT

When NAT is involved, anchoring media at the PBX simplifies RTP traversal; Asterisk’s NAT examples call out `direct_media` as an important endpoint setting. citeturn10search14

---

## 5) Phones behind NAT (Mode C): what to configure

In your endpoint template (e.g. `[endpoint-common](!)`), keep NAT-friendly settings:

```ini
direct_media=no
rewrite_contact=yes
rtp_symmetric=yes
force_rport=yes
```

Asterisk’s NAT guidance for PJSIP highlights transport `external_*`/`local_net` and endpoint `direct_media` as key, and community configurations commonly add the contact/rtp symmetry options for NAT robustness. citeturn10search14turn10search16

---

## 6) VLAN scenario: what to change

If your PBX and phones are on different VLANs, you need **inter‑VLAN routing** and rules allowing the SIP/RTP ports.

### 6.1 Ensure inter‑VLAN routing is enabled

- Layer‑3 switch SVI method or router-on-a-stick: VLANs are isolated unless routing is configured. citeturn10search8turn10search12

### 6.2 Add ACL / firewall rules at the gateway (recommended)

Even if you don’t run UFW on the PBX host, you typically control cross‑VLAN access at the gateway/L3 device:

Allow **Phone VLAN(s) → PBX VLAN**:
- `UDP 5060` (and optional `TCP 5060`) citeturn10search14turn1search13
- `UDP RTP_START–RTP_END` citeturn10search14turn1search10

Deny **everything else** by default and open only what you need (principle of least privilege). citeturn10search8turn10search12

---

## 7) Docker Compose binding strategy in complex networks

### 7.1 Bind ports to the interface/IP that phones can reach

- If PBX is **directly on the routed network/VLAN**: bind to that VLAN IP. citeturn10search8turn1search13
- If PBX is **behind NAT**: Docker binds on the PBX host’s internal IP, while the router forwards from its WAN IP to that internal IP. citeturn10search14turn1search13

### 7.2 Avoid binding on unwanted interfaces

If the host has multiple NICs/VLAN subinterfaces, binding published ports to a specific IP reduces accidental exposure on other interfaces. citeturn10search31turn10search29

---

## 8) Dialplan and configuration hygiene (still recommended)

### 8.1 Wildcard extension pattern

Asterisk pattern matching uses:
- an underscore prefix `_` and tokens like `X` (0–9), `Z` (1–9), `N` (2–9). citeturn10search1turn10search5

So `_1XXX` matches `1000–1999`. citeturn10search1turn10search5

### 8.2 Split configs with `#include` (one file per extension)

Asterisk supports `#include` / `#tryinclude` and can include a whole directory using wildcards, which is specifically intended to keep large configs manageable. citeturn10search21

Recommended layout:

```text
<CONFIG_PATH>/
  pjsip.conf
  pjsip.d/
    1001.conf
    1002.conf
  extensions.conf
  rtp.conf
```

`pjsip.conf` includes users:

```ini
#include pjsip.d/*.conf
```

This is supported by Asterisk config include semantics. citeturn10search21

---

## 9) Troubleshooting in complex networks (fast checklist)

### 9.1 Signaling works but no audio

Most common causes:
- RTP range not forwarded (PBX behind NAT) citeturn10search14
- Inter‑VLAN ACL missing RTP range citeturn10search8turn10search12
- RTP range mismatch between Docker published ports and `rtp.conf` citeturn1search10turn10search14

### 9.2 Phones don’t register

- Can the phone reach PBX SIP port across VLANs/routes? (inter‑VLAN routing required) citeturn10search8turn10search12
- If PBX behind NAT: is SIP 5060 forwarded? citeturn10search14
- Check contacts:

```bash
docker exec -it lan-pbx-asterisk asterisk -rx "pjsip show contacts"
```

PJSIP config uses endpoints/aors/auth objects; if none exist, registrations will fail. citeturn2search28

### 9.3 NAT settings wrong (PBX advertises wrong IP)

- Ensure `external_signaling_address` / `external_media_address` match the PBX router’s WAN IP as seen by phones. citeturn10search14

---

## 10) If you later introduce a SIP proxy (optional note)

If you put a SIP proxy (e.g., Kamailio) in front and it is relaying for you, Asterisk documentation notes that NAT-related transport parameters like `external_*`/`local_net` may not be appropriate (Asterisk should not know what’s beyond the proxy). citeturn10search18

---

## 11) Quick “what to change” summary

If you moved from “single subnet” to this complicated topology, change your methodology as follows:

1. **Add routing/ACL thinking**: VLANs are isolated unless inter‑VLAN routing is configured. citeturn10search8turn10search12
2. **If PBX behind NAT**: port-forward SIP + RTP and set `local_net` + `external_*` in the PJSIP transport. citeturn10search14turn10search16
3. **If phones behind NAT**: keep endpoint NAT-friendly options and keep `direct_media=no`. citeturn10search14turn10search16
4. **Keep configs modular**: use `#include` with `pjsip.d/*.conf` and a wildcard dialplan like `_1XXX`. citeturn10search21turn10search1

---

## Appendix A — Reference links

- Asterisk NAT guide: [Configuring res_pjsip to work through NAT](https://docs.asterisk.org/Configuration/Channel-Drivers/SIP/Configuring-res_pjsip/Configuring-res_pjsip-to-work-through-NAT/) citeturn10search14
- Asterisk config includes: [Using the include, tryinclude and exec constructs](https://docs.asterisk.org/Fundamentals/Asterisk-Configuration/Asterisk-Configuration-Files/Using-The-include-tryinclude-and-exec-Constructs/) citeturn10search21
- Asterisk dialplan patterns: [Pattern Matching](https://docs.asterisk.org/Configuration/Dialplan/Pattern-Matching/) citeturn10search1
- RFC1918 (private address space): [RFC 1918 on IETF Datatracker](https://datatracker.ietf.org/doc/rfc1918/) citeturn10search31
- Inter‑VLAN routing basics: [Inter VLAN Routing by Layer 3 Switch](https://www.geeksforgeeks.org/computer-networks/inter-vlan-routing-layer-3-switch/) citeturn10search8 and [InterVLAN Routing (NetworkLessons)](https://networklessons.com/switching/intervlan-routing) citeturn10search12
