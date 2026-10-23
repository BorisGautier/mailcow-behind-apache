#!/bin/bash
# Creates a mailbox with a random password, saved in CREDENTIALS_FILE (root only).
# Cree une boite avec un mot de passe aleatoire, enregistre dans CREDENTIALS_FILE (root seulement).
#
# Usage: sudo ./scripts/05-add-mailbox.sh user@example.org "Display Name" [quota-MB] [--force-password-change]
. "$(dirname "$0")/lib.sh"
require_root
load_config

address=${1:-}; name=${2:-}; quota=${3:-3072}; force=0
[ "${4:-}" = --force-password-change ] && force=1
[[ "$address" == *@*.* ]] && [ -n "$name" ] || die "usage: $0 user@domain \"Display Name\" [quota-MB] [--force-password-change]"
local_part=${address%@*}; domain=${address#*@}

mailcow_api GET "get/domain/$domain" | jq -e '.domain_name? // empty' >/dev/null \
  || die "domain $domain does not exist in mailcow: run 03-add-domain.sh $domain first"
if mailcow_api GET "get/mailbox/$address" | jq -e '.username? // empty' >/dev/null; then
  ok "$address already exists (password unchanged)"; exit 0
fi

password=$(gen_password 20)
body=$(jq -nc --arg l "$local_part" --arg d "$domain" --arg n "$name" --arg p "$password" \
  --argjson q "$quota" --argjson f "$force" \
  '{local_part:$l, domain:$d, name:$n, password:$p, password2:$p, quota:$q, active:1, force_pw_update:$f, tls_enforce_in:0, tls_enforce_out:0}')
result=$(mailcow_api POST add/mailbox "$body")
if echo "$result" | jq -e 'any(.[]; .msg[0] == "mailbox_added")' >/dev/null; then
  umask 077
  echo "$address $password" >> "$CREDENTIALS_FILE"
  ok "$address created (${quota} MB). Password saved in $CREDENTIALS_FILE"
  [ "$force" = 1 ] && echo "  The user must choose a new password at first login (https://$MAIL_HOSTNAME)."
else
  die "mailcow refused: $(echo "$result" | jq -c '[.[] | .msg]')"
fi
