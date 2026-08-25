# Installing

There is no App Store listing. You install this yourself, which is why it can
have a domain scanner and a real terminal at all — and why nothing you do in it
reaches anyone else's server.

Two routes. **Route A needs no computer after setup** and is what most people
should use.

---

## What you need either way

- An **iPhone/iPad on iOS 17 or later**.
- A **free Apple ID**. No paid developer account.
- **~10 minutes**, once.

> **The 7-day thing, up front:** apps signed with a free Apple ID stop opening
> after 7 days unless they are refreshed. SideStore does this automatically over
> Wi-Fi, so in practice you rarely notice — but if you leave it untouched for a
> fortnight, it will need a refresh before it opens. A paid Apple Developer
> account (€99/yr) raises that to a year. Free Apple IDs also cap you at
> **3 sideloaded apps** at once.

---

## Route A — SideStore (recommended)

SideStore refreshes over Wi-Fi with no computer involved after the first setup.

1. **Install SideStore** — follow <https://sidestore.io>. It walks you through
   pairing your device once (you need a computer for that single step) and
   installs the SideStore app itself.
2. **Download the build.** Grab `Toolbelt-unsigned.ipa` from the
   [Releases page](../../releases) of this repo.

   > If Releases is empty, no tagged build exists yet. Use Route C (build it
   > yourself) for now — the release is cut from a `v*` tag, so there is
   > deliberately nothing there until one is tagged, rather than a stale
   > artifact pretending to be current.
3. **Open SideStore → `+` → pick the `.ipa`.** Sign in with your Apple ID when
   asked. That Apple ID is sent to *Apple*, not to anyone else — SideStore signs
   the app locally on your device.
4. **Trust the certificate.** Settings → General → VPN & Device Management →
   tap your Apple ID → Trust. iOS will not open the app until you do.
5. Open Toolbelt.

To update: download the newer `.ipa` and repeat step 3.

---

## Route B — AltStore Classic

Same idea, but refreshes need your computer on the same Wi-Fi.

1. Install AltServer on a Mac or PC from <https://altstore.io>, then AltStore on
   the device.
2. Download `Toolbelt-unsigned.ipa` from [Releases](../../releases).
3. AltStore → **My Apps** → `+` → choose the `.ipa`.
4. Trust the certificate as in step 4 above.

---

## Route C — build it yourself

If you would rather not trust a binary, build from source. **Requires a Mac**
with Xcode; there is no supported way to produce an `.ipa` on Linux or Windows.

```bash
git clone https://github.com/PietjePuh/toolbelt-ios
cd toolbelt-ios
brew install xcodegen
xcodegen generate          # project.yml is the source of truth
open Toolbelt.xcodeproj
```

Plug in your device, pick it as the run destination, set your own Signing team
in **Signing & Capabilities**, and hit Run. Xcode will sign it with your free
Apple ID.

---

## After installing

Everything works immediately with no account and no configuration — the app
carries its own gateway, so there is nothing to point it at.

**Optional:** if you run the [Developer Toolbelt](https://github.com/PietjePuh/Toolbelt)
on a Linux box, you can point the app at it over Tailscale to add local service
health and the alert inbox. That is entirely optional; the app is fully usable
without it.

---

## Troubleshooting

**"Unable to Verify App" / it will not open.**
You skipped the Trust step, or the 7 days elapsed. Refresh it in
SideStore/AltStore, then Trust again if prompted.

**"Maximum number of apps installed".**
A free Apple ID allows 3 sideloaded apps. Remove one.

**The scanner says "unknown" for everything.**
That means the checks could not be performed — no connectivity, or the host is
not answering. It deliberately does **not** show a pass in that case: an unknown
result is reported as unknown, never as "looks fine".

**It stopped working after a week and I was away from Wi-Fi.**
Expected on a free Apple ID. Reconnect and refresh.

---

## TestFlight (paid Apple Developer account, no computer needed)

The AltStore route above needs AltServer on a computer on the same Wi-Fi — to
install *and* to re-sign every 7 days. With a **paid** developer account none of
that applies: TestFlight installs directly on the device and builds last **90
days**.

Everything below can be done from a phone browser.

### One-time setup

1. **Create an App Store Connect API key.**
   appstoreconnect.apple.com → *Users and Access* → *Integrations* → *Keys* →
   `+`. Give it the **App Manager** role — it needs that to register the bundle
   ID on the first run. Download the `.p8`. **Apple lets you download it once.**

2. **Note three values** from that page: the **Key ID**, the **Issuer ID**
   (above the key list), and your **Team ID** from *Membership details*.

3. **Base64-encode the `.p8`.** On a phone the simplest way is a shortcut or
   any base64 tool; on a computer it is `base64 -i AuthKey_XXXX.p8`.

4. **Add four repository secrets** — GitHub → Settings → Secrets and variables
   → Actions:

   | Secret | Value |
   |---|---|
   | `ASC_KEY_ID` | the Key ID |
   | `ASC_ISSUER_ID` | the Issuer ID |
   | `ASC_KEY_P8` | the base64 of the `.p8` |
   | `APPLE_TEAM_ID` | the 10-character Team ID |

   No certificate or provisioning profile is stored in the repo. `xcodebuild
   -allowProvisioningUpdates` creates and renews them on the runner, and the
   key is deleted from the runner at the end of the job.

### Every build after that

GitHub → **Actions** → **TestFlight** → *Run workflow*. Then on the phone:
install **TestFlight** from the App Store, sign in with the Apple ID that is on
your App Store Connect team, and the build appears once processing finishes
(usually 5–15 minutes).

**Internal testing only, deliberately.** Internal testers are people already on
your team, and their builds are **not reviewed** — so a build is installable
minutes after upload. External testing would mean Apple review, which is a
separate decision.

### Which route to use

| | AltStore | TestFlight |
|---|---|---|
| Computer needed | Yes, to install and to refresh | No |
| Expires after | 7 days (free) / 1 year (paid) | 90 days |
| Apple review | None | None, for internal testers |
| Setup | AltServer + USB once | Four secrets, once |
