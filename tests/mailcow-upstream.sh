#!/bin/bash
# Compatibility with the current mailcow release (run weekly by CI):
#  - every service limited in templates/docker-compose.override.yml still exists upstream
#    (an unknown service in an override breaks `docker compose up`);
#  - the mailcow.conf keys set by 01-install-mailcow.sh are still read by mailcow.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

git clone -q --depth 1 https://github.com/mailcow/mailcow-dockerized "$work/mailcow"
echo "mailcow upstream: $(git -C "$work/mailcow" log -1 --format='%h %cs %s')"

upstream=$(python3 -c 'import sys, yaml; print("\n".join(yaml.safe_load(open(sys.argv[1]))["services"]))' "$work/mailcow/docker-compose.yml" | sort)
ours=$(python3 -c 'import sys, yaml; print("\n".join(yaml.safe_load(open(sys.argv[1]))["services"]))' "$REPO_DIR/templates/docker-compose.override.yml" | sort)
missing=$(comm -13 <(echo "$upstream") <(echo "$ours"))
new=$(comm -23 <(echo "$upstream") <(echo "$ours"))
[ -z "$new" ] || echo "note: upstream services without a limit in the override: $(echo "$new" | tr '\n' ' ')"
if [ -n "$missing" ]; then
  echo "FAIL: services in templates/docker-compose.override.yml that no longer exist upstream: $(echo "$missing" | tr '\n' ' ')"
  exit 1
fi
echo "OK: all $(echo "$ours" | wc -l) overridden services exist upstream"

status=0
for key in HTTP_PORT HTTP_BIND HTTPS_PORT HTTPS_BIND SKIP_LETS_ENCRYPT IPV4_NETWORK ENABLE_IPV6 SKIP_CLAMD \
           ADDITIONAL_SERVER_NAMES API_KEY API_ALLOW_FROM; do
  if grep -rqs "$key" "$work/mailcow/generate_config.sh" "$work/mailcow/docker-compose.yml"; then echo "OK: $key"
  else echo "FAIL: mailcow no longer uses $key"; status=1; fi
done
exit "$status"
