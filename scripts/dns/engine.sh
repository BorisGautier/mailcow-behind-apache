#!/bin/bash
# Provider-independent DNS publication for a mail domain. Sourced by 04-dns-publish.sh after lib.sh
# and after one provider file (scripts/dns/<provider>.sh) that implements:
#
#   dns_check_config            fail early when credentials are missing
#   dns_backup FILE             save the current zone (or the records we may change) to FILE
#   dns_get NAME TYPE           print the current values, one per line
#   dns_set NAME TYPE TTL V...  replace all the records NAME/TYPE by the values V...
#   dns_republish NAME TYPE     optional: force a provider to republish a record set
#
# NAME is relative to the domain ("@" for the apex). Values use zone-file syntax without quotes:
#   MX "10 mail.example.com."   SRV "0 1 993 mail.example.com."   CNAME "mail.example.com."
#   TXT the full text, unquoted (providers split values longer than 255 characters themselves)
# The domain being published is in DNS_DOMAIN.

DNS_TTL=3600

# Records of a mail domain, except the apex TXT (SPF is merged with the existing TXT values).
# Output: NAME<TAB>TYPE<TAB>VALUE, one record per line.
mail_dns_records() {
  local domain=$1 dkim=$2 h="$MAIL_HOSTNAME."
  printf '%s\t%s\t%s\n' \
    @ MX "10 $h" \
    dkim._domainkey TXT "$dkim" \
    _dmarc TXT "$(dmarc_value "$domain")" \
    _autodiscover._tcp SRV "0 1 443 $h" \
    _submissions._tcp SRV "0 1 465 $h" \
    _submission._tcp SRV "0 1 587 $h" \
    _imaps._tcp SRV "0 1 993 $h" \
    _pop3s._tcp SRV "10 1 995 $h" \
    webmail CNAME "$h" \
    mta-sts CNAME "$h" \
    _mta-sts TXT "v=STSv1; id=${MTA_STS_ID:-20261026}" \
    _smtp._tls TXT "v=TLSRPTv1; rua=mailto:${DMARC_RUA//\{domain\}/$domain}"
}

# Apex TXT values after the switch: every current value except SPF records, then our SPF.
# Input: current values on stdin (one per line). Argument: the new SPF value.
apex_txt_merge() {
  local spf=$1 v
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    case "$v" in v=spf1*) ;; *) printf '%s\n' "$v" ;; esac
  done
  printf '%s\n' "$spf"
}

# Normalise TXT values read from DNS or an API (zone presentation format):
# '"part1" "part2"' -> 'part1part2', and escaped characters such as '\/' or '\"' -> '/' '"'
txt_unquote() { sed -e 's/" "//g' -e 's/^"//' -e 's/"$//' -e 's/\\\([^0-9]\)/\1/g'; }

# SPF mechanisms of OLD that NEW no longer allows (senders that would lose the right to send).
# The qualifiers of "all" and the mechanisms of this server are ignored.
spf_dropped() {
  local old=$1 new=$2 m out=()
  for m in $old; do
    case "$m" in v=spf1|all|[~?+-]all|mx|a|"a:$MAIL_HOSTNAME") continue ;; esac
    [[ " $new " == *" $m "* ]] || out+=("$m")
  done
  echo "${out[*]}"
}

