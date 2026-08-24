# Decisions

Open questions that change the shape of the work, and the ones already settled.
Written down so the next session does not re-derive them.

---

## RESOLVED THIS ROUND

### ~~1. Signing route~~ — SETTLED: AltStore
See `docs/ALTSTORE.md`. Consequences now fixed:
- Free Apple ID → **7-day** signing, background refresh. Prefer **SideStore**,
  which refreshes over Wi-Fi via a pairing file rather than needing a computer.
- **3-app cap** on free Apple IDs.
- CI produces an **unsigned** `.ipa` — which is exactly what AltStore resigns.
- **AltStore PAL** (EU, no 7-day limit) remains an option but is not a drop-in:
  it distributes ADPs, not plain `.ipa`s. Recorded, not adopted.

Still open under this heading: nothing blocking. Revisit only if the weekly
refresh becomes annoying enough to justify €99/yr — at which point compare
TestFlight rather than assuming sideloading.

### ~~2. Where the IPA is hosted~~ — SETTLED: over the tailnet
AltStore must fetch the source JSON and the `.ipa` from the phone, and
**private-repo release assets require auth**, which AltStore does not send. The
usual workaround is making the repo public.

Not needed here: the phone (`iphone173`, 100.90.114.93) is already on the
tailnet with this host (`pluto-kali`, 100.112.72.3), and Caddy is already
running. Serve both files there. Repo stays private, nothing faces the
internet, and Tailscale issues the real certificate iOS ATS requires.

### ~~3. Private vs public repo~~ — SETTLED by the above
**Stays private.** macOS CI minutes still bill at 10x, which is why the build
workflow is manual + PR-only rather than running on every push.

---

## OPEN — still needs the owner

### ~~4. Native SwiftUI vs a wrapper~~ — SETTLED: PWA first
Decided with the owner. The deciding fact: **the gateway is tailnet-only, and
the owner connects deliberately rather than staying connected.**

Once the data source is unreachable much of the time, native's usual advantage
(works offline) mostly evaporates — a native app with no tailnet shows nothing
useful either. What remains is a straight comparison the PWA wins:

|  | PWA | native + AltStore |
|---|---|---|
| weekly re-signing | none | every 7 days, forever |
| 3-app cap (free Apple ID) | n/a | consumes one |
| macOS CI at 10x minutes | none | every build |
| shipping an update | copy to Caddy | rebuild, resign, re-download |
| the existing 10 hub UIs | reusable | rewrite in SwiftUI |

**Push alerts do not distinguish the options.** Nothing can push to the phone
over a tailnet it is not connected to — not a PWA, not a native app. Real push
needs an internet-reachable relay (APNs), which cuts against the
nothing-faces-the-internet posture. So the alert inbox is check-on-open for
now. Deliberately deferred, not overlooked.

**The trigger to revisit:** if reliable background alerts become a requirement
and a push relay is accepted, native becomes the better tool. The AltStore
plumbing (source manifest, release script, schema tests) is already in place
and stays valid — this is a fork in the road, not a discarded branch.

Consequence that shapes the code: because disconnection is the NORMAL state,
every read is cached and rendered **with its age**. Showing a two-day-old
"all services healthy" as if current is the false-clean failure the parent repo
keeps hitting; `web/src/store.js` returns `fresh` / `cached` / `none` and the
UI must distinguish them.

---

## SETTLED

### Talks to the existing gateway, no new server
The Toolbelt gateway already runs on `:3847` and exposes a safe lane of ~10
read-only actions, reachable over Tailscale. Standing up a second backend for
the phone would mean a second auth surface to get right. Reuse it.

### Finance is read-only in this app — permanently
The desktop trader is crypto-only and gated behind armed + kill-switch +
daily-loss halt, with a graduated live rail (20 paper cycles and 7 days before
real money, first 10 orders at quarter size). Those guarantees hold because
there is exactly one path to an order.

A phone app that could arm or trade would be a second, weaker path — different
auth, easier to lose, easier to shoulder-surf. Watchlist and portfolio display
only.

### No credential vault, no offensive bridges
The vault stays on the desktop. Kali, hexstrike and the CLI-agent bridge are
out of scope: they are owner-operated tooling with container-RCE-equivalent
reach, and they are gated to extension pages for good reason.

### Builds run on GitHub-hosted macOS
Both self-hosted runners are Linux. No local Xcode exists anywhere in this
setup. Verified, not assumed.
