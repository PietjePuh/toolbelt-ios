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

### ~~2. Where the IPA is hosted~~ — SETTLED: over the tailnet *(applies only to the deferred native fork)*
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

**CORRECTED 2026-08-24 — see decision 5.** The original framing here treated
the app as tailnet-only and therefore useless when disconnected. That was
wrong, and the owner caught it.

Consequence that shapes the code: because disconnection is the NORMAL state,
every read is cached and rendered **with its age**. Showing a two-day-old
"all services healthy" as if current is the false-clean failure the parent repo
keeps hitting; `web/src/store.js` returns `fresh` / `cached` / `none` and the
UI must distinguish them.

---

### 5. Two tiers — internet-only, plus more on the tailnet
**Corrects an assumption baked into decisions 2 and 4.**

I designed as if the app were tailnet-only, which made it a brick whenever
Tailscale was off. The owner's objection: most Toolbelt tools need the internet
anyway, so an app that only works on the tailnet has the dependency backwards.

The confusion was mine: the tools that need internet need the GATEWAY's
internet, not the phone's. `pluto-kali` already has connectivity and does that
work on the owner's behalf. But it is still true that an app which does nothing
without a VPN is the wrong product.

So the app has two tiers and degrades on purpose:

| tier | needs | provides |
|---|---|---|
| internet only | any connection | market data, RSS, AI — public APIs called directly. No VPN. |
| + tailnet | Tailscale on | local service health, alert inbox, gateway safe-lane control |

Consequences:
- The PWA is served **publicly** (it is static files — nothing sensitive) so it
  loads without the tailnet. Decision 2's tailnet-only hosting applied to the
  AltStore `.ipa`, and is moot now that the native fork is deferred.
- **The gateway is NOT exposed.** No Funnel, no tunnel, no port-forward. The
  tailnet tier simply fails to the cached/none states already built.
- Any public API the app calls directly needs its key ON THE PHONE. That is a
  real trade: a phone key is easier to lose than a desktop vault entry. Use
  read-only keys where the provider offers them, and never the trading
  credentials — Bitvavo keys stay on the desktop, withdrawal-disabled, as they
  already are.

Worth recording for later: the gateway binds to 127.0.0.1 by default and
REFUSES to start on a non-loopback address without auth, with HMAC signing and
nonce replay protection. It was built anticipating exposure — so Tailscale
Funnel remains a viable future option. Deliberately not taken now: exposing the
gateway is the owner's call, not something to switch on while they are away.

### 6. Public, but self-hosted-by-the-user — the gateway ships INSIDE the app
Supersedes the personal-tool framing of decisions 2 and 5.

Goal: anyone can use it, distributed from the GitHub repo — **not** the App
Store. That avoids App Review and the €99/yr, and it avoids the thing that
would otherwise sink this: running infrastructure for strangers.

**The gateway is embedded in the app.** Each user's device does its own
fetching, with their own API keys, over their own connection. Consequences,
which are the whole point:

- **No hosted backend.** No uptime obligation, no bill, no scaling.
- **No data-processor role.** Nobody's data ever reaches the author, so the
  GDPR surface is the user's own device, not a service.
- **Scanner abuse is not the author's problem.** A domain scan originates from
  the user's own connection. Still ship a consent line in-app — "only scan what
  you own or are authorised to test" — because it is the right thing to say,
  not because it shifts liability.

**Optional second mode:** connect to a self-hosted gateway on a Linux box, for
users who want the full 42-stack setup. That is the author's own configuration,
generalised — not a service anyone else operates.

**Why this also settles native (again, and for a better reason):** an embedded
gateway must make arbitrary cross-origin HTTP requests. A browser cannot —
CORS forbids it, which is precisely why the domain scanner and in-app browser
were already forcing native. Same constraint, now load-bearing for the whole
architecture rather than two features.

### 7. Repo must go PUBLIC — OPEN, needs the owner
Blocks distribution, and only the owner can decide it.

GitHub **release assets on a private repo require authentication**, so nobody
could download the `.ipa`. Distribution-from-the-repo therefore requires the
repo to be public. It also makes macOS CI minutes **free**, removing the 10x
private-repo cost that shaped the build workflow.

Not reversible in the way it sounds: flipping to public is one click, but
flipping back does **not** un-publish what was already fetched or forked.
Before flipping, confirm no secret has ever been committed — the history goes
public too, not just the current tree.

### 8. Scope discipline — what the public version is ABOUT
The differentiator is **aggregation**: most apps wrap one provider; this one
puts many behind a single gateway with one auth model. That is the unglamorous
work already done in the parent repo and it is genuinely hard to copy.

Tasks, goals, calendar and habits are **commodity** — a crowded space, and
including them turns the pitch into "everything app", which is far harder to
land than "the one app that unifies your security and money tools". Keep them
as personal/v2 features, out of the public story.

**Finance stays educational-not-advice, and it matters more now.** With real
users, §6 stops being a style rule and becomes what keeps this clear of
investment-advice regulation in the EU. Transparent indicators with their
numbers; never an invented price target; never a recommendation to buy.

---

## SETTLED

### Talks to the existing gateway, no new server — *tailnet tier only*
**Amended by decision 5:** this holds for the tailnet tier. The internet-only
tier calls public APIs directly and does not involve the gateway at all.
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
