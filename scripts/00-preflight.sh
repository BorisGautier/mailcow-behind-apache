#!/bin/bash
# Checks that the server can host mailcow behind Apache. Changes nothing.
# Verifie que le serveur peut accueillir mailcow derriere Apache. Ne modifie rien.
#
# Usage: sudo ./scripts/00-preflight.sh
. "$(dirname "$0")/lib.sh"
require_root
load_config

errors=0
bad() { fail "$*"; errors=$((errors + 1)); }

info "System"
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release; ok "$PRETTY_NAME"
fi
mem_gb=$(awk '/MemTotal/ {printf "%.1f", $2/1024/1024}' /proc/meminfo)
need=6; [ "$MAILCOW_SKIP_CLAMD" = y ] && need=4
awk -v m="$mem_gb" -v n="$need" 'BEGIN { exit !(m >= n) }' && ok "RAM ${mem_gb} GB" \
  || warn "RAM ${mem_gb} GB: mailcow needs ~${need} GB (less without ClamAV, MAILCOW_SKIP_CLAMD=y)"
disk=$(df -BG --output=avail / | tail -1 | tr -dc 0-9)
[ "$disk" -ge 20 ] && ok "free disk ${disk} GB" || warn "only ${disk} GB free on /"

info "Tools"
for t in docker git curl openssl dig apache2ctl certbot jq; do
  command -v "$t" >/dev/null && ok "$t" || bad "$t missing (apt install docker-ce git curl openssl dnsutils apache2 certbot python3-certbot-apache jq)"
done
docker compose version >/dev/null 2>&1 && ok "docker compose v2" || bad "docker compose v2 plugin missing"
for m in proxy proxy_http proxy_wstunnel ssl headers rewrite; do
  apache2ctl -M 2>/dev/null | grep -q "^ ${m}_module" && ok "apache mod_$m" || warn "apache mod_$m not enabled (a2enmod $m)"
done

info "Ports (must be free: mailcow publishes them directly)"
for p in 25 465 587 143 993 110 995 4190 "$MAILCOW_HTTP_PORT" "$MAILCOW_HTTPS_PORT"; do
  if ss -Hltn "sport = :$p" | grep -q .; then
    owner=$(ss -Hltnp "sport = :$p" | grep -oE 'users:\(\("[^"]+' | head -1 | cut -d'"' -f2 || true)
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q mailcow && [ "${owner:-}" = docker-proxy ]; then ok "$p used by mailcow"
    else bad "port $p already used by ${owner:-another process}"; fi
  else ok "$p free"; fi
done

info "Outbound SMTP (many providers block port 25 by default)"
if timeout 10 bash -c 'exec 3<>/dev/tcp/gmail-smtp-in.l.google.com/25' 2>/dev/null; then ok "can reach gmail-smtp-in.l.google.com:25"
else bad "outbound port 25 blocked: ask your provider to open it, or configure a relay (see docs)"; fi

info "Docker network $MAILCOW_IPV4_NETWORK.0/24"
used=$(docker network ls -q | xargs -r docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null || true)
if echo "$used" | tr ' ' '\n' | grep -q "^$MAILCOW_IPV4_NETWORK\."; then
  docker network ls --format '{{.Name}}' | grep -q mailcow && ok "already used by mailcow" || bad "$MAILCOW_IPV4_NETWORK.0/24 already used by another Docker network"
else ok "free"; fi

info "DNS of $MAIL_HOSTNAME"
a=$(qdig A "$MAIL_HOSTNAME" | tail -1 || true)
[ "$a" = "$SERVER_IP" ] && ok "A $MAIL_HOSTNAME -> $a" || bad "A record of $MAIL_HOSTNAME is '${a:-none}', expected $SERVER_IP"
ptr=$(qdig -x "$SERVER_IP" | sed 's/\.$//' || true)
[ "$ptr" = "$MAIL_HOSTNAME" ] && ok "PTR $SERVER_IP -> $ptr" \
  || bad "PTR of $SERVER_IP is '${ptr:-none}': set it to $MAIL_HOSTNAME in your provider's panel (Gmail/Outlook reject mail otherwise)"
ip -6 addr show scope global 2>/dev/null | grep -q inet6 || [ "$MAILCOW_ENABLE_IPV6" = false ] \
  || warn "MAILCOW_ENABLE_IPV6=true but no global IPv6 address on this server"

echo
if [ "$errors" -eq 0 ]; then echo "${c_green}Ready.${c_reset} Next: ./scripts/01-install-mailcow.sh"
else echo "${c_red}$errors blocking problem(s).${c_reset} Fix them, then run this check again."; exit 1; fi
