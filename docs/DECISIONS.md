# Decisions

Open questions that change the shape of the work, and the ones already settled.
Written down so the next session does not re-derive them.

---

## OPEN — needs the owner

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

### 3. Was: private vs public repo
Resolved by the above — **stays private**. macOS CI minutes still bill at 10x,
which is why the build workflow is manual + PR-only rather than per-push.

| option | cost | app lifetime | catch |
|---|---|---|---|
| AltStore / SideStore | free Apple ID | 7 days, auto-refresh | 3-app limit; SideStore needs a one-time pairing file |
| Apple Developer Program | €99/yr | 1 year | unlocks TestFlight — which may beat sideloading outright |
| TrollStore | free | permanent | only on exploitable iOS versions — **check the device's iOS first** |

Not decidable from here: it depends on the iPhone's iOS version and whether a
paid account is wanted. **Ask before building refresh logic.**

### 3. Native SwiftUI vs a wrapper
Scaffolded as native SwiftUI. A Capacitor/PWA wrapper would reuse the existing
hub UIs and could sidestep sideloading entirely (add-to-home-screen), at the
cost of native polish and background behaviour. Worth a deliberate answer
before much UI exists.

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
