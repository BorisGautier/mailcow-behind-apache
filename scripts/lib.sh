#!/bin/bash
# Shared helpers, sourced by every script.
# shellcheck disable=SC2034  # variables are used by the scripts that source this file

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$REPO_DIR/config.env}"

c_red=$'\e[31m'; c_green=$'\e[32m'; c_yellow=$'\e[33m'; c_bold=$'\e[1m'; c_reset=$'\e[0m'
[ -t 1 ] || { c_red=; c_green=; c_yellow=; c_bold=; c_reset=; }

info() { echo "${c_bold}==>${c_reset} $*"; }
ok()   { echo "  ${c_green}OK${c_reset}   $*"; }
warn() { echo "  ${c_yellow}WARN${c_reset} $*"; }
fail() { echo "  ${c_red}FAIL${c_reset} $*"; }
die()  { echo "${c_red}error:${c_reset} $*" >&2; exit 1; }

require_root() { [ "$(id -u)" -eq 0 ] || die "run as root"; }

load_config() {
  [ -f "$CONFIG_FILE" ] || die "missing $CONFIG_FILE - copy config.example.env to config.env and edit it"
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
  local v
  for v in MAIL_HOSTNAME SERVER_IP TIMEZONE MAILCOW_DIR MAILCOW_HTTP_PORT MAILCOW_HTTPS_PORT MAILCOW_IPV4_NETWORK CERTBOT_EMAIL; do
    [ -n "${!v:-}" ] || die "$v is not set in $CONFIG_FILE"
  done
  case "$MAIL_HOSTNAME" in *example.com) die "MAIL_HOSTNAME still has the example value";; esac
  MAILCOW_ENABLE_IPV6="${MAILCOW_ENABLE_IPV6:-false}"
  MAILCOW_SKIP_CLAMD="${MAILCOW_SKIP_CLAMD:-n}"
  APPLY_RESOURCE_LIMITS="${APPLY_RESOURCE_LIMITS:-yes}"
  DMARC_POLICY="${DMARC_POLICY:-none}"
  DMARC_RUA="${DMARC_RUA:-postmaster@{domain\}}"
  SPF_EXTRA="${SPF_EXTRA:-}"
  CREDENTIALS_FILE="${CREDENTIALS_FILE:-/root/mailcow-mailboxes.txt}"
  GANDI_PAT="${GANDI_PAT:-}"
}

# Set KEY=VALUE in mailcow.conf (replace or append)
set_mailcow_conf() {
  local key=$1 value=$2 file="$MAILCOW_DIR/mailcow.conf"
  if grep -q "^$key=" "$file"; then
    sed -i "s|^$key=.*|$key=$value|" "$file"
  else
    echo "$key=$value" >> "$file"
  fi
}

# Read a value from mailcow.conf
mailcow_conf() { grep "^$1=" "$MAILCOW_DIR/mailcow.conf" | head -1 | cut -d= -f2-; }

# Call the mailcow API from the host (API_ALLOW_FROM must contain 127.0.0.1)
#   mailcow_api GET  get/domain/all
#   mailcow_api POST add/domain '{"domain":"..."}'
mailcow_api() {
  local method=$1 path=$2 body=${3:-}
  local key; key=$(mailcow_conf API_KEY)
  [ -n "$key" ] || die "API_KEY is empty in mailcow.conf (run 01-install-mailcow.sh first)"
  curl -sk -m 60 -X "$method" \
    -H "X-API-Key: $key" -H "Content-Type: application/json" -H "Host: $MAIL_HOSTNAME" \
    "https://127.0.0.1:$MAILCOW_HTTPS_PORT/api/v1/$path" ${body:+-d "$body"}
}

# Random password without characters that break shells or URLs
gen_password() { openssl rand -base64 32 | tr -d '/+=' | cut -c1-"${1:-20}"; }

# dig wrapper with a public resolver, so results are not polluted by local caches
qdig() { dig +short @1.1.1.1 "$@"; }