# Publish every mail record of DNS_DOMAIN. Arguments: DKIM value, "yes" to skip the MX confirmation.
dns_publish() {
  local dkim=$1 assume_yes=${2:-no} name type value backup
  local domain=$DNS_DOMAIN h="$MAIL_HOSTNAME."
  dns_check_config

  info "Backup of the current records"
  mkdir -p "${DNS_BACKUP_DIR:=/root/dns-backups}"
  chmod 700 "$DNS_BACKUP_DIR"
  backup="$DNS_BACKUP_DIR/$domain-$DNS_PROVIDER-$(date +%F-%H%M%S).json"
  dns_backup "$backup"
  ok "$backup"

  local current_mx
  current_mx=$(dns_get @ MX)
  if [ -n "$current_mx" ] && ! grep -qx "[0-9]* $h" <<< "$current_mx"; then
    warn "current MX of $domain: $(tr '\n' ' ' <<< "$current_mx")"
    warn "replacing it sends ALL new mail for $domain to this server. Create the mailboxes first,"
    warn "and copy the existing mail with imapsync (docs/en/migration.md)."
    if [ "$assume_yes" != yes ] && [ "$DNS_PROVIDER" != manual ]; then
      local a; read -r -p "Replace the MX now? [y/N] " a
      [[ "$a" =~ ^[yYoO] ]] || die "aborted, nothing changed (backup: $backup)"
    fi
  fi

  local current_txt old_spf dropped
  current_txt=$(dns_get @ TXT)
  old_spf=$(grep -m1 '^v=spf1' <<< "$current_txt" || true)
  dropped=$(spf_dropped "$old_spf" "$(spf_value)")
  if [ -n "$dropped" ]; then
    warn "the current SPF of $domain also allows: $dropped"
    warn "with the new SPF they can no longer send as @$domain (newsletters, forms, SaaS...)."
    warn "To keep them: --spf-extra \"$dropped\" (or SPF_EXTRA in config.env). Old mail provider: drop it."
    if [ "$assume_yes" != yes ] && [ "$DNS_PROVIDER" != manual ]; then
      local s; read -r -p "Drop them from the SPF? [y/N] " s
      [[ "$s" =~ ^[yYoO] ]] || die "aborted, nothing changed (backup: $backup)"
    fi
  fi

  info "Publishing ($DNS_PROVIDER)"
  local -a apex
  mapfile -t apex < <(apex_txt_merge "$(spf_value)" <<< "$current_txt")
  dns_set @ TXT "$DNS_TTL" "${apex[@]}" && ok "@ TXT (SPF + $((${#apex[@]} - 1)) other value(s) kept)"
  while IFS=$'\t' read -r name type value; do
    dns_set "$name" "$type" "$DNS_TTL" "$value" && ok "$name $type"
  done < <(mail_dns_records "$domain" "$dkim")
  # shellcheck disable=SC2034  # read by 04-dns-publish.sh
  DNS_LAST_BACKUP=$backup
}

# Check on the authoritative servers that the records are served. Retries once through
# dns_republish when the provider defines it (Gandi sometimes keeps serving old TXT values).
dns_verify() {
  local domain=$DNS_DOMAIN ns attempt missing
  ns=$(dig +short NS "$domain" | head -1)
  [ -n "$ns" ] || { warn "no NS found for $domain"; return 1; }
  info "Checking on $ns"
  for attempt in 1 2 3; do
    missing=()
    dig +short TXT "$domain" @"$ns" | txt_unquote | grep -qxF "$(spf_value)" || missing+=("@ TXT")
    dig +short TXT "dkim._domainkey.$domain" @"$ns" | txt_unquote | grep -q "^v=DKIM1" || missing+=("dkim._domainkey TXT")
    dig +short TXT "_dmarc.$domain" @"$ns" | txt_unquote | grep -q "^v=DMARC1" || missing+=("_dmarc TXT")
    dig +short MX "$domain" @"$ns" | grep -q " $MAIL_HOSTNAME\.$" || missing+=("@ MX")
    [ ${#missing[@]} -eq 0 ] && { ok "MX, SPF, DKIM and DMARC served by $ns"; return 0; }
    [ "$attempt" = 3 ] && break
    if [ "$attempt" = 1 ] && declare -F dns_republish >/dev/null; then
      warn "not served yet: ${missing[*]} - asking $DNS_PROVIDER to republish"
      local r; for r in "${missing[@]}"; do dns_republish "${r% *}" "${r#* }"; done
    fi
    sleep 30
  done
  fail "still not served by $ns: ${missing[*]} (propagation can take a few minutes; then run check.sh)"
  return 1
}
