# Roadmap

Ordered work list. Lives in the repo rather than in a chat so it survives a
lost session — anyone picking this up should be able to read this file and
continue without archaeology.

**Order is deliberate: tractable-and-verifiable first, riskiest last.** Nothing
here can be compiled in the authoring environment (Linux, no Xcode), so every
slice costs a CI round-trip. Cheap slices that land beat an ambitious one that
sits broken.

## Working rules for each slice

1. **One vertical slice at a time.** A feature that works end to end beats five
   stubbed tabs — an empty tab that looks like a feature is exactly the dead
   cosmetic UI the parent repo spent a PR deleting.
2. **Tests before or alongside, never after.** Especially for anything that
   parses untrusted input or reports a security verdict.
3. **A check that could not be performed reports UNKNOWN, never a pass.**
4. **Never assert an operation completes before a wall-clock deadline** — assert
   the condition. Three CI flakes in the parent repo came from that shape.
5. **Commit before any destructive verification** (`git checkout --`, stashing).
   Uncommitted work has been lost that way twice in this project's history.
6. CI is the compiler. Push, watch, fix. Do not claim something builds until a
   run says so.

---

## Done
- [x] Embedded gateway — typed failures (`unreachable` / `http` / `malformed` /
      `refused`), `isAnswer` so callers cannot conflate "no answer" with "404".
- [x] Domain scanner — headers, certificate transparency, DNS-over-HTTPS. Each
      check independent; unreachable yields one `unknown`, not four false
      findings.
- [x] SSH device identity — Ed25519 generated on-device, no import path,
      never syncs to iCloud.
- [x] Host-key verification — TOFU where a *changed* key is a hard failure, and
      "remember instead" needs an explicit forget.
- [x] Magnet parsing — v1/v2 hex, base32, hybrid links; `dn` treated as data.
- [x] CI: XcodeGen → build → test → unsigned `.ipa` → release on `v*` tag.

## Next, in order

### 1. In-app browser  ← cheapest real feature
`WKWebView` wrapper. Open a scan result or feed item without leaving the app.
Needs: back/forward/reload, the URL visible at all times (a browser that hides
what it is showing is a phishing aid), and no persistent cookie store by default.

### 2. RSS
Feed list + item list + open-in-browser. Reuses the gateway. Parsing untrusted
XML from arbitrary hosts, so: no entity expansion, size cap, and a malformed
feed reports as malformed rather than rendering an empty list that reads as
"no news".

### 3. Finance glance
Read-only. Watchlist + last price from public market data. **No trading, ever** —
the desktop trader's guarantees hold because there is exactly one path to an
order. Indicators shown with their numbers; no price targets, no
recommendations.

### 4. Security feeds
CVE / KEV / threat intel lists. Straight reads, same staleness discipline as
everything else.

### 5. VLC player
VLCKit is pinned by revision (its tags are not valid semver). Play a local or
remote file; background audio already declared. Landscape already enabled.

### 6. SSH transport + terminal UI  ← the key handling is already done
swift-nio-ssh for transport, a terminal view for rendering. The security layer
(identity, host keys) exists and is tested, so this sits on something correct
rather than having security retrofitted.

### 6b. Live TV from IPTV (M3U)  ← cheap, and it lands before the hard stuff
Parse an M3U/M3U8 playlist, list the channels, hand the stream URL to VLCKit —
which already speaks HLS, MPEG-TS and UDP natively, so there is nothing to
build on the playback side.

Untrusted input from a user-supplied URL, so the parser gets the same treatment
as the magnet parser: size cap, no blind trust of `tvg-logo`/`group-title`, and
a malformed playlist reports as malformed rather than rendering an empty list
that reads as "no channels".

### 7. Torrent STREAMING, not downloading  ← changed by the owner, and it is better
Originally scoped as a download manager. The owner's call: **stream into the
player like Stremio** — sequential pieces, served to VLC, watch while it
fetches.

This is a genuinely better fit for iOS, and it largely dissolves the problem
that made downloading awkward: **you are watching, so the app is in the
foreground by definition.** The background-suspension limit that would have
stalled an overnight download barely applies to a session you are actively
looking at.

Shape:

    magnet ──▶ engine (sequential piece priority) ──▶ local HTTP on 127.0.0.1
                                                              │
                                                              ▼
                                                     VLCKit plays that URL

Still the largest slice — there is no mature pure-Swift BitTorrent stack, so it
means libtorrent (C++). Deliberately last, and now with a smaller surface: no
download queue, no resume state, no storage management. A stream that plays and
is discarded is far less code than a download manager.

Still say plainly in the UI that pausing and backgrounding for a long time will
stall the stream. Stating a limitation beats a progress bar that silently
stops.

---

## Not doing (and why)

- **Trading controls** — permanently out. One path to an order.
- **Credential vault, offensive bridges (Kali/hexstrike/CLI-agent)** — out. The
  SSH terminal to your own host is a different risk class from shipping a root
  shell in a container full of offensive tooling to a device that can be lost.
- **AI chat** — v1 out; it would mean provider keys on the phone.
- **Tasks / goals / calendar / habits** — commodity, and they turn the pitch
  into "everything app". Personal-use features, not part of the public story.
- **Push notifications** — nothing can push over a tailnet you are not
  connected to, and a public push relay contradicts the no-internet-exposure
  posture. Revisit only if that trade is deliberately accepted.
