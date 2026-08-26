#!/usr/bin/env bash
# Refuse `gh pr merge` while any check on that PR is not green.
#
# WHY THIS AND NOT BRANCH PROTECTION
# Branch protection and rulesets both need GitHub Pro on a private repo; this
# repo is private on Free and GitHub returns 403 for both. This does the same
# job one layer earlier, in the client, so the plan is irrelevant.
#
# WHAT IT PREVENTS
# PRs merged on "CI is green" without reading the GitGuardian result sitting in
# the same check list. A person skims a wall of checks; this does not.
#
# FAILS CLOSED. Its first version used a python one-liner with `2>/dev/null`;
# a SyntaxError in it produced an empty result, which read as "no failing
# checks" and passed a PR with ten red ones. Any step that cannot produce a
# verdict now blocks instead.
set -uo pipefail

payload=$(cat)

cmd=$(printf '%s' "$payload" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if d.get("tool_name") == "Bash":
    print(d.get("tool_input", {}).get("command", ""))')

case "$cmd" in
  *"gh pr merge"*) ;;
  *) exit 0 ;;
esac

pr=$(printf '%s' "$cmd" | grep -oE 'gh pr merge[[:space:]]+[0-9]+' | grep -oE '[0-9]+$' || true)
repo=$(printf '%s' "$cmd" | grep -oE '\-R[[:space:]]+[^[:space:]]+' | awk '{print $2}' || true)

args=()
[ -n "$pr" ] && args+=("$pr")
[ -n "$repo" ] && args+=(-R "$repo")

# One call, jq only — no second interpreter to fail silently. A check with
# neither conclusion nor status counts as UNKNOWN, which is not green.
if ! bad=$(gh pr view "${args[@]}" --json statusCheckRollup --jq '
    [ .statusCheckRollup[]?
      | {name: .name,
         result: (if (.conclusion // "") != "" then .conclusion
                  elif (.status // "") != "" then .status
                  else "NO RESULT YET" end)}
      | select(.result != "SUCCESS" and .result != "NEUTRAL" and .result != "SKIPPED")
      | "  \(.name): \(.result)"
    ] | join("\n")' 2>&1); then
  echo "merge-guard: could not read this PR's checks (${bad}). Refusing — an unverifiable state is not a pass." >&2
  exit 2
fi

if [ -n "$bad" ]; then
  {
    echo "merge-guard: refusing to merge — these checks are not green:"
    echo "$bad"
    echo ""
    echo "Read each one. A green CI job is not the same as every check passing;"
    echo "GitGuardian and Semgrep sit in this same list and have been skimmed past before."
  } >&2
  exit 2
fi

exit 0
