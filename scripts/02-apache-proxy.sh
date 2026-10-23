#!/bin/bash
# Puts mailcow behind the existing Apache: vhost, Let's Encrypt certificate (certbot), and a
# deploy hook that copies every renewed certificate into mailcow (SMTP/IMAP/POP use it too).
# Met mailcow derriere l'Apache existant : vhost, certificat certbot, hook de copie vers mailcow.
#
# Usage: sudo ./scripts/02-apache-proxy.sh
. "$(dirname "$0")/lib.sh"
require_root
load_config

domain_base=${MAIL_HOSTNAME#*.}
site=/etc/apache2/sites-available/mailcow-$MAIL_HOSTNAME.conf
hook=/etc/letsencrypt/renewal-hooks/deploy/mailcow.sh

info "Apache modules"
a2enmod -q proxy proxy_http proxy_wstunnel ssl headers rewrite

info "Certificate for $MAIL_HOSTNAME (+ autodiscover/autoconfig if they resolve here)"
names=(-d "$MAIL_HOSTNAME")
for n in "autodiscover.$domain_base" "autoconfig.$domain_base"; do
  if [ "$(qdig A "$n" | tail -1)" = "$SERVER_IP" ]; then names+=(-d "$n"); ok "$n resolves here"
  else warn "$n does not resolve to $SERVER_IP: left out of the certificate (add a CNAME and run this script again)"; fi
done
if [ ! -d "/etc/letsencrypt/live/$MAIL_HOSTNAME" ]; then
  # Temporary HTTP-only vhost so that certbot --apache can answer the challenge
  cat > "$site" <<V
<VirtualHost *:80>
    ServerName $MAIL_HOSTNAME
</VirtualHost>
V
  a2ensite -q "$(basename "$site")" && systemctl reload apache2
fi
certbot certonly --apache --non-interactive --agree-tos -m "$CERTBOT_EMAIL" \
  --cert-name "$MAIL_HOSTNAME" --expand "${names[@]}"

info "Virtual host $site"
render_apache_vhost > "$site"
a2ensite -q "$(basename "$site")"
apache2ctl configtest
systemctl reload apache2
ok "enabled"

info "Deploy hook $hook"
mkdir -p "$(dirname "$hook")"
render_deploy_hook > "$hook"
chmod 755 "$hook"
# Run it once now to replace mailcow's placeholder certificate
RENEWED_LINEAGE="/etc/letsencrypt/live/$MAIL_HOSTNAME" "$hook"
ok "certificate copied into mailcow, services restarted"

info "Checks"
code=$(curl -s -o /dev/null -w '%{http_code}' -m 20 "https://$MAIL_HOSTNAME/SOGo/" || true)
[[ "$code" =~ ^(200|302)$ ]] && ok "webmail https://$MAIL_HOSTNAME/SOGo/ -> $code" || fail "webmail answered $code"
end=$(echo | openssl s_client -connect 127.0.0.1:993 -servername "$MAIL_HOSTNAME" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || true)
[ -n "$end" ] && ok "IMAPS certificate valid until $end" || fail "could not read the IMAPS certificate"

echo
echo "Next: log in to https://$MAIL_HOSTNAME/admin (admin / moohoo), change the password, enable 2FA,"
echo "then add your first domain: ./scripts/03-add-domain.sh example.org"
