#!/usr/bin/env bats
# Tests of the DNS publication engine (scripts/dns/engine.sh) and of the provider-specific formatting.
# No network: the engine runs against tests/fake-dns.sh.

setup() {
  TMP=$(mktemp -d)
  cat > "$TMP/config.env" <<EOF
MAIL_HOSTNAME=mail.host.test
SERVER_IP=203.0.113.10
TIMEZONE=UTC
MAILCOW_DIR=$TMP/mailcow
MAILCOW_HTTP_PORT=8080
MAILCOW_HTTPS_PORT=8443
MAILCOW_IPV4_NETWORK=10.77.1
CERTBOT_EMAIL=admin@host.test
EOF
  export CONFIG_FILE="$TMP/config.env"
  # shellcheck source=../scripts/lib.sh
  source "$BATS_TEST_DIRNAME/../scripts/lib.sh"
  set +euo pipefail
  load_config
  # shellcheck source=../scripts/dns/engine.sh
  source "$BATS_TEST_DIRNAME/../scripts/dns/engine.sh"
  DNS_DOMAIN=client.test
  DNS_BACKUP_DIR="$TMP/backups"
  DKIM="v=DKIM1;k=rsa;t=s;s=email;p=$(openssl rand -base64 300 | tr -d '\n')"
}

teardown() { rm -rf "$TMP"; }

use_fake_provider() {
  export FAKE_DNS_DIR="$TMP/zone"
  mkdir -p "$FAKE_DNS_DIR"
  DNS_PROVIDER=fake
  # shellcheck source=fake-dns.sh
  source "$BATS_TEST_DIRNAME/fake-dns.sh"
}

@test "mail_dns_records lists every record a mail domain needs" {
  run mail_dns_records client.test "$DKIM"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 12 ]
  [[ "$output" == *$'@\tMX\t10 mail.host.test.'* ]]
  [[ "$output" == *$'_dmarc\tTXT\tv=DMARC1; p=none; rua=mailto:postmaster@client.test'* ]]
  [[ "$output" == *$'_submission._tcp\tSRV\t0 1 587 mail.host.test.'* ]]
  [[ "$output" == *$'webmail\tCNAME\tmail.host.test.'* ]]
  [[ "$output" == *$'mta-sts\tCNAME\tmail.host.test.'* ]]
  [[ "$output" == *$'_mta-sts\tTXT\tv=STSv1; id=20261026'* ]]
  [[ "$output" == *$'_smtp._tls\tTXT\tv=TLSRPTv1; rua=mailto:postmaster@client.test'* ]]
}

@test "apex_txt_merge replaces the old SPF and keeps the other values" {
  run apex_txt_merge "v=spf1 mx a:mail.host.test ~all" <<< $'google-site-verification=abc\nv=spf1 include:_mailcust.gandi.net ~all\n'
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "google-site-verification=abc" ]
  [ "${lines[1]}" = "v=spf1 mx a:mail.host.test ~all" ]
}

@test "apex_txt_merge works on an empty apex" {
  run apex_txt_merge "v=spf1 mx ~all" < /dev/null
  [ "$output" = "v=spf1 mx ~all" ]
}

@test "txt_unquote joins the strings of a long TXT value" {
  [ "$(echo '"v=DKIM1; p=AB" "CD"' | txt_unquote)" = "v=DKIM1; p=ABCD" ]
  [ "$(echo 'v=spf1 mx ~all' | txt_unquote)" = "v=spf1 mx ~all" ]
}

@test "txt_unquote decodes zone escapes (Gandi returns '/' as '\\/')" {
  [ "$(echo '"p=MIIB\/ytm" "e\"x"' | txt_unquote)" = 'p=MIIB/ytme"x' ]
}

@test "spf_dropped lists the senders the new SPF no longer allows" {
  [ "$(spf_dropped "v=spf1 mx a:mail.host.test include:_spf.firebasemail.com include:_mailcust.gandi.net ~all" "$(spf_value)")" \
    = "include:_spf.firebasemail.com include:_mailcust.gandi.net" ]
  [ -z "$(spf_dropped "v=spf1 mx ~all" "$(spf_value)")" ]
  [ -z "$(spf_dropped "" "$(spf_value)")" ]
  SPF_EXTRA="include:_spf.firebasemail.com"
  [ "$(spf_dropped "v=spf1 include:_spf.firebasemail.com include:old.test -all" "$(spf_value)")" = "include:old.test" ]
}

@test "dns_publish asks before dropping SPF senders and changes nothing when refused" {
  use_fake_provider
  echo "v=spf1 include:_spf.firebasemail.com ~all" > "$FAKE_DNS_DIR/@__TXT"
  run dns_publish "$DKIM" no <<< "n"
  [ "$status" -ne 0 ]
  [[ "$output" == *"also allows: include:_spf.firebasemail.com"* ]]
  [ "$(cat "$FAKE_DNS_DIR/@__TXT")" = "v=spf1 include:_spf.firebasemail.com ~all" ]
}

@test "SPF_EXTRA keeps a third-party sender" {
  use_fake_provider
  echo "v=spf1 include:_spf.firebasemail.com ~all" > "$FAKE_DNS_DIR/@__TXT"
  SPF_EXTRA="include:_spf.firebasemail.com"
  run dns_publish "$DKIM" no
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_DNS_DIR/@__TXT")" = "v=spf1 mx a:mail.host.test include:_spf.firebasemail.com ~all" ]
}

