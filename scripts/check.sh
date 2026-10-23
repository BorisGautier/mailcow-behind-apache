#!/bin/bash
# Health check of the mail server: containers, ports, queue, certificates, reverse DNS, blocklists,
# DNS of every mail domain (MX, SPF, DKIM matching mailcow's key, DMARC), optional test message.
# Verification complete du serveur mail. Ne modifie rien (sauf l'envoi du message de test).
#
# Usage: sudo ./scripts/check.sh [--send-test you@gmail.com]
#   --send-test needs TEST_SMTP_USER and TEST_SMTP_PASS (an existing mailbox) in the environment.
. "$(dirname "$0")/lib.sh"
require_root
load_config
cd "$MAILCOW_DIR"
problems=0
bad() { fail "$*"; problems=$((problems + 1)); }

info "Containers"
down=$(docker compose ps -a --format '{{.Service}} {{.State}} {{.Health}}' | awk '$2 != "running" || ($3 != "" && $3 != "healthy") {print $1"("$2" "$3")"}')
total=$(docker compose ps -q | wc -l)
[ -z "$down" ] && ok "$total containers running" || bad "not running/healthy: $down"
oom=$(docker ps -a --filter "name=mailcowdockerized" --format '{{.Names}}' | xargs -r docker inspect -f '{{.Name}} {{.State.OOMKilled}}' | awk '$2 == "true" {print $1}')
[ -z "$oom" ] || bad "killed for lack of memory: $oom (raise its limit in docker-compose.override.yml)"

info "Ports"
for p in 25 465 587 993 995 143 110 4190; do
  ss -Hltn "sport = :$p" | grep -q . && ok "$p listening" || bad "$p not listening"
done

info "Mail queue"
queued=$(docker compose exec -T postfix-mailcow sh -c 'mailq | grep -c "^[A-F0-9]"' </dev/null 2>/dev/null || true)
queued=${queued:-0}
[ "${queued:-0}" -lt 20 ] && ok "$queued message(s) waiting" || bad "$queued messages waiting (docker compose exec postfix-mailcow mailq)"

info "Certificates"
for spec in "993 imap" "465 smtps" "587 smtp-starttls"; do
  read -r port kind <<< "$spec"
  if [ "$kind" = smtp-starttls ]; then opts=(-starttls smtp); else opts=(); fi
  end=$(echo | timeout 15 openssl s_client "${opts[@]}" -connect "127.0.0.1:$port" -servername "$MAIL_HOSTNAME" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || true)
  if [ -z "$end" ]; then bad "port $port: no certificate"; continue; fi
  days=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
  [ "$days" -gt 14 ] && ok "port $port valid $days more days" || bad "port $port expires in $days days (check certbot and the deploy hook)"
done

info "Reverse DNS and blocklists for $SERVER_IP"
ptr=$(qdig -x "$SERVER_IP" | sed 's/\.$//' || true)
[ "$ptr" = "$MAIL_HOSTNAME" ] && ok "PTR $ptr" || bad "PTR is '${ptr:-none}', expected $MAIL_HOSTNAME"
rev=$(echo "$SERVER_IP" | awk -F. '{print $4"."$3"."$2"."$1}')
# Spamhaus refuses queries from public resolvers: ask the system resolver
for bl in zen.spamhaus.org bl.spamcop.net b.barracudacentral.org; do
  r=$(dig +short "$rev.$bl" A | head -1 || true)
  case "$r" in
    "") ok "not listed on $bl" ;;
    127.255.255.*) warn "$bl refused the query (public/open resolver): use a local resolver to check" ;;
    *) bad "LISTED on $bl ($r)" ;;
  esac
done

info "Mail domains"
for domain in $(mailcow_api GET get/domain/all | jq -r '.[].domain_name'); do
  mx=$(qdig MX "$domain" | awk '{print $2}' | sed 's/\.$//' | tr '\n' ' ' || true)
  spf=$(qdig TXT "$domain" | tr -d '"' | grep -c 'v=spf1' || true)
  spf_ok=$(qdig TXT "$domain" | tr -d '"' | grep 'v=spf1' | grep -cE "( mx |a:$MAIL_HOSTNAME|ip4:$SERVER_IP)" || true)
  want=$(mailcow_api GET "get/dkim/$domain" | jq -r '.dkim_txt // empty' | grep -oE 'p=[A-Za-z0-9+/=]+' | tail -c 40 || true)
  have=$(qdig TXT "dkim._domainkey.$domain" | tr -d '" ' | grep -oE 'p=[A-Za-z0-9+/=]+' | tail -c 40 || true)
  dmarc=$(qdig TXT "_dmarc.$domain" | grep -c 'v=DMARC1' || true)
  line="$domain: MX=${mx:-none}"
  issues=()
  [[ " $mx " == *" $MAIL_HOSTNAME "* ]] || issues+=("MX")
  [ "$spf" = 1 ] || issues+=("SPF records: $spf (need exactly 1)")
  [ "$spf_ok" -ge 1 ] || issues+=("SPF does not allow this server")
  [ -n "$want" ] && [ "$want" = "$have" ] || issues+=("DKIM missing or different from mailcow's key")
  [ "$dmarc" -ge 1 ] || issues+=("no DMARC")
  if [ ${#issues[@]} -eq 0 ]; then ok "$line SPF DKIM DMARC"; else bad "$line -> ${issues[*]}"; fi
done

if [ "${1:-}" = --send-test ]; then
  to=${2:-}; [ -n "$to" ] || die "--send-test needs an address"
  [ -n "${TEST_SMTP_USER:-}" ] && [ -n "${TEST_SMTP_PASS:-}" ] || die "set TEST_SMTP_USER and TEST_SMTP_PASS"
  info "Test message $TEST_SMTP_USER -> $to"
  msg=$(mktemp)
  printf 'From: %s\r\nTo: %s\r\nSubject: mailcow-behind-apache test %s\r\nDate: %s\r\nMessage-ID: <%s.check@%s>\r\n\r\nTest message from %s. Reply to it to test incoming mail.\r\n' \
    "$TEST_SMTP_USER" "$to" "$(date +%F)" "$(date -R)" "$(date +%s)" "$MAIL_HOSTNAME" "$MAIL_HOSTNAME" > "$msg"
  if curl -s --url "smtp://$MAIL_HOSTNAME:587" --ssl-reqd --mail-from "$TEST_SMTP_USER" --mail-rcpt "$to" \
       --user "$TEST_SMTP_USER:$TEST_SMTP_PASS" --upload-file "$msg"; then
    ok "accepted for delivery"
    sleep 20
    docker compose logs --since 2m postfix-mailcow 2>/dev/null | grep "to=<$to>" | grep -oE 'status=[a-z]+ \(.{0,80}' | tail -1 | sed 's/^/  /'
  else bad "submission on port 587 failed"; fi
  rm -f "$msg"
fi

echo
if [ "$problems" -eq 0 ]; then echo "${c_green}All checks passed.${c_reset}"
else echo "${c_red}$problems problem(s) found.${c_reset}"; exit 1; fi
