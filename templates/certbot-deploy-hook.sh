#!/bin/bash
# mailcow-behind-apache: certbot deploy hook.
# certbot renews the certificate for Apache; mailcow (Postfix, Dovecot, its nginx) needs a copy of it,
# otherwise SMTP/IMAP keep serving an expired certificate while the website looks fine.
# Installed as /etc/letsencrypt/renewal-hooks/deploy/mailcow.sh by scripts/02-apache-proxy.sh.
# Placeholders: __MAIL_HOSTNAME__ __MAILCOW_DIR__
set -euo pipefail
[ "${RENEWED_LINEAGE:-}" = "/etc/letsencrypt/live/__MAIL_HOSTNAME__" ] || exit 0
install -m 644 "$(readlink -f "$RENEWED_LINEAGE/fullchain.pem")" __MAILCOW_DIR__/data/assets/ssl/cert.pem
install -m 600 "$(readlink -f "$RENEWED_LINEAGE/privkey.pem")"   __MAILCOW_DIR__/data/assets/ssl/key.pem
cd __MAILCOW_DIR__ && docker compose restart postfix-mailcow dovecot-mailcow nginx-mailcow
