# Free TwiSMS — Infrastructure & Configuration

Complete documentation of the server-side stack behind the Free TwiSMS iOS app:
the PBX server, the SMS connector, Twilio, push notifications, and nginx.

> **Secrets policy:** No passwords, tokens, PINs, or private keys are committed to
> this repo. They live in `/opt/sms-connector/.env` (chmod 600) on the server and in
> the FreePBX database. This doc lists *which* secrets exist and where, not their values.

---

## 1. Architecture overview

```
 iPhone (Free TwiSMS app)                 Yealink T54W desk phone
        |  HTTPS (JSON API + APNs)               |  SIP/RTP over OpenVPN
        v                                         v
 ┌─────────────────────────── bulwarkblack-pbx (64.225.116.144) ──────────────────────┐
 │  nginx (443, Let's Encrypt: pbx.bulwarkblack.com)                                    │
 │    /sms,/api/,/sms-hook,/m/  → SMS connector (127.0.0.1:8090)                        │
 │    /legal/                   → static compliance pages (/opt/legal-pages)            │
 │    /                         → FreePBX admin (127.0.0.1:8443)                        │
 │                                                                                      │
 │  Docker: freepbx (tiredofit/freepbx)  +  sms-connector (python)                      │
 │  OpenVPN server (UDP 1194)  ·  Asterisk AMI (172.18.0.2:5038)                        │
 └──────────────────────────────────────────────────────────────────────────────────┘
        |  SIP trunk (UDP 5060, Twilio IPs only)        |  Twilio REST API
        v                                                v
 Twilio Elastic SIP Trunk  ───────────────────────  Twilio (SMS/MMS, numbers, A2P)
```

- **Numbers:** +1 509-309-8286 ("Bulwark Black LLC") and +1 360-302-4667 ("Rural Tech and Support", ruraltechandsupport.com)
- **Extensions:** 101 (Bulwark Black, Line 1) and 102 (Rural Tech, Line 2), both on the Yealink T54W

---

## 2. Host server

