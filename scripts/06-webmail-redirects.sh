#!/bin/bash
# webmail.<client domain> -> https://MAIL_HOSTNAME/ (one shared webmail, each client keeps an address
# with their own name). Needs "webmail.<domain> CNAME MAIL_HOSTNAME." in each client's DNS.
# webmail.<domaine client> redirige vers le webmail central.
#
# Usage: sudo ./scripts/06-webmail-redirects.sh example.org [example.net ...]
. "$(dirname "$0")/lib.sh"
require_root
load_config
[ $# -gt 0 ] || die "usage: $0 <domain> [domain...]"

site=/etc/apache2/sites-available/mailcow-webmail-redirects.conf
names=()
# keep the domains already configured
if [ -f "$site" ]; then
  read -r -a names <<< "$(grep -m1 '^# domains:' "$site" | cut -d: -f2-)"
fi
for d in "$@"; do [[ " ${names[*]} " == *" webmail.$d "* ]] || names+=("webmail.$d"); done

info "DNS"
ready=()
for n in "${names[@]}"; do
  if [ "$(qdig A "$n" | tail -1)" = "$SERVER_IP" ]; then ready+=("$n"); ok "$n"
  else warn "$n does not resolve to $SERVER_IP yet: skipped (add the CNAME, then run again)"; fi
done
[ ${#ready[@]} -gt 0 ] || die "no name resolves here"

info "Certificate (cert name: mailcow-webmail-redirects)"
args=(); for n in "${ready[@]}"; do args+=(-d "$n"); done
cat > "$site" <<V
# domains: ${names[*]}
<VirtualHost *:80>
    ServerName ${ready[0]}
    ServerAlias ${ready[*]}
    Redirect permanent / https://$MAIL_HOSTNAME/
</VirtualHost>
V
a2ensite -q "$(basename "$site")"; systemctl reload apache2
certbot certonly --apache --non-interactive --agree-tos -m "$CERTBOT_EMAIL" \
  --cert-name mailcow-webmail-redirects --expand "${args[@]}"

cat >> "$site" <<V

<IfModule mod_ssl.c>
<VirtualHost *:443>
    ServerName ${ready[0]}
    ServerAlias ${ready[*]}
    Redirect permanent / https://$MAIL_HOSTNAME/
    SSLEngine On
    SSLCertificateFile /etc/letsencrypt/live/mailcow-webmail-redirects/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/mailcow-webmail-redirects/privkey.pem
</VirtualHost>
</IfModule>
V
apache2ctl configtest && systemctl reload apache2
for n in "${ready[@]}"; do
  loc=$(curl -s -o /dev/null -w '%{redirect_url}' -m 15 "https://$n/" || true)
  [ "$loc" = "https://$MAIL_HOSTNAME/" ] && ok "https://$n -> $loc" || fail "https://$n -> ${loc:-no redirect}"
done
