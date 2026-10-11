# Phase 2: email notifications (design, not built)

Nimbus UPS Bar 1.0 tells the owner what happened through macOS notifications and the log.
Both only reach someone sitting at the Mac. The desk is often unattended, and the volumes are
reached over the network from elsewhere, so the next step is a message that leaves the house:
an email when the power goes, when a volume comes off, and when everything is back.

This document is the design to review before anything is written. Nothing below exists yet.

## What an email has to achieve

- **Reach the owner wherever they are** within a minute of each stage change, on a phone.
- **Say what was done to the data**, not just that the power went: which volumes were
  unmounted, which apps were asked to quit and whether they went, and whether the volumes are
  back.
- **Survive the outage itself.** The router, the modem and the switch are usually on wall
  power, not on this UPS. The first few minutes of an outage are exactly when there may be no
  internet. A message that cannot be sent has to wait and go later, in order, with its
  original timestamp, rather than be lost.
- **Never block the guard.** Sending runs beside the state machine, never inside it. A hung
  SMTP connection must not delay an unmount.
- **Keep secrets in the Keychain** and nothing else, as the Leviton app does with its login.

## Events and messages

One email per event, short enough to read on a lock screen. Subjects carry the facts:

| Event | Subject |
| --- | --- |
| Transfer to battery | `Power outage: UPS at 100 %, 190 min left` |
| Soft stage | `Closing apps: asked Lightroom Classic to quit` |
| Volume unmounted | `Flitslig unmounted (safe to lose power)` |
| Hard limit | `Forced unmount: charge at 50 %` |
| Power restored | `Power restored after 12 min; Flitslig remounted` |
| Health fault | `UPS fault: battery needs replacement` |
| Daily digest (optional) | `UPS fine: 100 %, 118 W, 3 h runtime` |

The body is the same as the log lines for the outage so far, oldest first, plus the current
UPS figures and the Mac's own battery level. A "power restored" message carries the whole
outage in one place, which is the one most people will actually read.

Blips shorter than the grace period produce one message, not two: "power flickered for 40 s,
nothing was touched", sent when the outage ends. A rehearsal or drill sends nothing unless a
"send test email" item is used.

## Transport: three candidates

| Option | For | Against |
| --- | --- | --- |
| **SMTP with an app password** (Gmail, Fastmail, iCloud) | No server to run; works from anywhere; the app owns the whole path | An SMTP client in Swift (STARTTLS, AUTH PLAIN, MIME) is a few hundred lines; the app password sits on this Mac |
| **A hosted relay** (a tiny HTTPS endpoint, SendGrid, Postmark, a Cloudflare Worker) | Trivial client: one HTTPS POST; the key can be scoped to "send to the owner only" | A service to keep alive; a dependency outside the house |
| **Mail.app through Apple events** | Nothing to configure; uses whatever account Mail has | Needs Mail running and Automation permission; silent when Mail is quit, which it is on an unattended Mac |

The recommendation is **SMTP with an app password, written in-house**, for the same reason the
updater was: no dependency, nothing else to keep running, and the trust is in one place (the
Keychain item). Network.framework gives TLS for free; the protocol on top of it is small.

## Queue and retry

- Every message is appended to a queue on disk (`~/Library/Application Support/Nimbus UPS
  Bar/outbox/`, one JSON file per message, named by timestamp).
- A sender loop tries the oldest message, then the next, and on any failure waits with
  backoff (10 s, 30 s, 1 min, 5 min, then every 5 min) and tries again. A message older than
  24 hours is dropped with a log line.
- `NWPathMonitor` kicks the loop as soon as a path to the internet exists, so the backlog
  goes the moment the router is back.
- Sending runs on its own queue; the guard only ever appends.

## Settings and UI

A **Notifications** submenu replacing today's checkbox:

- *Show notifications on this Mac* (today's behaviour).
- *Email me…* opens a small dialog: recipient, SMTP host and port, user name, app password
  (Keychain), with a *Send Test Email* button that reports the SMTP conversation's result.
- *Email a daily summary at 09:00* (off by default).
- The last send's result in the submenu: `last email sent 3 min ago` or `⚠︎ could not send:
  connection refused`.

Settings other than the password live in UserDefaults like everything else; the password is a
generic-password Keychain item, `Keychain.swift` copied from nimbus-leviton-bar with the
service name changed. The Developer ID signature keeps the Keychain prompt to one "Always
Allow" (see that repo's CLAUDE.md on why ad-hoc builds re-prompt).

## Open questions for the owner

1. **Which account sends?** A dedicated address for the desk (`macbookpro@…`) keeps an app
   password away from the main account.
2. **One recipient or several?** The design assumes one, comma-separated is easy.
3. **Should a health fault email at once, or only in the digest?** A replace-battery flag is
   worth an immediate email; "no load" is a one-off setup warning better left to the digest.
4. **Is SMS wanted too?** Most carriers accept email at a gateway address, so this design
   covers it with a second recipient and a shorter body.

## Steps, once agreed

1. `Keychain.swift` and the settings dialog, with Send Test Email working end to end.
2. The outbox and the sender loop, tested against a local SMTP sink (`python3 -m smtpd` or
   `mailpit`) and against the real provider.
3. Hook the guard's events in, through the same `GuardEnvironment.notify` the notifications
   use, so the state machine stays untouched.
4. The daily digest timer.
5. A drill with the network cable pulled for the first two minutes, to see the queue drain.
