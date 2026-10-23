#!/usr/bin/env bats
# Unit tests for scripts/lib.sh. Run: bats tests
# Needs bash, jq, sed, openssl (no network, no root, no Docker).

setup() {
  TMP=$(mktemp -d)
  write_config mail.client.test
  export CONFIG_FILE="$TMP/config.env"
  # shellcheck source=../scripts/lib.sh
  source "$BATS_TEST_DIRNAME/../scripts/lib.sh"
  set +euo pipefail   # lib.sh enables strict mode for the scripts; bats handles failures itself
}

teardown() { rm -rf "$TMP"; }

write_config() {
  cat > "$TMP/config.env" <<EOF
MAIL_HOSTNAME=$1
SERVER_IP=203.0.113.10
TIMEZONE=Europe/Paris
MAILCOW_DIR=$TMP/mailcow
MAILCOW_HTTP_PORT=8080
MAILCOW_HTTPS_PORT=8443
MAILCOW_IPV4_NETWORK=10.77.1
CERTBOT_EMAIL=admin@client.test
EOF
}

@test "load_config fails when config.env is missing" {
  CONFIG_FILE="$TMP/nope.env" run load_config
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing"* ]]
}

@test "load_config refuses the example hostname" {
  write_config mail.example.com
  run load_config
  [ "$status" -ne 0 ]
  [[ "$output" == *"example value"* ]]
}

@test "load_config refuses an empty required variable" {
  sed -i 's/^SERVER_IP=.*/SERVER_IP=/' "$TMP/config.env"
  run load_config
  [ "$status" -ne 0 ]
  [[ "$output" == *"SERVER_IP is not set"* ]]
}

@test "load_config sets defaults for optional variables" {
  load_config
  [ "$DMARC_POLICY" = none ]
  [ "$DMARC_RUA" = "postmaster@{domain}" ]
  [ "$MAILCOW_ENABLE_IPV6" = false ]
  [ "$APPLY_RESOURCE_LIMITS" = yes ]
}

@test "spf_value allows this server only" {
  load_config
  [ "$(spf_value)" = "v=spf1 mx a:mail.client.test ~all" ]
}

@test "spf_value keeps the extra mechanisms" {
  load_config
  SPF_EXTRA="include:_spf.google.com ip4:198.51.100.7"
  [ "$(spf_value)" = "v=spf1 mx a:mail.client.test include:_spf.google.com ip4:198.51.100.7 ~all" ]
}

@test "dmarc_value puts the domain in the report address" {
  load_config
  DMARC_POLICY=quarantine
  [ "$(dmarc_value shop.test)" = "v=DMARC1; p=quarantine; rua=mailto:postmaster@shop.test" ]
}

@test "txt_chunks keeps a short value in one string" {
  [ "$(txt_chunks 'v=DMARC1; p=none' | jq -r .)" = '"v=DMARC1; p=none"' ]
}

@test "txt_chunks splits a 2048-bit DKIM key into strings of at most 255 characters" {
  key="v=DKIM1;k=rsa;t=s;s=email;p=$(openssl rand -base64 300 | tr -d '\n')"
  value=$(txt_chunks "$key" | jq -r .)
  # every quoted string fits in a TXT string
  while read -r chunk; do [ ${#chunk} -le 255 ]; done < <(grep -oE '"[^"]*"' <<< "$value" | tr -d '"')
  # joined back, the strings give the original key
  [ "$(grep -oE '"[^"]*"' <<< "$value" | tr -d '"\n')" = "$key" ]
  [ "$(grep -oE '"[^"]*"' <<< "$value" | wc -l)" -ge 2 ]
}

@test "set_mailcow_conf replaces an existing key and appends a new one" {
  load_config
  mkdir -p "$MAILCOW_DIR"
  printf 'HTTP_PORT=80\nHTTP_BIND=\n' > "$MAILCOW_DIR/mailcow.conf"
  set_mailcow_conf HTTP_PORT 8080
  set_mailcow_conf SKIP_LETS_ENCRYPT y
  [ "$(mailcow_conf HTTP_PORT)" = 8080 ]
  [ "$(mailcow_conf SKIP_LETS_ENCRYPT)" = y ]
  [ "$(grep -c '^HTTP_PORT=' "$MAILCOW_DIR/mailcow.conf")" = 1 ]
}

@test "render_apache_vhost fills every placeholder" {
  load_config
  out=$(render_apache_vhost)
  run grep -q '__[A-Z_]*__' <<< "$out"
  [ "$status" -ne 0 ]
  grep -q 'ServerName mail.client.test' <<< "$out"
  grep -q 'ServerAlias autodiscover.client.test autoconfig.client.test' <<< "$out"
  grep -q 'ProxyPass / https://127.0.0.1:8443/' <<< "$out"
  grep -q '/etc/letsencrypt/live/mail.client.test/fullchain.pem' <<< "$out"
}

@test "render_deploy_hook gives a valid script for this host" {
  load_config
  render_deploy_hook > "$TMP/hook.sh"
  run grep -q '__[A-Z_]*__' "$TMP/hook.sh"
  [ "$status" -ne 0 ]
  bash -n "$TMP/hook.sh"
  grep -q '"/etc/letsencrypt/live/mail.client.test"' "$TMP/hook.sh"
}

@test "the deploy hook ignores other certificates" {
  load_config
  render_deploy_hook > "$TMP/hook.sh"
  RENEWED_LINEAGE=/etc/letsencrypt/live/other.test run bash "$TMP/hook.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "gen_password has the requested length and no shell-unsafe characters" {
  p=$(gen_password 24)
  [ ${#p} -eq 24 ]
  [[ "$p" =~ ^[A-Za-z0-9]+$ ]]
}
