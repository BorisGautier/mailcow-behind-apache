#!/bin/bash
# Installs mailcow-dockerized bound to loopback, without its own Let's Encrypt (Apache + certbot handle TLS).
# Installe mailcow en local uniquement, sans son propre Let's Encrypt (Apache + certbot gerent TLS).
#
# Usage: sudo ./scripts/01-install-mailcow.sh
. "$(dirname "$0")/lib.sh"
require_root
load_config

if [ -f "$MAILCOW_DIR/mailcow.conf" ]; then
  info "mailcow already configured in $MAILCOW_DIR - only re-applying settings"
else
  info "Cloning mailcow-dockerized into $MAILCOW_DIR"
  git clone https://github.com/mailcow/mailcow-dockerized "$MAILCOW_DIR"
  cd "$MAILCOW_DIR"
  # "1" = stable branch. generate_config.sh asks for the hostname and timezone, given here as variables.
  printf '1\n' | MAILCOW_HOSTNAME="$MAIL_HOSTNAME" MAILCOW_TZ="$TIMEZONE" ./generate_config.sh
fi
cd "$MAILCOW_DIR"

info "Adapting mailcow.conf"
set_mailcow_conf HTTP_PORT "$MAILCOW_HTTP_PORT"
set_mailcow_conf HTTP_BIND 127.0.0.1
set_mailcow_conf HTTPS_PORT "$MAILCOW_HTTPS_PORT"
set_mailcow_conf HTTPS_BIND 127.0.0.1
set_mailcow_conf SKIP_LETS_ENCRYPT y            # certificate comes from certbot (02-apache-proxy.sh)
set_mailcow_conf IPV4_NETWORK "$MAILCOW_IPV4_NETWORK"
set_mailcow_conf ENABLE_IPV6 "$MAILCOW_ENABLE_IPV6"
set_mailcow_conf SKIP_CLAMD "$MAILCOW_SKIP_CLAMD"
domain_base=${MAIL_HOSTNAME#*.}
set_mailcow_conf ADDITIONAL_SERVER_NAMES "autodiscover.$domain_base,autoconfig.$domain_base"
# API for the helper scripts, reachable only from the host. Requests to the published port reach
# nginx-mailcow from the Docker gateway (x.x.x.1), hence the second address.
[ -n "$(mailcow_conf API_KEY)" ] || set_mailcow_conf API_KEY "$(openssl rand -hex 16 | tr a-f A-F)"
set_mailcow_conf API_ALLOW_FROM "127.0.0.1,$MAILCOW_IPV4_NETWORK.1"
chmod 600 mailcow.conf
ok "ports $MAILCOW_HTTP_PORT/$MAILCOW_HTTPS_PORT on 127.0.0.1, network $MAILCOW_IPV4_NETWORK.0/24, IPv6=$MAILCOW_ENABLE_IPV6, ClamAV skip=$MAILCOW_SKIP_CLAMD"

if [ "$APPLY_RESOURCE_LIMITS" = yes ]; then
  if [ -f docker-compose.override.yml ] && ! grep -q "mailcow-behind-apache" docker-compose.override.yml; then
    warn "docker-compose.override.yml already exists and was not written by this project: left untouched"
  else
    cp "$REPO_DIR/templates/docker-compose.override.yml" docker-compose.override.yml
    ok "resource limits: docker-compose.override.yml (kept by mailcow's update.sh)"
  fi
fi

# Placeholder certificate so nginx-mailcow starts; replaced by the real one in 02-apache-proxy.sh
mkdir -p data/assets/ssl
if [ ! -s data/assets/ssl/cert.pem ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$MAIL_HOSTNAME" \
    -keyout data/assets/ssl/key.pem -out data/assets/ssl/cert.pem 2>/dev/null
fi

info "Pulling images"
# A stale ghcr.io login in root's Docker config makes pulls of public images fail ("denied"):
# pull with an empty Docker config instead of touching the existing one.
empty_cfg=$(mktemp -d)
echo '{}' > "$empty_cfg/config.json"
DOCKER_CONFIG="$empty_cfg" docker compose pull --quiet
rm -rf "$empty_cfg"

info "Starting mailcow"
docker compose up -d
for _ in $(seq 1 30); do
  curl -sk -o /dev/null -m 5 "https://127.0.0.1:$MAILCOW_HTTPS_PORT/" -H "Host: $MAIL_HOSTNAME" && break
  sleep 10
done
docker compose ps --format '{{.Service}}: {{.Status}}' | sed 's/^/  /'

echo
echo "Next: ./scripts/02-apache-proxy.sh"
echo "Admin UI (after step 02): https://$MAIL_HOSTNAME/admin  -  default login admin / moohoo, change it immediately."
