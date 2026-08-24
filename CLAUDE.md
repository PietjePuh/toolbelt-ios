# toolbelt-ios

Sideloaded iOS companion for the Developer Toolbelt (PietjePuh/Toolbelt).
Talks to the existing gateway (:3847) over Tailscale. No new server.

## Hard constraints — read before proposing anything

- **iOS builds need macOS.** This host and both self-hosted runners are Linux.
  Builds run on GitHub-hosted macOS runners; on a PRIVATE repo those bill at a
  10x minute multiplier. Do not assume a local Xcode.
- **The signing route is undecided** (AltStore/SideStore 7-day, paid dev
  account 1-year, or TrollStore). It changes distribution, not app code — but
  do not write refresh/update logic until it is chosen. See README.
- **The safe lane is the boundary.** This app may use the gateway's read-only
  actions. It must not reach the offensive bridges (Kali, hexstrike,
  CLI-agent), the credential vault, or anything that mutates security state.

## Finance guardrails — inherited, non-negotiable

The desktop auto-trader is crypto-only and gated behind: armed + kill-switch
clear + daily-loss halt clear, with a graduated live rail (20 paper cycles and
7 days before real money, first 10 orders at quarter size).

**This app is READ-ONLY for finance.** No arming, no disarming, no order
placement, no changing what the trader may trade. A phone must not become a
second, weaker path to an order. If a feature seems to need it, stop and ask.

## Working style (carried over from Toolbelt)

- **Behaviour tests, not source-regex.** Every fix ships a canary proven to
  FAIL against the pre-fix code — state how you proved it.
- **Never assert an operation completes before a wall-clock deadline.** Assert
  the condition. Three CI flakes in the parent repo came from that shape.
- **A check that could not consult its source reports UNKNOWN, never "clean".**
- **Verify before deleting.** Two "dead" controls in the parent repo turned out
  to be working features with missing CSS.
- Commit before running any destructive verification (`git checkout --`,
  stashing). Uncommitted work has been lost that way.

## Related

Parent repo: /data/Toolbelt — the extension, gateway, and 42 docker stacks.
The gateway's safe-lane action list is the API surface this app consumes.
