# Compliance pages

Public SMS-compliance pages required for **A2P 10DLC** registration. On the server they
live in `/opt/legal-pages/` and are served (no auth) at:

- `https://pbx.bulwarkblack.com/legal/privacy.html` — Privacy Policy (includes the
  carrier-required "no mobile information shared with third parties" language)
- `https://pbx.bulwarkblack.com/legal/terms.html` — SMS Terms & Conditions
- `https://pbx.bulwarkblack.com/legal/optin.html` — SMS Opt-In / consent disclosure

The Twilio A2P campaign's message-flow references these URLs. Edit a file on the server
and it's live immediately (nginx `location /legal/` → `alias /opt/legal-pages/`).
