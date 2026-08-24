# AltStore

Signing route: **decided — AltStore.** This document is how the app reaches the
phone, and why the hosting choice is what it is.

## The distribution problem, and why the tailnet solves it

AltStore installs from a **source** — a JSON manifest at a URL you add in the
app. AltStore must be able to fetch two things from the phone:

1. the source JSON, and
2. the `.ipa` named in it.

That is awkward for a private repo: **GitHub release assets on a private repo
require authentication**, and AltStore sends no credentials. The usual answer is
"make the repo public", which publishes the source history permanently.

There is a better answer here, because the phone is already on the tailnet:

```
iPhone (AltStore)  ──Tailscale──▶  your-host  ──▶  Caddy  ──▶  /altstore/source.json
                                                                /altstore/Toolbelt.ipa
```

Verified on this setup:
- `your-host` — 100.x.y.z (this host, serving)
- `your-phone` — 100.x.y.z (the phone, already enrolled)
- Caddy already runs as `toolbelt-caddy`

So the repo stays **private**, nothing is exposed to the internet, and the
source is reachable exactly where it needs to be. Tailscale also issues real
certificates (`tailscale cert`), which matters because iOS App Transport
Security blocks plain `http://` — the schema test enforces `https://`.

## Serving it

`tailscale serve` is the least-moving-parts option:

```bash
# on your-host
sudo tailscale serve --bg --set-path /altstore /var/www/altstore
```

Or via the Caddy instance that is already running, if you would rather keep one
front door. Either way the files live in one directory:

```
/var/www/altstore/
  source.json          # from source/source.json
  Toolbelt.ipa         # the build artefact
  icon.png             # referenced by iconURL
```

Then in AltStore: **Browse → Sources → + → `https://<your-host-magicdns>/altstore/source.json`**

## The 7-day reality

A free Apple ID signs for **7 days**. AltStore refreshes in the background, but
only when it can reach the phone.

- **SideStore** refreshes over Wi-Fi using a pairing file — no computer needed
  after setup. Worth preferring for this reason alone.
- The phone must be able to reach the tailnet for a refresh that re-downloads.
- Free Apple IDs cap at **3 sideloaded apps**.

If the weekly refresh becomes annoying, the escape hatch is a paid developer
account (1-year signing) — and at that point TestFlight is worth comparing
against sideloading rather than assuming.

### AltStore PAL (EU)
You are in the EU, where AltStore PAL exists as a real alternative marketplace
under the DMA, without the 7-day limit. It is **not** a drop-in swap: PAL
distributes ADPs (`manifest.json` + package) rather than plain `.ipa`s, and
listing an app involves Apple's marketplace requirements. Worth investigating
if the refresh cycle grates — noted here so it is not rediscovered later.

## Cutting a release

```bash
# on the macOS runner, after the build produces build/Toolbelt-unsigned.ipa
node scripts/add-release.mjs build/Toolbelt-unsigned.ipa \
  https://<your-host-magicdns>/altstore/Toolbelt.ipa

node --test tests/source-schema.test.mjs     # validate before publishing
```

`add-release.mjs` reads `version`, `buildVersion` and `size` **out of the built
`.ipa`** rather than taking them on trust — a source that advertises a version
it does not actually serve is the most common way this breaks.

Then copy `source.json` and the `.ipa` into the served directory. AltStore
picks up `versions[0]`.

## What this app will not do

Carried from the parent repo and not up for renegotiation here:

- **No trading.** Finance is read-only. The desktop trader's arming,
  kill-switch and daily-loss guarantees hold because there is exactly one path
  to an order; a phone must not become a second one.
- **No credential vault**, no offensive bridges (Kali, hexstrike, CLI-agent).
- Gateway **safe lane only**.
