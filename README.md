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

## Architecture

This repo is the **iOS client**. It talks to a small JSON API exposed by a separate
server-side connector (a Python service sitting in front of Twilio + FreePBX):

- `GET  /api/numbers` — the numbers this account owns
- `GET  /api/conversations` — threads, newest first
- `GET  /api/thread?via=&with=` — messages in a thread
- `POST /api/send` / `/api/send-mms` / `/api/send-file` — outbound
- `POST /api/register-device` — register the APNs device token

Auth is HTTP Basic over HTTPS; credentials are stored in the iOS Keychain.
Notifications are delivered via APNs (token auth key on the server).

## Building

- Xcode 26+, iOS 17+ target
- The project file is generated from `project.yml` with
  [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`xcodegen generate`), but the
  generated `.xcodeproj` is committed so it opens directly.
- Set your signing team in Xcode (Signing & Capabilities). Push Notifications
  capability is already declared.
- On first launch, enter your server URL + login.

## Status

Single-tenant personal build. See the project notes for what a multi-tenant /
App Store version would require (accounts, per-user Twilio, A2P at scale).

---

© Bulwark Black LLC. All rights reserved.
