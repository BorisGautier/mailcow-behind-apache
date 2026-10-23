#!/bin/bash
# Integration test: the generated vhost is accepted by a real Apache with the modules enabled by
# 02-apache-proxy.sh. Runs in CI as root on a throwaway machine (installs apache2, writes in /etc).
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
host=mail.ci.test

command -v apache2ctl >/dev/null || { apt-get update -qq && apt-get install -y -qq apache2 >/dev/null; }
a2enmod -q proxy proxy_http proxy_wstunnel ssl headers rewrite

# Self-signed certificate where certbot would put the real one
live=/etc/letsencrypt/live/$host
mkdir -p "$live"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=$host" \
  -keyout "$live/privkey.pem" -out "$live/fullchain.pem" 2>/dev/null

cat > /tmp/ci-config.env <<EOF
MAIL_HOSTNAME=$host
SERVER_IP=203.0.113.10
TIMEZONE=UTC
MAILCOW_DIR=/opt/mailcow-dockerized
MAILCOW_HTTP_PORT=8080
MAILCOW_HTTPS_PORT=8443
MAILCOW_IPV4_NETWORK=10.77.1
CERTBOT_EMAIL=ci@ci.test
EOF
export CONFIG_FILE=/tmp/ci-config.env
# shellcheck source=../scripts/lib.sh
. "$REPO_DIR/scripts/lib.sh"
load_config
render_apache_vhost > /etc/apache2/sites-available/mailcow-$host.conf
a2ensite -q "mailcow-$host.conf"
apache2ctl configtest
apache2ctl -S 2>/dev/null | grep -E "$host" | sed 's/^/  /'
echo "vhost accepted by $(apache2ctl -v | head -1)"
