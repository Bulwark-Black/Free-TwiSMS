# Free TwiSMS

A native SwiftUI iPhone app for reading and sending texts (and MMS/files) through a
Twilio number, backed by a lightweight self-hosted connector. Built as a personal
client for the Bulwark Black phone system.

> **A note from the author**
>
> Just to let you know, I built this specific to my situation, but the layout and code is
> here. If you want to use it you will have to create a Twilio account and buy a phone
> number ($1.15 a month, cheap), and host a server (cloud or otherwise). Install FreePBX on
> it and configure it if you also want phone calls and a desk phone. I use a Yealink T54W as
> my VoIP phone. It has two numbers on it. I also have an Apple Developer account ($99 a
> year), which allows me to use native Apple push notifications through production keys.
> Lastly, I set up legal compliance for the A2P campaign — this is what allows you to send
> out SMS and MMS messages over the VoIP numbers you have on Twilio. Without it you can not
> send out, only receive.
>
> See **[Make it work for your situation](#make-it-work-for-your-situation)** below for the
> exact list of things to change.

## What it does

- Phone-style messaging UI: conversation list, chat threads, number switcher
- Send/receive SMS and MMS (photos)
- Send any file as a download link (PDF, docs, etc.)
- Emoji picker (plus the system keyboard emoji)
- Native Apple push notifications on incoming texts (tap opens the conversation)
- Verification codes auto-highlighted

## How it all fits together

Free TwiSMS isn't a standalone app — it's the pocket half of a little self-hosted phone
system. The neat part is that **the same two phone numbers ring my desk phone *and* show up
in the app**: Twilio is the phone company, a small server in the middle glues everything
together, and the app and desk phone are just two windows into it. Below I walk through each
piece, then trace, step by step, what actually happens when a text or a call comes in.

### The pieces

Think of it like a relay team — Twilio talks to the outside phone network, the server in the
middle makes sense of everything, and the app and desk phone are the ends you actually touch.

| Piece | What it does |
|---|---|
| **Twilio** | The phone company. It owns the numbers and is the bridge to the real phone network — handling calls (over a SIP trunk) and texts (over webhooks + its REST API). |
| **The connector** (Python, in Docker) | The brain of the texting side. It catches incoming texts, files them in a little database, hands them to the app, sends your outgoing texts, and fires off notifications. It's one small Python file — no heavy framework. |
| **FreePBX / Asterisk** (Docker) | The PBX — the part that handles actual *phone calls*, routing them between Twilio and the desk phone and taking voicemail. (Only needed for the voice side.) |
| **nginx** | The front door. It handles HTTPS for the domain and quietly sends each request to the right place behind it. |
| **The app** (this repo) | Your pocket window into all of it — reading and sending texts, and buzzing you when something arrives. |
| **APNs** | Apple's notification service — how the server reaches out and lights up your phone. |
| **OpenVPN** | A private tunnel so the desk phone can reach the server safely, without leaving phone signaling exposed on the open internet. |

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

### When a text comes in

Here's the whole journey of an incoming text, from someone's thumb to your pocket:

1. Someone texts one of your numbers. Twilio, as the phone company, receives it first.
2. You've told Twilio "whenever a text hits this number, hand it to my server" — that's the
   *Messaging webhook*, pointed at `https://your-domain/sms-hook`. So Twilio immediately
   forwards the whole message (who it's from, who it's to, the text, and any photo) to your server.
3. The connector's first move is to make sure the message is *really* from Twilio and not
   someone poking at the URL — it checks a signature Twilio stamps on every request, and
   drops anything that doesn't match.
4. Once it's verified, the connector files the text away in its little database (and quietly
   downloads any attached photo).
5. Then it fans out and nudges everything that should know about the new message, all at once:
   - your **desk phone** gets a little text popup,
   - your **iPhone** gets a push notification with a preview and an updated unread badge,
   - and a backup notification fires over ntfy, just in case.
6. The app shows the new message — the instant the notification lands, or the next time it
   checks in with the server.

### When you send a text, photo, or file

When you hit send, the app hands the message to your server, which passes it on to Twilio —
but the three kinds of attachment take slightly different routes:

- **A plain text** goes straight through Twilio and out to the recipient. Simple.
- **A photo** is a little trickier, because carriers want a *link* to the image, not the raw
  bytes. So the connector tucks the photo away at a public web address and tells Twilio
  "send this as a picture message, and here's where to grab it." Twilio fetches it and delivers it.