@test "dns_publish writes every record and keeps the other apex TXT values" {
  use_fake_provider
  printf 'google-site-verification=abc\nv=spf1 include:old.test ~all\n' > "$FAKE_DNS_DIR/@__TXT"
  echo "10 mx.old-provider.test." > "$FAKE_DNS_DIR/@__MX"
  run dns_publish "$DKIM" yes
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_DNS_DIR/@__MX")" = "10 mail.host.test." ]
  grep -qx "google-site-verification=abc" "$FAKE_DNS_DIR/@__TXT"
  grep -qx "v=spf1 mx a:mail.host.test ~all" "$FAKE_DNS_DIR/@__TXT"
  run grep -c "v=spf1" "$FAKE_DNS_DIR/@__TXT"
  [ "$output" = 1 ]
  [ "$(cat "$FAKE_DNS_DIR/dkim._domainkey__TXT")" = "$DKIM" ]
  [ "$(cat "$FAKE_DNS_DIR/_imaps._tcp__SRV")" = "0 1 993 mail.host.test." ]
  ls "$DNS_BACKUP_DIR"/client.test-fake-*.json
}

@test "dns_publish warns before replacing the MX of another provider" {
  use_fake_provider
  echo "10 mx.old-provider.test." > "$FAKE_DNS_DIR/@__MX"
  run dns_publish "$DKIM" yes
  [[ "$output" == *"current MX of client.test: 10 mx.old-provider.test."* ]]
}

@test "dns_publish stops without changing anything when the MX replacement is refused" {
  use_fake_provider
  echo "10 mx.old-provider.test." > "$FAKE_DNS_DIR/@__MX"
  run dns_publish "$DKIM" no <<< "n"
  [ "$status" -ne 0 ]
  [ "$(cat "$FAKE_DNS_DIR/@__MX")" = "10 mx.old-provider.test." ]
  [ ! -e "$FAKE_DNS_DIR/_dmarc__TXT" ]
}

@test "dns_publish is idempotent" {
  use_fake_provider
  dns_publish "$DKIM" yes >/dev/null
  first=$(cat "$FAKE_DNS_DIR"/*)
  dns_publish "$DKIM" yes >/dev/null
  [ "$(cat "$FAKE_DNS_DIR"/*)" = "$first" ]
}

@test "cloudflare: MX, SRV, CNAME and long TXT payloads" {
  source "$BATS_TEST_DIRNAME/../scripts/dns/cloudflare.sh"
  [ "$(cf_record_json client.test MX 3600 '10 mail.host.test.' | jq -c '[.content, .priority]')" = '["mail.host.test",10]' ]
  [ "$(cf_record_json _imaps._tcp.client.test SRV 3600 '0 1 993 mail.host.test.' | jq -c .data)" = '{"priority":0,"weight":1,"port":993,"target":"mail.host.test"}' ]
  [ "$(cf_record_json webmail.client.test CNAME 3600 'mail.host.test.' | jq -c '[.content, .proxied]')" = '["mail.host.test",false]' ]
  content=$(cf_record_json dkim._domainkey.client.test TXT 3600 "$DKIM" | jq -r .content)
  [[ "$content" == '"v=DKIM1'*'" "'* ]]
  [ "$(echo "$content" | txt_unquote)" = "$DKIM" ]
  [ "$(cf_record_json _dmarc.client.test TXT 3600 'v=DMARC1; p=none' | jq -r .content)" = 'v=DMARC1; p=none' ]
}

@test "manual: zone snippet with quoted, split TXT values" {
  source "$BATS_TEST_DIRNAME/../scripts/dns/manual.sh"
  MAN_NS=none.invalid
  dns_get() { :; }   # no network in the tests
  dns_check_config
  dns_set dkim._domainkey TXT 3600 "$DKIM"
  dns_set @ MX 3600 "10 mail.host.test."
  grep -qE '^dkim._domainkey +3600 IN TXT +"v=DKIM1[^"]*" "' "$DNS_ZONE_OUT"
  grep -qE '^@ +3600 IN MX +10 mail.host.test.$' "$DNS_ZONE_OUT"
}

@test "every provider implements the contract" {
  for p in "$BATS_TEST_DIRNAME"/../scripts/dns/*.sh "$BATS_TEST_DIRNAME/fake-dns.sh"; do
    [ "$(basename "$p")" = engine.sh ] && continue
    for fn in dns_check_config dns_backup dns_get dns_set; do
      grep -qE "^$fn\(\)" "$p" || { echo "$p: missing $fn"; return 1; }
    done
    bash -n "$p"
  done
}
