#!/usr/bin/env bash
# gh_app_mint.sh — mint a GitHub App installation token.
#
# Prints the token on STDOUT and nothing else.  Every diagnostic goes to
# STDERR, because the caller does `tok=$(scripts/gh_app_mint.sh)`.
#
# SECRET LAW: the private key is read from the environment (or from a
# file named by an environment variable) and is never echoed, logged,
# written to disk, or passed on a command line.  The PEM is piped into
# openssl through a file descriptor by openssl itself; the minted token
# lives in memory only and expires in <=1 hour.
#
# Inputs (environment):
#   GH_APP_ID                 the App id (numeric)
#   GH_APP_PRIVATE_KEY        the PEM text, inline        (one of these)
#   GH_APP_PRIVATE_KEY_FILE   path to the PEM file        (or this one)
#   GH_APP_INSTALLATION_ID    optional; when unset the script discovers
#                             the single installation of the App
#   GITHUB_API_URL            optional; defaults to https://api.github.com
#
# Exit codes: 0 minted, 2 bad input, 3 JWT/HTTP failure.
#
# Requires: bash, curl, openssl, jq (all present on GitHub runners).
set -euo pipefail

api=${GITHUB_API_URL:-https://api.github.com}

need() { [ -n "${2:-}" ] || { printf 'gh_app_mint: missing %s\n' "$1" >&2; exit 2; }; }
need GH_APP_ID "${GH_APP_ID:-}"

if [ -n "${GH_APP_PRIVATE_KEY_FILE:-}" ]; then
  [ -r "$GH_APP_PRIVATE_KEY_FILE" ] || { printf 'gh_app_mint: key file not readable\n' >&2; exit 2; }
  key_file=$GH_APP_PRIVATE_KEY_FILE
elif [ -n "${GH_APP_PRIVATE_KEY:-}" ]; then
  # Inline PEM -> a private temp file with 0600, removed on exit.
  umask 077
  key_file=$(mktemp "${TMPDIR:-/tmp}/ghappkey.XXXXXX")
  trap 'rm -f "$key_file"' EXIT
  printf '%s\n' "$GH_APP_PRIVATE_KEY" >"$key_file"
else
  printf 'gh_app_mint: missing GH_APP_PRIVATE_KEY or GH_APP_PRIVATE_KEY_FILE\n' >&2
  exit 2
fi

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

now=$(date +%s)
header=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)
payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' \
            "$((now - 60))" "$((now + 540))" "$GH_APP_ID" | b64url)
unsigned="$header.$payload"

# Sign without touching disk beyond the key itself.
sig=$(printf '%s' "$unsigned" \
      | openssl dgst -sha256 -sign "$key_file" -binary \
      | b64url)
jwt="$unsigned.$sig"

api_call() { # method path jwt [body]
  curl -sS -X "$1" "$api$2" \
    -H "Authorization: Bearer $3" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    ${4:+-d "$4"}
}

inst=${GH_APP_INSTALLATION_ID:-}
if [ -z "$inst" ]; then
  body=$(api_call GET /app/installations "$jwt") || {
    printf 'gh_app_mint: installations call failed\n' >&2; exit 3; }
  inst=$(printf '%s' "$body" | jq -r '
    if length == 0 then "none"
    elif length == 1 then .[0].id | tostring
    else ([.[].account.login] | join(",")) end')
  case $inst in
    none) printf 'gh_app_mint: the App has no installation\n' >&2; exit 3 ;;
    *,*)  printf 'gh_app_mint: several installations (%s); set GH_APP_INSTALLATION_ID\n' \
                "$inst" >&2; exit 3 ;;
  esac
fi

body=$(api_call POST "/app/installations/$inst/access_tokens" "$jwt" '{}') || {
  printf 'gh_app_mint: token mint failed\n' >&2; exit 3; }
tok=$(printf '%s' "$body" | jq -r '.token // empty')
[ -n "$tok" ] || { printf 'gh_app_mint: empty token in response\n' >&2; exit 3; }

printf '%s\n' "$tok"