- **A file** (a PDF, a document) is trickier still — US carriers tend to strip anything
  that isn't a photo out of picture messages. So rather than fight that, the connector hosts
  the file and just **texts the recipient a download link**, which works for any file type
  and always gets through.

Either way, the sent message gets saved too, so it shows up in the thread like a normal reply.

> **One important catch for US numbers:** carriers won't let an ordinary 10-digit number
> send texts at all until you've gone through *A2P 10DLC* registration (covered in the setup
> section). Until that's approved you can **receive** texts perfectly, but anything you
> *send* gets quietly blocked. Receiving works from day one; sending is the part that takes
> paperwork.

### How the app reads your messages

The app itself is deliberately simple — it holds no data of its own. It just asks the server
for things over a small set of requests (all behind a login, over HTTPS, with your
credentials stored safely in the iPhone's Keychain). In plain English, it asks:

- *what numbers do I have?* (to build the switcher at the top)
- *give me my conversations, newest first*
- *give me the messages in this one conversation*
- *send this for me* · *I've read these, clear the badge* · *here's my phone's notification address*

The server answers each one straight out of its database. That's the entire app-to-server
relationship — no magic, just a handful of tidy requests. (For the curious, those map to
`/api/numbers`, `/api/conversations`, `/api/thread`, `/api/send*`, `/api/mark-read`, and
`/api/register-device`.)

### How the notifications actually reach your phone

1. When the app launches, it asks iOS for this phone's unique "push address" and hands it to
   the server, so the server knows where to reach you.
2. When a text arrives, the server builds a securely-signed little message and sends it to
   **Apple's** push service, including the preview and your unread count.
3. Apple delivers it to your phone. Tap it and the app opens **straight to that
   conversation**; open the app and the badge clears.

> **The one gotcha** (and the thing that cost me hours): Apple runs two separate notification
> worlds — a **sandbox** one for apps you run straight from Xcode, and a **production** one
> for apps installed through TestFlight or the App Store. Your push key *and* your server
> have to be pointed at the same world the app was installed from, or Apple just refuses the
> notification with a cryptic `BadDeviceToken` error. Match them and it works instantly.

### How phone calls work (the optional voice side)

Calls never touch the texting connector at all — they ride a completely separate path
through Twilio and FreePBX:

- **Someone calls you:** Twilio receives the call and hands it to FreePBX, which looks at
  which number was dialed and rings the matching line on the desk phone (over the VPN). No
  answer? It rolls to that line's voicemail.
- **You call out:** you pick which line/identity you want on the desk phone, FreePBX stamps
  that line's caller ID onto the call, and sends it back out through Twilio to the real phone
  network. (That's how each number can show its own business name on outgoing calls.)

For safety, the phone side is firewalled to only accept traffic from Twilio and the VPN — the
PBX is never sitting open on the public internet, which is how people get hit with toll fraud.

### Why there's a VPN

My desk phone lives somewhere other than the server. The lazy way to connect them would be
to expose the phone system to the internet — but that's exactly what bots scan for, brute-
forcing their way in to rack up fraudulent international calls. So instead the phone dials
into a private VPN tunnel and reaches the server through that. (It also neatly solved a
networking snag at the phone's location.)

### How it's kept secure

- Everything over the web is **HTTPS**. The app and web inbox sit behind a **login**, and
  your credentials live in the iPhone's **Keychain**, not in plain text anywhere.
- Every incoming text from Twilio is **signature-checked**, so nobody can fake messages into
  your inbox. The only intentionally-public spots are the attachment links and the legal
  pages — and those *have* to be reachable so Twilio and recipients can load them.
- The phone system only listens to Twilio and the VPN. And every secret — Twilio keys, the
  Apple push key, passwords — lives in a locked-down file on the server and **never** goes
  into this repo.

## Building

- Xcode 26+, iOS 17+ target
- The project file is generated from `project.yml` with
  [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`xcodegen generate`), but the
  generated `.xcodeproj` is committed so it opens directly.
- Set your signing team in Xcode (Signing & Capabilities). Push Notifications
  capability is already declared.
- On first launch, enter your server URL + login.

## Make it work for your situation

I built this around my own phone setup, so a handful of things are wired specifically to
me — my domain, my phone numbers, my Apple account, my business details. None of it is
hard to change, but you'll be touching a few different places (this app, a small server,
your Twilio account, and Apple's developer portal). Here's the whole thing, roughly in the
order I'd do it, with the *why* behind each step so it's not just a checklist.

**Before you start, decide how far you want to go.** There are really two halves here. The
**texting half** (the app + a small server + Twilio, optionally with push notifications) is
the core, and it's not too bad to stand up. The **voice half** (FreePBX + a physical desk
phone + a VPN) is completely optional — skip it entirely if you just want texting. I've
marked the voice-only bits clearly at the end.

**1. Get a server with a domain name.** The app and Twilio both need to reach your server
over plain HTTPS — Twilio has to POST your incoming texts to a public URL, and Apple's push
service won't talk to anything that isn't HTTPS. Any cheap cloud VPS does the job. Point a
domain (or a subdomain) at it and grab a free Let's Encrypt certificate. Wherever you see
`pbx.bulwarkblack.com` in the config, that becomes your domain — it's the address your app
talks to and the address Twilio delivers your texts to.

**2. Set up Twilio.** Create an account and buy a number (search by area code — they're
about $1.15/month). Two things to wire up: point the number's **Messaging webhook** at
`https://your-domain/sms-hook` (that's the pipe your incoming texts flow through), and copy
your **Account SID + Auth Token** into the server config so the connector can send texts on
your behalf. That's it for receiving; sending also needs the A2P step (#5).

**3. Run the connector.** This is the small Python service that's the actual brain — it
catches incoming texts, stores them, serves the app's data, and sends your outgoing texts.
Two things in it are personal to me: the **`NUMBERS` list** near the top of `app.py` (swap
in your own number(s) and whatever friendly label you want to see for each), and the
**`.env` file** — that's where your domain, the username/password you'll log into the app
with, your Twilio keys, and the Apple-push settings from step 6 all go. Nothing secret is
ever committed to the repo; you fill in your own `.env` on the server. *(Note: the connector
code itself currently lives on the server, not in this repo — see
[docs/INFRASTRUCTURE.md](docs/INFRASTRUCTURE.md) for its layout.)*

**4. Make the app yours.** Open `project.yml` and change two things: the **bundle
identifier** to something unique to you (like `com.yourname.yourapp`), and the **Development
Team** to your Apple Team ID so Xcode can sign it. Then run `xcodegen generate`. If you
want, rename the app and drop in your own icon too. The nice part: the app doesn't hardcode
your phone numbers — it pulls them from your server — so once it points at your domain and
you log in with the username/password you set in step 3, everything just shows up.

**5. Register A2P so you can actually send (US numbers).** This one surprises people. US
carriers won't let a regular 10-digit number send texts until you register an **A2P 10DLC
"brand" and "campaign"** — basically telling the carriers who you are and what kind of
messages you'll send. Part of that is publishing a privacy policy, SMS terms, and an opt-in
page; mine are in the `legal/` folder, so just swap in your business name, email, and
number(s) and host them. Until your campaign is approved you can **receive** texts fine, but
**outgoing** ones get silently blocked by the carriers — so start this early, because
approval can take a few days.

**6. Turn on push notifications (optional, but it's the magic).** This is the fiddly part,
and it needs the paid ($99/year) Apple Developer account. In Apple's developer portal you
create a push **key** (a `.p8` file), note its **Key ID** and your **Team ID**, and drop
those plus the `.p8` onto your server. The one thing that *will* trip you up: the push
**environment has to match how you install the app**. A build you run straight from Xcode
uses Apple's **sandbox**; a build you ship through **TestFlight** or the App Store uses
**production**. Mismatch them and you get cryptic `BadDeviceToken` errors. (Ask me how I
know — see "How the notifications actually reach your phone" above.)

**7. (Optional) The phone-call side.** Only bother with this if you want real phone calls
and a physical desk phone, not just texting — the texting app needs none of it. This is
where **FreePBX** comes in: it's the PBX that routes calls between Twilio and a SIP phone (I
use a **Yealink T54W**). You'd set up a Twilio **SIP trunk**, create **extensions** and
call-routing rules in FreePBX (which number rings which phone, and which caller ID goes out
on each line), and register your phone to those extensions. If the phone isn't sitting on
the same network as the server, put them both on a **VPN** so you're not exposing phone
signaling to the open internet. It's easily the most involved part of the whole project.

## Infrastructure

The full server-side stack (PBX, SMS connector, Twilio, nginx, APNs, A2P) is
documented in **[docs/INFRASTRUCTURE.md](docs/INFRASTRUCTURE.md)** — exact build,
config, endpoints, and operational runbook. (Secrets live in the server `.env`, never here.)

## Status

Single-tenant personal build. See the project notes for what a multi-tenant /
App Store version would require (accounts, per-user Twilio, A2P at scale).

---

© Bulwark Black LLC. All rights reserved.
