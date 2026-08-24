# toolbelt-ios

A security + finance app that runs entirely on **your** device, with **your**
keys, over **your** connection.

Most apps in this space wrap a single provider — one exchange, one scanner, one
feed. This one puts many behind a single gateway, and **that gateway ships
inside the app**. There is no server to sign up for and no account to create,
because there is no service: nothing you do here reaches anyone else's
infrastructure.

Optionally, point it at a self-hosted gateway on a Linux box if you want the
full [Developer Toolbelt](https://github.com/PietjePuh/Toolbelt) setup behind
it.

Status: **early**. The gateway and domain scanner are written; finance, RSS,
security feeds and the terminal are not yet. See `docs/DECISIONS.md` for what
was decided and why.

## Install

**[→ Installation instructions](docs/INSTALL.md)** — free Apple ID, no paid
developer account, ~10 minutes. Or build it yourself from source.

## What it does

- **Finance** — watchlist and portfolio glance from public market data.
  Read-only, always: no trading, no order placement, no account linking.
- **RSS** — your feeds.
- **Domain scanner** — DNS, subdomains, certificate transparency, security
  headers. Runs from your device, over your connection.
- **In-app browser** — open what you find without leaving the app.
- **Security feeds** — CVE / KEV / threat intel.

### Not here, by design
- **No trading controls.** Ever. Market data is displayed, never acted on.
- **No AI chat in v1** — it would mean storing provider keys on the phone.
- **No telemetry, no analytics, no account.** There is nowhere for data to go.

## Why your keys stay yours

Every request originates from your device. API keys live in the iOS Keychain
and are never transmitted anywhere except to the provider they belong to. The
author operates no infrastructure and receives nothing — which is a design
choice, not a promise you have to take on trust: read the code.

### On the domain scanner
Only scan hosts you own or are authorised to test. Scans originate from **your**
connection and are attributable to you.

### On the finance features
Indicators are shown with their underlying numbers so you can check them. There
are no price targets, no buy/sell recommendations, and nothing here is
financial advice.

---

## Before you can build — the honest constraints

**1. iOS builds require macOS.** There is no supported way to produce an `.ipa`
on Linux. This host is Linux, and both self-hosted CI runners (`kali-toolbelt`,
`titan-toolbelt`) are Linux. So builds run on **GitHub-hosted macOS runners**.

> Cost note: macOS minutes bill at a **10× multiplier** on private repos. This
> repo is private. Public repos get macOS minutes free. Flipping this repo to
> public is a one-click change; the reverse is not, so it starts private.

**2. Sideloading needs a signing route, and they are not equivalent.** Pick one
before writing much code — it changes the refresh story, not the app code:

| route | Apple account | app lifetime | notes |
|---|---|---|---|
| **AltStore / SideStore** | free Apple ID | **7 days**, auto-refreshed | SideStore refreshes over Wi-Fi via a pairing file; no PC needed after setup. 3-app limit on free IDs. |
| **Apple Developer Program** | paid, €99/yr | **1 year** | No weekly refresh. Also unlocks TestFlight, which is arguably a nicer distribution path than sideloading at all. |
| **TrollStore** | none | permanent | Only on exploitable iOS versions. Check your device's iOS against the TrollStore compatibility list before counting on this. |

**3. Decide before building, not after:** if the answer is "paid developer
account", TestFlight may be a better fit than sideloading and this repo's CI
should produce a signed archive instead of an unsigned `.ipa`.

---

## What it is meant to do

Extend the Toolbelt's reach to the phone, over the tailnet:

- **Local services** — status of the docker stacks (from `stack-catalog.json`),
  with the lifecycle verdicts added in Toolbelt #3881.
- **Alert inbox** — the unified feed (~14 sensors) that already exists in the
  extension.
- **Finance, read-only** — watchlist and portfolio glance. **No trading
  controls.** The auto-trader is crypto-only, gated behind arming, a
  kill-switch and a daily-loss halt on the desktop side; a phone app must not
  become a second, weaker path to an order.
- **Gateway command** — the safe lane the gateway already exposes (10 read-only
  actions). Not the offensive tooling.

### Deliberately out of scope
- Anything that arms, disarms or places a trade.
- Credential/vault access. The Toolbelt vault stays on the desktop.
- The offensive bridges (Kali, hexstrike, CLI-agent runner).

## Architecture sketch

```
iPhone (SwiftUI)  ──Tailscale──▶  toolbelt gateway :3847
                                    │
                                    └── existing safe-lane actions
```

No new server. It talks to the gateway that already exists, which is why the
safe lane's boundaries matter more than the app's own UI.

## Getting started

```bash
gh repo clone PietjePuh/toolbelt-ios && cd toolbelt-ios
claude          # start a Claude Code session here
```

## Layout

```
App/            SwiftUI sources
.github/        macOS build workflow (unsigned .ipa artifact)
docs/           decisions worth writing down
```
