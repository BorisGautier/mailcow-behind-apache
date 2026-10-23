# mailcow-behind-apache

[![CI](https://github.com/BorisGautier/mailcow-behind-apache/actions/workflows/ci.yml/badge.svg)](https://github.com/BorisGautier/mailcow-behind-apache/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/BorisGautier/mailcow-behind-apache)](https://github.com/BorisGautier/mailcow-behind-apache/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**Self-host your email (and your clients') with [mailcow](https://mailcow.email) on a VPS that already runs other websites behind Apache.**

[Version française](README.fr.md)

The official mailcow setup assumes it owns ports 80/443 and the server. On a shared VPS, Apache already serves
your sites and certbot already manages certificates. These scripts install mailcow *next to* that stack:

```
                 Internet
                    │
        ┌───────────┴────────────────────────────────────┐
        │ 80/443                  25 465 587 993 995 4190 │
        ▼                                     ▼
   Apache + certbot  ──proxy──▶  127.0.0.1:8443   mailcow (Postfix, Dovecot, Rspamd,
   (your other sites)            nginx-mailcow    SOGo webmail, ClamAV) in Docker
        │                                     ▲
        └── certbot deploy hook copies the renewed certificate ──┘
```

- **Apache keeps 80/443.** mailcow's web server listens on loopback only; Apache proxies the admin UI,
  SOGo webmail, ActiveSync and autodiscover to it.
- **One certificate, managed by certbot.** A deploy hook copies every renewal into mailcow, so SMTP and
  IMAP never serve an expired certificate while the website looks fine.
- **Several domains, one server.** `mail.example.com` hosts the mailboxes of `client-a.org`, `client-b.net`…
  Each client can keep `webmail.client-a.org`, redirected to the shared webmail.
- **DNS done right, at any DNS host.** MX, a single merged SPF, DKIM (2048 bits), DMARC and SRV records are generated
  and published through the API of Gandi or Cloudflare, of 100+ other hosts via
  [dns-lexicon](https://github.com/dns-lexicon/dns-lexicon) (OVH, Route 53, GoDaddy, Namecheap, Infomaniak…), or
  written as a zone snippet to paste anywhere. The zone is backed up first. See [DNS providers](docs/en/dns-providers.md).
- **Safe on a busy server.** Pre-flight checks (ports, Docker subnets, outbound port 25, reverse DNS) and
  memory limits for every mailcow container.

Written from a real migration: 5 domains moved off a hosted mail service onto a 48 GB VPS that also runs
about 100 other containers. Everything that went wrong is in [docs/en/pitfalls.md](docs/en/pitfalls.md).

## Requirements

| | |
|---|---|
| OS | Debian 12 / Ubuntu 22.04+ (other Linux distributions with systemd should work) |
| Already installed | Docker Engine + compose plugin, Apache 2.4, certbot with the Apache plugin, `git curl openssl dnsutils jq` |
| RAM | 6 GB free for mailcow (4 GB with ClamAV disabled) |
| Network | A fixed public IPv4, **outbound port 25 open** (some providers block it), ports 25, 465, 587, 143, 993, 110, 995, 4190 free |
| DNS | An A record for the mail hostname, and the **reverse DNS (PTR)** of the IP set to that hostname at your provider |

## Quick start

```bash
git clone https://github.com/BorisGautier/mailcow-behind-apache.git
cd mailcow-behind-apache
cp config.example.env config.env && nano config.env      # hostname, IP, timezone, free Docker subnet...

sudo ./scripts/00-preflight.sh          # checks only, changes nothing
sudo ./scripts/01-install-mailcow.sh    # mailcow on 127.0.0.1:8080/8443, own network, limits
sudo ./scripts/02-apache-proxy.sh       # Apache vhost, Let's Encrypt certificate, deploy hook
# log in to https://mail.example.com/admin (admin / moohoo): change the password and enable 2FA

sudo ./scripts/03-add-domain.sh client-a.org          # domain + DKIM, prints the DNS records
sudo ./scripts/04-dns-publish.sh client-a.org         # publish them (API or zone snippet, see DNS_PROVIDER)
sudo ./scripts/05-add-mailbox.sh contact@client-a.org "Contact"
sudo ./scripts/06-webmail-redirects.sh client-a.org   # optional: webmail.client-a.org -> shared webmail
sudo ./scripts/check.sh                               # full health check (run it from cron too)
```

All scripts are idempotent: running one again re-applies its settings without duplicating anything.

## Scripts

| Script | What it does |
|---|---|
| `00-preflight.sh` | RAM/disk, tools, Apache modules, free ports, outbound port 25, free Docker subnet, A and PTR records. Changes nothing. |
| `01-install-mailcow.sh` | Clones mailcow, generates `mailcow.conf`, binds it to loopback, disables its ACME client, sets the Docker subnet, IPv6, ClamAV, the API (host only) and the resource limits, pulls and starts. |
| `02-apache-proxy.sh` | Enables the Apache modules, gets the certificate (adds autodiscover/autoconfig only if they resolve), writes the vhost, installs the certbot deploy hook and runs it once. |
| `03-add-domain.sh` | Creates the domain and its DKIM key through the mailcow API and prints every DNS record. |
| `04-dns-publish.sh` | Backs up the records, then publishes MX, merged SPF (other TXT values kept), DKIM, DMARC, SRV and `webmail` CNAME through the chosen provider (`gandi`, `cloudflare`, `lexicon`, or `manual` = zone snippet for any host). Asks before replacing an existing MX. Verifies on the authoritative servers. `--provider` when domains are spread over several hosts. |
| `05-add-mailbox.sh` | Creates a mailbox with a random password stored in a root-only file. |
| `06-webmail-redirects.sh` | `webmail.<client>` → shared webmail, with its own certificate. |
| `check.sh` | Containers, OOM kills, ports, queue, certificate expiry on 465/587/993, PTR, blocklists, and for every domain MX/SPF/DKIM (compared with mailcow's key)/DMARC. `--send-test` sends a real message. |

## Documentation

- [Pitfalls we hit, and their fixes](docs/en/pitfalls.md)
- [DNS providers](docs/en/dns-providers.md): Gandi, Cloudflare, 100+ hosts through dns-lexicon, or manual
- [Migrating a domain from another provider](docs/en/migration.md) (no lost mail)
- [Operations](docs/en/operations.md): backups, updates, monitoring, sending from your applications, DMARC hardening

## Development

- Work on `dev`; `main` only receives tested changes through pull requests from `dev`.
- CI runs on every push and pull request: ShellCheck, bash syntax, YAML, documentation links, unit tests
  (`bats tests`), the generated vhost checked by a real Apache, and a compatibility check against the current
  mailcow release (also every Monday, to catch upstream changes).
- Dependabot opens weekly pull requests on `dev` for the GitHub Actions used by the workflows.
- Releases: add the version to [CHANGELOG.md](CHANGELOG.md), merge into `main`, then
  `git tag -a vX.Y.Z -m vX.Y.Z && git push origin vX.Y.Z`. The release workflow runs the CI again and publishes the
  GitHub release with its notes and an archive.

## Security notes

- `config.env` (DNS API tokens) and the credentials file are never committed (`.gitignore`). Keep them root-only.
- The mailcow API key generated by the installer only accepts requests from the host itself.
- Change the default admin password and enable two-factor authentication right after installation.

## License

[MIT](LICENSE). mailcow itself is GPL-3.0 and is downloaded from its official repository at install time.
