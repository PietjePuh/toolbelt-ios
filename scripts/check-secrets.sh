#!/usr/bin/env bash
# Refuse to add a secret to a PUBLIC repository.
#
# GitHub's push protection now covers this repo and catches KNOWN provider
# tokens — AWS, Stripe, GitHub, and so on. This gate covers what it cannot
# know about, which is everything specific to this project:
#
#   - IPTV playlist URLs, which carry the subscription username and password
#     in the query string. There is no provider pattern for that.
#   - A TMDB read token, which is a bare JWT with no distinguishing prefix.
#   - Any private key that ends up in a fixture.
#
# A public repository is permanent: a secret pushed here is a secret published,
# and deleting the commit does not unpublish it. So this fails the build rather
# than warning.
set -euo pipefail

base="${1:-origin/main}"

if ! diff=$(git diff --unified=0 "${base}...HEAD" 2>/dev/null); then
  # Same rule as the lockfile gate: a check that could not run must not pass.
  echo "::error::could not diff against ${base} — refusing to report clean"
  exit 1
fi

added=$(printf '%s\n' "$diff" | grep -E '^\+' | grep -v '^\+\+\+' || true)
if [ -z "$added" ]; then
  echo "[secrets] nothing added — nothing to check"
  exit 0
fi

fail=0
report() {
  echo "::error::possible secret added — $1"
  printf '%s\n' "$2" | head -3 | sed 's/^/    /'
  fail=1
}

# Credentials in a URL query string. The IPTV case, and the one most likely to
# arrive by copy-paste from a provider email.
#
# The placeholder test is applied to the VALUE, never to the whole line. The
# first version excluded any line containing "example" — which exempted every
# credential on an example.com-style host, i.e. exactly the shape a real
# provider URL has. A whole-line exclusion means one innocent word anywhere
# disables the check for that line.
if pairs=$(printf '%s\n' "$added" | grep -oiE '[?&](password|passwd|pwd|username|user|token|api_key|apikey|secret|auth)=[A-Za-z0-9._%-]{3,}' || true); [ -n "$pairs" ]; then
  if hits=$(printf '%s\n' "$pairs" | while IFS= read -r pair; do
      value="${pair#*=}"
      # Only an obviously fake VALUE is allowed through.
      case "$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" in
        redacted|placeholder|your-*|your_*|xxx*|changeme|todo|none|null|test|example|dummy|foo|bar) ;;
        *) printf '%s\n' "$pair" ;;
      esac
    done); [ -n "$hits" ]; then
    report "credentials in a URL query string" "$hits"
  fi
fi

# Private keys of any flavour.
if hits=$(printf '%s\n' "$added" | grep -E 'BEGIN [A-Z ]*PRIVATE KEY' || true); [ -n "$hits" ]; then
  report "a private key" "$hits"
fi

# Bare JWTs — how a TMDB read token looks.
if hits=$(printf '%s\n' "$added" | grep -E 'eyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{10,}' | grep -viE 'example|redact|placeholder' || true); [ -n "$hits" ]; then
  report "a JWT" "$hits"
fi

# Credentials in the authority: https://user:pass@host
if hits=$(printf '%s\n' "$added" | grep -iE 'https?://[A-Za-z0-9._%-]+:[A-Za-z0-9._%-]{3,}@' | grep -viE 'redact|placeholder|example|user:pass' || true); [ -n "$hits" ]; then
  report "credentials in a URL authority" "$hits"
fi

if [ "$fail" -ne 0 ]; then
  echo ""
  echo "This repository is PUBLIC. A secret pushed here is published, and"
  echo "deleting the commit does not unpublish it — it has to be revoked."
  echo ""
  echo "If this is a false positive, make the placeholder obvious (REDACTED,"
  echo "your-key-here) rather than loosening the pattern."
  exit 1
fi

echo "[secrets] no credentials in the added lines"
