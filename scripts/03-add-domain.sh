#!/bin/bash
# Adds a mail domain to mailcow, generates its DKIM key and prints the DNS records to publish.
# With an API provider in DNS_PROVIDER (gandi, cloudflare, lexicon), offers to publish them (04-dns-publish.sh).
# Ajoute un domaine a mailcow, genere sa cle DKIM et affiche les enregistrements DNS a publier.
#
# Usage: sudo ./scripts/03-add-domain.sh example.org [--max-mailboxes 20] [--quota-mb 10240]
. "$(dirname "$0")/lib.sh"
require_root
load_config

domain=${1:-}; [ -n "$domain" ] || die "usage: $0 <domain> [--max-mailboxes N] [--quota-mb N]"
shift
max_mailboxes=20; quota_mb=10240
while [ $# -gt 0 ]; do
  case $1 in
    --max-mailboxes) max_mailboxes=$2; shift 2 ;;
    --quota-mb) quota_mb=$2; shift 2 ;;
    *) die "unknown option $1" ;;
  esac
done
[ "$domain" != "$MAIL_HOSTNAME" ] || die "use a domain (example.org), not the server hostname"

info "Domain $domain"
if mailcow_api GET "get/domain/$domain" | jq -e '.domain_name? // empty' >/dev/null; then
  ok "already exists"
else
  body=$(jq -nc --arg d "$domain" --argjson m "$max_mailboxes" --argjson q "$quota_mb" \
    '{domain:$d, description:$d, aliases:400, mailboxes:$m, defquota:3072, maxquota:$q, quota:$q, active:1, restart_sogo:1}')
  mailcow_api POST add/domain "$body" | jq -r '.[] | "  \(.type): \(.msg | tostring)"'
fi

info "DKIM key (selector dkim, 2048 bits)"
if [ -z "$(mailcow_api GET "get/dkim/$domain" | jq -r '.dkim_txt // empty')" ]; then
  mailcow_api POST add/dkim "$(jq -nc --arg d "$domain" '{domains:$d, dkim_selector:"dkim", key_size:2048}')" \
    | jq -r '.[] | "  \(.type): \(.msg | tostring)"'
fi
dkim=$(mailcow_api GET "get/dkim/$domain" | jq -r '.dkim_txt // empty')
[ -n "$dkim" ] || die "could not read the DKIM key of $domain"
ok "ready"

spf=$(spf_value)
dmarc=$(dmarc_value "$domain")

cat <<EOF

${c_bold}DNS records for $domain${c_reset} (zone file syntax, TTL 3600 is fine):

  @                     MX     10 $MAIL_HOSTNAME.
  @                     TXT    "$spf"
  dkim._domainkey       TXT    "$dkim"
  _dmarc                TXT    "$dmarc"
  _autodiscover._tcp    SRV    0 1 443 $MAIL_HOSTNAME.
  _submissions._tcp     SRV    0 1 465 $MAIL_HOSTNAME.
  _submission._tcp      SRV    0 1 587 $MAIL_HOSTNAME.
  _imaps._tcp           SRV    0 1 993 $MAIL_HOSTNAME.
  _pop3s._tcp           SRV    10 1 995 $MAIL_HOSTNAME.
  webmail               CNAME  $MAIL_HOSTNAME.     (optional, see 06-webmail-redirects.sh)

Notes:
  - Keep ONE SPF record only: merge "$spf" with any existing "v=spf1" TXT of the domain.
  - The DKIM value is longer than 255 characters: most DNS panels split it automatically;
    in a raw zone file write it as several quoted strings.
  - Start with DMARC p=none, read the reports for a few weeks, then move to quarantine/reject.
  - Users set up mail clients with: server $MAIL_HOSTNAME, IMAP 993 (SSL), SMTP 587 (STARTTLS) or 465 (SSL),
    username = full email address.
EOF

echo
if [ "$DNS_PROVIDER" = manual ]; then
  echo "To get these records merged with the existing ones of $domain (single SPF, other TXT kept) as a"
  echo "zone snippet, or to publish them through an API: ./scripts/04-dns-publish.sh $domain [--provider NAME]"
else
  read -r -p "Publish these records now through $DNS_PROVIDER? [y/N] " answer
  if [[ "$answer" =~ ^[yYoO] ]]; then "$REPO_DIR/scripts/04-dns-publish.sh" "$domain"; fi
fi
echo
echo "Next: create mailboxes with ./scripts/05-add-mailbox.sh contact@$domain \"Contact\""
