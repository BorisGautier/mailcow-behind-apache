# Pitfalls we hit, and their fixes

Each item happened during a real installation on a shared VPS. The scripts handle all of them.

## Server and Docker

**1. No free Docker subnet.** mailcow defaults to `172.22.1.0/24`. On a server with many compose projects,
every `172.17-31.x` range can already be taken, and `docker compose up` fails with *"Pool overlaps with other one
on this address space"*. → Set `MAILCOW_IPV4_NETWORK` to an unused range (e.g. `10.77.1`). `00-preflight.sh`
lists the subnets in use.

**2. "denied" when pulling public images.** A stale `docker login ghcr.io` in root's `~/.docker/config.json`
makes Docker send bad credentials for *public* ghcr.io images. → `01-install-mailcow.sh` pulls with an empty
`DOCKER_CONFIG`, without touching your existing logins.

**3. Not enough memory.** ClamAV alone uses ~1 GB and up to ~2 GB while reloading signatures. On a busy host, the
kernel OOM killer picks a random container. → `templates/docker-compose.override.yml` caps every mailcow
container; `check.sh` reports containers killed for lack of memory. Without antivirus: `MAILCOW_SKIP_CLAMD=y`.

**4. IPv6 half configured.** If mailcow enables IPv6 but the server has no global IPv6 (or no PTR for it), Postfix
tries IPv6 first and receivers reject the mail. → `MAILCOW_ENABLE_IPV6=false` unless IPv6 is complete.

## Apache and certificates

**5. Apache already owns 80/443.** → mailcow binds `127.0.0.1:8080/8443` (`HTTP_BIND`/`HTTPS_BIND`), its own ACME
client is disabled (`SKIP_LETS_ENCRYPT=y`) and Apache proxies to it, including the `/websocket` and
`/Microsoft-Server-ActiveSync` paths and long timeouts.

**6. Website fine, mail certificate expired.** certbot renews the certificate for Apache, but Postfix and Dovecot
read their own copy in `data/assets/ssl/`. Mail clients start failing 90 days later. → The certbot deploy hook
copies every renewal and restarts postfix, dovecot and nginx-mailcow.

**7. certbot fails because of one dead name.** A certificate that still lists a name no longer pointing to the
server cannot be renewed at all. → Only request names that resolve to the server (the scripts check each name
first), and add the others later with `--expand`.

**8. Wildcard DNS + default vhost = "Dangerous site" warning.** With `*.example.com` pointing to the server, any
unknown subdomain is answered by Apache's *first* vhost, which may be another customer's site. Browsers then see
the same site on random names, which looks like phishing. → Add a catch-all default vhost (first in load order)
returning 403 for unknown names.

**9. HSTS `includeSubDomains`.** Set on the mail host, it also forces HTTPS on every sub-name of that domain.
→ The template sends HSTS without `includeSubDomains`.

## DNS

**10. Reverse DNS (PTR).** Providers set a generic PTR (e.g. `vmi123456.provider.net`). Gmail and Outlook reject or
spam-folder mail from an IP whose PTR does not match the sending hostname. → Set the PTR to `MAIL_HOSTNAME` in the
provider's panel (it is not in your DNS zone). `00-preflight.sh` and `check.sh` verify it.

**11. Outbound port 25 blocked.** Several cloud providers block it by default. Mail then stays in the queue.
→ Ask the provider to open it, or relay outgoing mail through a smarthost (mailcow admin → Configuration →
Routing).

**12. Two SPF records.** A domain that already had `v=spf1 include:old-provider ~all` and gets a second SPF record
fails SPF entirely (`permerror`). → Keep exactly one TXT starting with `v=spf1`. `04-dns-gandi.sh` replaces the
old one and keeps the other TXT values (site verifications…); `SPF_EXTRA` keeps third-party senders.

**13. MX without the final dot.** In a zone or in some DNS APIs, `10 mail.example.com` (no trailing dot) is relative:
it becomes `mail.example.com.example.org`. → Always write `mail.example.com.`.

**14. DKIM longer than 255 characters.** A 2048-bit key does not fit in one TXT string. → Split it into several
quoted strings in the same record (`"v=DKIM1; k=rsa; p=MIIB..." "...rest"`). The Gandi script does it.

**15. Gandi LiveDNS accepts an update but keeps serving the old TXT.** Observed several times: the API answers
"updated", yet the authoritative servers keep the previous value. → Publishing the same values again with a
different TTL forces it. `04-dns-gandi.sh` checks the authoritative servers and does this automatically.

**16. A domain that stays with another provider.** If `example.com` stays on Google Workspace (or similar), do **not**
add it to mailcow: mailcow would deliver mail sent from your server to `@example.com` locally instead of to Google.

**17. No MX record = mail to the A record.** Senders deliver to the A record of a domain without MX (implicit MX).
With wildcard DNS this can accidentally work, then break the day the A record changes. → Always publish an
explicit MX.

## Scripting

**18. A piped script stops in the middle.** `ssh server 'bash -s' < script.sh` with a
`docker compose exec -T ...` inside a loop: the container command reads the rest of the script from stdin and the
loop silently ends after the first iteration. → Add `</dev/null` to `docker compose exec` calls in scripts.

**19. The API refuses requests from the host.** With `API_ALLOW_FROM=127.0.0.1`, calls to the published port
still arrive at nginx-mailcow from the Docker gateway (`x.x.x.1`). → Allow both (`01-install-mailcow.sh` does).