| | |
|---|---|
| Hostname | `bulwarkblack-pbx` |
| Public IP | `64.225.116.144` |
| OS | Ubuntu 24.04 LTS (DigitalOcean) |
| SSH | `ssh root@64.225.116.144` (key `~/.ssh/id_ed25519`, passphrase-protected) |
| Web | `https://pbx.bulwarkblack.com` (nginx + Let's Encrypt) |
| Docker networks | `docker-freepbx_default` (172.18.0.0/16); freepbx = 172.18.0.2 |

---

## 3. FreePBX / Asterisk (Docker)

- **Container:** `freepbx`, image `tiredofit/freepbx:latest`. FreePBX 15.0.38 / Asterisk 17.9.3 (both EOL — upgrade is a known TODO).
- **Admin GUI:** `https://pbx.bulwarkblack.com/admin` (proxied to container `:8443`; also direct on host `:8080`/`:8443`).
- **Trunk:** Twilio Elastic SIP Trunk "PBX-Trunk" (`TK753cb67e5831575a838d0d21fbb3c27d`), domain `bulwarkpbx.pstn.twilio.com`. Trunk outbound CID is a fallback; per-extension Outbound CID overrides it.
- **Inbound routes** (FreePBX `incoming` table): `+15093098286` → ext 101; `+13603024667` → ext 102.
- **Extensions** (pjsip): 101 "Bulwark Black LLC" (Outbound CID +15093098286), 102 "Rural Tech and Support" (Outbound CID +13603024667). SIP secrets stored in the FreePBX DB / on the phone.
- **Voicemail:** boxes for 101 and 102 (context `default`, attach=yes, email set). PINs stored in voicemail.conf. **Voicemail-to-email is NOT yet active** — the container MTA (msmtp) has no relay configured.

### FreePBX operational gotchas
- Run `fwconsole reload` **as the asterisk user**, not root:
  `docker exec freepbx su -s /bin/bash asterisk -c 'fwconsole reload'`.
  Running as root leaves root-owned files in `/tmp` (e.g. `/tmp/cron.error`) that break later reloads with `proc_open(...): Permission denied` — fix with `rm -f /tmp/cron.error /tmp/cron.out` in the container.
- To add an extension headlessly, use the BMO API, not raw SQL (raw SQL does not populate the Asterisk `astdb` AMPUSER/DEVICE trees):
  `FreePBX::Core()->processQuickCreate("pjsip", $ext, [...])`.
- To create/edit a voicemail box headlessly: `FreePBX::Voicemail()->addMailbox($ext, [...], false)` — the password key is **`vmpwd`** (passing `pwd` silently writes a blank password).
- Inbound DIDs arrive in E.164 with leading `+` (dialplan context `ext-did` matches `+1360...`).

---

## 4. SIP trunk firewall (toll-fraud protection)

iptables `DOCKER-USER` chain restricts SIP/RTP so the PBX is **not** open to the internet:
- SIP UDP 5060 allowed **only** from Twilio signaling subnets `54.172.60.0/30` and `54.244.51.0/30`, and from the VPN (`tun0`).
- Public 5060/5160 and RTP (18000–20000) from `eth0` are dropped.
- The FreePBX container also runs its own fail2ban for SIP.

---

## 5. OpenVPN + the Yealink phone

- **OpenVPN server:** `openvpn-server@server`, UDP 1194, subnet 10.8.0.0/24 (server 10.8.0.1). Config `/etc/openvpn/server/server.conf` (certs under `/usr/share/easy-rsa/pki/`). Pushes route `172.18.0.0/16` so the phone reaches the FreePBX container.
- **Phone:** Yealink **T54W** (firmware 96.86.x), OpenVPN client CN `yealink-t45w`, VPN IP ~10.8.0.6, LAN 192.168.100.101. Registers ext 101 (Line 1) and ext 102 (Line 2) to the FreePBX container at **172.18.0.2:5060** over the VPN.
- The phone's web UI uses an RSA-encrypted SPA login — it cannot be driven by curl; configure Line 2 etc. via the phone's web page directly.

---

## 6. SMS connector (`/opt/sms-connector`)

A small Python service (stdlib + `httpx[http2]`, `pyjwt`, `cryptography`) that bridges
Twilio SMS/MMS to the iOS app, the web inbox, the desk phone, and push.

### Files
| File | Purpose |
|---|---|
| `app.py` | the whole service (HTTP server, ~700 lines) |
| `Dockerfile` | `python:3.12-slim` + `pip install httpx[http2] pyjwt cryptography` |
| `.env` | all config + secrets (chmod 600, **not** in git) |
| `data/sms.db` | SQLite: `messages`, `devices`, `meta` tables |
| `data/media/` | inbound + sent media (served authenticated at `/sms/media/`) |
| `data/outmedia/` | outbound media for Twilio + file links (served public at `/m/`) |
| `data/apns_key.p8` | APNs auth private key (chmod 600, **not** in git) |

> Note: `docker-compose.yml` exists but the host's `docker-compose` v1 is **broken**
> with Docker 29 (`KeyError: 'ContainerConfig'`). Use plain `docker run` (below).

### Environment variables (`.env`)
| Key | Meaning | Secret? |
|---|---|---|
| `PUBLIC_BASE` | `https://pbx.bulwarkblack.com` | no |
| `INBOX_USER` / `INBOX_PASS` | web inbox + app login (HTTP Basic) | **yes** |
| `TWILIO_ACCOUNT_SID` | `AC… (account SID — see server .env)` | no |
| `TWILIO_AUTH_TOKEN` | Twilio API auth token | **yes** |
| `AMI_HOST/PORT/USER/PASS` | Asterisk AMI for desk-phone SIP MESSAGE push (172.18.0.2:5038, user `smsconn`) | pass **yes** |
| `YEALINK_EXT` | `101` | no |
| `DB_PATH` / `LISTEN_PORT` | `/data/sms.db` / `8090` | no |
| `NTFY_URL` / `NTFY_TOPIC` | ntfy push (legacy/backup; `https://ntfy.sh` + secret topic) | topic semi |
| `APNS_TEAM_ID` | `7VS3GN26RD` | no |
| `APNS_KEY_ID` | `AX52YNBG35` | no |
| `APNS_BUNDLE_ID` | `com.bulwarkblackllc.freetwisms` | no |
| `APNS_HOST` | `api.push.apple.com` (production) — use `api.sandbox.push.apple.com` for development builds | no |
| `APNS_KEY_P8` | path to the `.p8` key file (`/data/apns_key.p8`) | key file **yes** |

### JSON API (HTTP Basic auth, used by the iOS app)
| Method/Path | Purpose |
|---|---|
| `GET /api/numbers` | the account's numbers + labels |
| `GET /api/conversations[?box=<num>]` | threads, newest first |
| `GET /api/thread?via=<our>&with=<contact>` | messages in a thread (`+` must be %2B-encoded) |
| `POST /api/send` | send SMS (JSON `{from,to,body}`) |
| `POST /api/send-mms` | send MMS image (JSON adds `image`=base64, `content_type`) |
| `POST /api/send-file` | upload a file → send a download link (JSON adds `file`=base64, `filename`) |
| `POST /api/register-device` | register an APNs device token (`{token}`) |
| `POST /api/mark-read` | mark all read (resets unread badge) |
| `GET /sms/media/<name>` | inbound/sent media (auth) |
| `GET /m/<name>` | **public** outbound media/file links (so Twilio + recipients can fetch) |

Other paths: `POST /sms-hook` (Twilio inbound webhook, validated by X-Twilio-Signature),
`GET /sms` (web inbox HTML), `GET /healthz`.

### Inbound flow
Twilio → `POST /sms-hook` → store in SQLite → (a) desk-phone SIP MESSAGE via AMI,
(b) ntfy push, (c) APNs push with unread badge. Unread = inbound messages with
`ts > meta.read_ts`; `/api/mark-read` advances `read_ts`.

### Rebuild / restart the connector
```bash
cd /opt/sms-connector
docker build -t sms-connector_sms:latest .
docker rm -f sms-connector
docker run -d --name sms-connector --restart unless-stopped \
  --env-file /opt/sms-connector/.env \
  -p 127.0.0.1:8090:8090 \
  -v /opt/sms-connector/data:/data \
  --network docker-freepbx_default \
  sms-connector_sms:latest
```

---

## 7. nginx (`/etc/nginx/sites-available/freepbx`)

The 443 server block (server_name `pbx.bulwarkblack.com`, Let's Encrypt) adds, in order:
- `client_max_body_size 25m;` (for photo/file uploads — default 1 MB caused HTTP 413)
- `location = /sms-hook` → `127.0.0.1:8090` (Twilio webhook, public)
- `location /m/` → `127.0.0.1:8090` (public outbound media)
- `location /api/` → `127.0.0.1:8090` (app API; auth enforced by the app)
- `location /sms` → `127.0.0.1:8090` (web inbox; auth enforced by the app)
- `location /legal/` → `alias /opt/legal-pages/` (static, public)
- `location /` → `https://127.0.0.1:8443` (FreePBX admin)

Backups of prior vhost versions are kept alongside as `freepbx.bak.*`.

---

## 8. Twilio configuration

- **Account SID:** `AC… (account SID — see server .env)` (auth token in `.env`).
- **Numbers:** `PN9896a03ee2a0089645dcea1f395a2ed6` (+15093098286), `PN095f604cebc23c3b0613790c83e0bb0d` (+13603024667). Both on the SIP trunk (voice) and with **SmsUrl = `https://pbx.bulwarkblack.com/sms-hook`** (POST).
- **Messaging Service:** `MG82af7ef4cd45904ad8102da8d341cd4b` ("Bulwark Black Outbound", `UseInboundWebhookOnNumber=True` so inbound still hits `/sms-hook`). Both numbers are senders in it.
  - A prior 3rd-party service ("Talkyto", `MGba8b8a3b8202d2bd8aa00d0c42a8aa3b`) used to hijack inbound SMS to a cloud function; the 509 number was removed from it and inbound restored.
- **A2P 10DLC:** approved Standard brand `BNcd2b8b7c7c1163c80b8375da08cf0ab2` (TCR `B8WJIPU`, "Bulwark Black LLC"). LOW_VOLUME campaign `QE2c6890da8086d771620e9b13fadeba0b` registered referencing the compliance pages below. **Until the campaign is approved, all outbound SMS/MMS fail with error 30034** (inbound is unaffected).
- **Compliance pages** (`/opt/legal-pages/`, served at `/legal/`): `privacy.html`, `terms.html`, `optin.html`. Privacy policy contains the carrier-required "No mobile information will be shared with third parties" language.

### Inbound verification-code note
Verification codes from some senders fail with error **30038 (OTP redaction)** on Trial
accounts. This account is now Full, but **VoIP/Twilio numbers are widely refused by
high-security senders (Google, banks, WhatsApp)** — use the voice "call instead" option
or a real mobile for those.

---

## 9. Push notifications (APNs)

- **Key:** APNs auth key `.p8`, Key ID `AX52YNBG35`, Team `7VS3GN26RD`. Stored on the
  server at `/data/apns_key.p8` (referenced by `APNS_KEY_P8`); **not** in git.
- **Topic / bundle id:** `com.bulwarkblackllc.freetwisms`.
- **Environment:** must match the app build. **Production** app (`aps-environment=production`)
  → `APNS_HOST=api.push.apple.com`. Development build → `api.sandbox.push.apple.com`.
  A mismatch returns `BadEnvironmentKeyInToken` / `BadDeviceToken`. Device tokens are
  environment-specific — after switching environments, re-run the app to register a fresh token.
- The connector signs an ES256 JWT (PyJWT) and POSTs over HTTP/2 (httpx) to APNs, including
  an `aps.badge` = unread count. ntfy is kept as a no-credential backup channel.

---

## 10. iOS app build/run

- Xcode 26+, iOS 17+, Swift 5 language mode. Project generated from `project.yml` via
  XcodeGen (`xcodegen generate`); the `.xcodeproj` is committed so it opens directly.
- Signing team: `7VS3GN26RD` (automatic). Push Notifications capability declared
  (`aps-environment=production`).
- First launch: enter server URL + login (stored in iOS Keychain).
- Free-tier installs expire in 7 days; the paid account gives 1-year installs + push.

---

## 11. Known TODOs

- FreePBX 15 / Asterisk 17 are EOL — plan an upgrade.
- Voicemail-to-email needs an SMTP relay on the container's msmtp.
- Host-level security: FreePBX admin is internet-exposed; no host fail2ban for SSH;
  pending OS updates + reboot. Rotate the Twilio auth token (was exposed in chat).
- Outbound SMS/MMS is gated on A2P campaign approval (error 30034 until then).
