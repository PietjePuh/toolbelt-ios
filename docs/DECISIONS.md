# Decisions

Open questions that change the shape of the work, and the ones already settled.
Written down so the next session does not re-derive them.

---

## OPEN — needs the owner

### 1. Signing route
Blocks: update/refresh handling, whether CI signs, whether TestFlight is better.

| option | cost | app lifetime | catch |
|---|---|---|---|
| AltStore / SideStore | free Apple ID | 7 days, auto-refresh | 3-app limit; SideStore needs a one-time pairing file |
| Apple Developer Program | €99/yr | 1 year | unlocks TestFlight — which may beat sideloading outright |
| TrollStore | free | permanent | only on exploitable iOS versions — **check the device's iOS first** |

Not decidable from here: it depends on the iPhone's iOS version and whether a
paid account is wanted. **Ask before building refresh logic.**

### 2. Private vs public repo
Private today. macOS CI minutes bill at **10×** on private repos; they are free
on public ones. Flipping to public is one click; flipping back does not
un-publish history. Left private deliberately — revisit if CI cost bites.

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
