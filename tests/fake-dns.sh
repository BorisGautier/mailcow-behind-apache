#!/bin/bash
# In-memory DNS provider for the tests (and the smallest example of a provider, see docs/en/dns-providers.md).
# Each record set is a file "$FAKE_DNS_DIR/<name>__<type>" holding one value per line.

dns_check_config() { [ -d "${FAKE_DNS_DIR:?}" ]; }

dns_backup() {
  local f
  for f in "$FAKE_DNS_DIR"/*__*; do
    [ -e "$f" ] || continue
    # shellcheck disable=SC2094  # jq writes to stdout, not to $f
    jq -Rn --arg rr "$(basename "$f")" '{rrset: $rr, values: [inputs]}' < "$f"
  done | jq -s . > "$1"
}

dns_get() { cat "$FAKE_DNS_DIR/${1}__$2" 2>/dev/null || true; }

dns_set() { # NAME TYPE TTL VALUE...
  local name=$1 type=$2
  shift 3
  printf '%s\n' "$@" > "$FAKE_DNS_DIR/${name}__$type"
}
