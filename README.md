# Free TwiSMS

A native SwiftUI iPhone app for reading and sending texts (and MMS/files) through a
Twilio number, backed by a lightweight self-hosted connector. Built as a personal
client for the Bulwark Black phone system.

## What it does

- Phone-style messaging UI: conversation list, chat threads, number switcher
- Send/receive SMS and MMS (photos)
- Send any file as a download link (PDF, docs, etc.)
- Emoji picker (plus the system keyboard emoji)
- Native Apple push notifications on incoming texts (tap opens the conversation)
- Verification codes auto-highlighted

## Architecture & how it works

Free TwiSMS is one piece of a small self-hosted phone system. The same two phone
numbers are shared by a **Yealink desk phone** (voice) and the **iPhone app** (texts),
with **Twilio** as the carrier and a **self-hosted server** tying it all together. This
section explains every moving part and traces each thing that can happen end to end.

### The components

| Component | Role |
|---|---|
| **Twilio** | The carrier. Owns the two phone numbers; delivers/receives calls (via a SIP trunk) and SMS/MMS (via webhooks + REST API). |
| **FreePBX / Asterisk** (Docker) | The PBX. Routes calls between Twilio and the desk phone, applies caller ID, runs voicemail. |
| **SMS connector** (Python, Docker) | The brain for texting + the app. Receives Twilio's SMS webhooks, stores messages in SQLite, serves the JSON API and web inbox, sends outbound texts, and fires push notifications. |
| **nginx** | TLS termination (`pbx.bulwarkblack.com`, Let's Encrypt) and a reverse proxy that routes each URL path to the right place. |
| **OpenVPN** | A secure tunnel so the remote desk phone can reach the PBX without exposing SIP to the internet. |
| **Free TwiSMS (this app)** | The iPhone client: reads/sends texts over the JSON API, receives push notifications. |
| **APNs** | Apple's push service, used to notify the iPhone of incoming texts. |

```
                         ┌──────────────────────── Twilio ─────────────────────────┐
   PSTN  ◀──calls──▶ SIP Trunk            SMS/MMS webhooks ▶          REST API ◀ send
                         └────────┬──────────────────┬──────────────────┬──────────┘
                                  │ SIP/RTP           │ HTTPS POST       │ HTTPS
                                  │ (Twilio IPs only) │ /sms-hook        │
   ┌────────────────────────── server (pbx.bulwarkblack.com) ───────────────────────┐
   │  nginx 443 ──/──▶ FreePBX admin                                                 │
   │           ├─ /sms-hook,/api/,/sms,/m/ ─▶ SMS connector ──▶ SQLite + media       │
   │           └─ /legal/ ─▶ static compliance pages                                 │
   │  FreePBX/Asterisk ◀── SIP trunk ;  AMI ◀── connector (desk-phone text popups)   │
   │  OpenVPN server (UDP 1194)                                                       │
   └───────────┬───────────────────────────────────────────────┬─────────────────────┘
               │ SIP/RTP over VPN                               │ APNs (HTTP/2, JWT)
        Yealink T54W desk phone                          iPhone — Free TwiSMS app
        (ext 101 = 509, ext 102 = 360)                   (JSON API + push notifications)
```

### Flow 1 — Receiving a text (the Twilio webhook)

1. Someone texts **+1 509** or **+1 360**. Twilio receives it.
2. Each number has its **Messaging webhook (`SmsUrl`)** set to
   `https://pbx.bulwarkblack.com/sms-hook`. Twilio sends an **HTTP POST** there with the
   sender, recipient, body, and any media URLs.
3. nginx routes `/sms-hook` to the connector. The connector **validates the
   `X-Twilio-Signature`** header (HMAC-SHA1 of the URL+params with the Twilio auth token)
   so only genuine Twilio requests are accepted.
4. The message is written to **SQLite**. Any MMS images are downloaded from Twilio
   (authenticated) and saved locally.
5. The connector then **fans out** three notifications:
   - **Desk phone:** a SIP `MESSAGE` is pushed to the Yealink via Asterisk **AMI**, so a text popup appears on the phone.
   - **iPhone:** an **APNs** push (see Flow 4), carrying a preview and the unread badge count.
   - **ntfy:** a no-credentials backup push (optional).
6. The iPhone app (and the web inbox) show the new message — either from the push, or on
   its next poll of the JSON API.

### Flow 2 — Sending a text, photo, or file from the app

1. You type a message and hit send. The app `POST`s to the connector's JSON API:
   - **Text:** `POST /api/send` → connector calls the **Twilio REST API** (`Messages`) → Twilio sends it.
   - **Photo (MMS):** `POST /api/send-mms` with the image base64-encoded. The connector saves it to a **public** path (`/m/<name>`), then tells Twilio to send an MMS whose `MediaUrl` points there — Twilio fetches the image from that public URL and delivers it.
   - **File (PDF, docs):** `POST /api/send-file`. US carriers drop non-image MMS, so instead the connector hosts the file at `/m/<name>` and sends a **plain text with a download link**. Reliable for any file type.
2. The sent message is recorded in SQLite so it appears in the thread.

> **A2P note:** US carriers require **A2P 10DLC** brand + campaign registration before a
> 10-digit number may send SMS. Until the campaign is approved, outbound sends are
> accepted by Twilio but blocked by carriers (error 30034). Receiving is unaffected.

### Flow 3 — Reading messages in the app

The app is a thin client over a JSON API (HTTP Basic auth over HTTPS, credentials in the
iOS Keychain). It polls a few of these:

- `GET /api/numbers` — the numbers this account owns + their labels (the top switcher)
- `GET /api/conversations[?box=<number>]` — threads, newest first
- `GET /api/thread?via=<ournum>&with=<contact>` — the messages in one thread
- `POST /api/send`, `/api/send-mms`, `/api/send-file` — outbound (Flow 2)
- `POST /api/register-device` — hand the connector this device's APNs token (Flow 4)
- `POST /api/mark-read` — reset the unread badge
- `GET /sms/media/<name>` — fetch an image in a thread (authenticated)

The connector reads/writes SQLite and returns JSON; there is no heavy framework — it's a
single Python file using only the standard library plus `httpx`, `pyjwt`, `cryptography`.

### Flow 4 — Push notifications (APNs)

1. On launch the app asks iOS for a **device token** and sends it to
   `POST /api/register-device`. The connector stores it.
2. When a text arrives (Flow 1), the connector builds an **ES256 JWT** signed with the
   APNs auth key (`.p8`), then makes an **HTTP/2 POST** to Apple's APNs with the alert,
   the **unread badge count**, and custom data (which conversation it belongs to).
3. Apple delivers the push to the phone. Tapping it **deep-links** straight to that
   conversation. Opening the app calls `mark-read`, which clears the badge.

> The APNs **environment must match the app build**: a TestFlight/App Store build uses
> the **production** APNs host; an Xcode "Run" (debug) build uses **sandbox**. The auth
> key is scoped to one or both environments. A mismatch is the classic
> `BadEnvironmentKeyInToken` / `BadDeviceToken` error.

### Flow 5 — Phone calls (the SIP trunk)

Voice never touches the connector — it flows through Twilio's **Elastic SIP Trunk** and
Asterisk:

- **Inbound:** caller → Twilio → SIP trunk → Asterisk → the number's **Inbound Route** →
  rings the matching extension (509 → ext 101, 360 → ext 102) → the **Yealink** over the VPN.
- **Outbound:** you pick **Line 1** (Bulwark Black) or **Line 2** (Rural Tech) on the
  desk phone → Asterisk's **Outbound Route** stamps that line's caller ID → SIP trunk →
  Twilio → the PSTN.
- **Unanswered** calls fall through to that extension's **voicemail**.

The SIP trunk is firewalled so SIP/RTP is accepted **only from Twilio's IP ranges and
the VPN** — the PBX is never exposed to the open internet (toll-fraud protection).

### Why the VPN

The desk phone is remote. Rather than expose SIP to the internet (which invites
brute-force registration and toll fraud), the phone joins an **OpenVPN** tunnel and
registers to the PBX over that private link. This also sidestepped a prior CGNAT issue at
the phone's location.

### Security model

- All web traffic is **HTTPS** (Let's Encrypt). The app and web inbox use **HTTP Basic
  auth**; the iPhone stores credentials in the **Keychain**.
- Twilio webhooks are **signature-validated**; only `/m/` and `/legal/` are intentionally
  public (so Twilio and message recipients can fetch attachments / compliance pages).
- SIP is restricted to Twilio + VPN. Secrets (Twilio token, APNs key, passwords) live in
  a root-only `.env` on the server and are **never committed** to this repo.

## Building

- Xcode 26+, iOS 17+ target
- The project file is generated from `project.yml` with
  [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`xcodegen generate`), but the
  generated `.xcodeproj` is committed so it opens directly.
- Set your signing team in Xcode (Signing & Capabilities). Push Notifications
  capability is already declared.
- On first launch, enter your server URL + login.

## Infrastructure

The full server-side stack (PBX, SMS connector, Twilio, nginx, APNs, A2P) is
documented in **[docs/INFRASTRUCTURE.md](docs/INFRASTRUCTURE.md)** — exact build,
config, endpoints, and operational runbook. (Secrets live in the server `.env`, never here.)

## Status

Single-tenant personal build. See the project notes for what a multi-tenant /
App Store version would require (accounts, per-user Twilio, A2P at scale).

---

© Bulwark Black LLC. All rights reserved.
