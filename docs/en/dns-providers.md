# DNS providers

`04-dns-publish.sh` publishes the mail records of a domain wherever its DNS zone is hosted. Pick the provider in
`config.env` (`DNS_PROVIDER`), or per run with `--provider` when your clients' domains are spread over several hosts.

Whatever the provider, the script:

1. saves the current records to `/root/dns-backups/<domain>-<provider>-<date>.json`;
2. asks before replacing an existing MX (that moves the domain's mail to your server);
3. replaces any old SPF and **keeps the other TXT values of the apex** (site verifications…); senders allowed by the
   old SPF (newsletter, form or SaaS `include:`) are listed and kept only with `--spf-extra "include:..."` (per domain)
   or `SPF_EXTRA` (all domains), after confirmation;
4. publishes MX, SPF, DKIM, DMARC, the autodiscover/IMAP/SMTP SRV records and `webmail` CNAME;
5. checks on the domain's authoritative servers that MX, SPF, DKIM and DMARC are served.

| `DNS_PROVIDER` | DNS hosts | Credentials in `config.env` |
|---|---|---|
| `gandi` | Gandi LiveDNS | `GANDI_PAT`: Personal Access Token, permission *Manage domain name technical configurations* |
| `cloudflare` | Cloudflare | `CLOUDFLARE_API_TOKEN`: API token with *Zone:Read* and *DNS:Edit* on the zones |
| `lexicon` | 100+ hosts through [dns-lexicon](https://github.com/dns-lexicon/dns-lexicon) | `LEXICON_PROVIDER` + `LEXICON_<PROVIDER>_<OPTION>` |
| `manual` | anything else (registrar panel, hosting control panel, own BIND…) | none |

## Gandi

Create the token in *Organization → Sharing → Personal Access Tokens*, limited to the domains you manage.
Gandi sometimes answers "updated" without serving the new TXT value; the script detects it and republishes with
another TTL, which forces it.

## Cloudflare

*My Profile → API Tokens → Create Token → Edit zone DNS*, with *Zone:Read* added. Records are created in
"DNS only" mode: mail never goes through Cloudflare's proxy, and the `webmail` CNAME must not be proxied either
(the certificate is the one of your server).

## dns-lexicon (OVH, AWS Route 53, GoDaddy, Namecheap, Infomaniak, DigitalOcean, Hetzner, Scaleway…)

```bash
pipx install dns-lexicon            # or: pip install dns-lexicon
lexicon --help                      # list of providers
lexicon ovh --help                  # options of one provider
```

Each option becomes a variable `LEXICON_<PROVIDER>_<OPTION>` in `config.env`. OVH example (create the keys at
<https://eu.api.ovh.com/createToken/> with GET/POST/PUT/DELETE on `/domain/zone/*`):

```bash
DNS_PROVIDER=lexicon
LEXICON_PROVIDER=ovh
LEXICON_OVH_AUTH_ENTRYPOINT=ovh-eu
LEXICON_OVH_AUTH_APPLICATION_KEY=...
LEXICON_OVH_AUTH_APPLICATION_SECRET=...
LEXICON_OVH_AUTH_CONSUMER_KEY=...
```

Route 53: `LEXICON_PROVIDER=route53` with `LEXICON_ROUTE53_AUTH_ACCESS_KEY` / `LEXICON_ROUTE53_AUTH_ACCESS_SECRET`.
Providers implement records slightly differently (MX priority, long TXT values): run `scripts/check.sh` after
publishing, it compares what is served with what mailcow expects.

## Manual (any other DNS host)

```bash
sudo ./scripts/04-dns-publish.sh client-a.org --provider manual
```

Nothing is changed: the script reads the current records through DNS, merges SPF with the existing TXT values,
and writes `/root/dns-backups/<domain>-mail-records-<date>.zone`:

```
@                        3600 IN MX    10 mail.example.com.
@                        3600 IN TXT   "google-site-verification=..."
@                        3600 IN TXT   "v=spf1 mx a:mail.example.com ~all"
dkim._domainkey          3600 IN TXT   "v=DKIM1;k=rsa;t=s;s=email;p=MIIBIjANBg..." "...IDAQAB"
...
```

Recreate these records in the provider's panel, replacing the existing ones of the same name and type, then run
`scripts/check.sh`. Most panels accept the long DKIM value pasted in one piece (without the quotes).

## Adding a provider

A provider is a file `scripts/dns/<name>.sh` with five functions (see the contract at the top of
`scripts/dns/engine.sh`): `dns_check_config`, `dns_backup FILE`, `dns_get NAME TYPE`,
`dns_set NAME TYPE TTL VALUE...` and, optionally, `dns_republish NAME TYPE`. `tests/fake-dns.sh` is a complete
example used by the tests. Pull requests are welcome.

## MTA-STS (encryption enforced between mail servers)

`04-dns-publish.sh` also publishes `mta-sts.<domain>` (CNAME to the mail server), `_mta-sts` (policy id) and
`_smtp._tls` (TLS reports sent to the DMARC report address). The policy itself must be served over HTTPS at
`https://mta-sts.<domain>/.well-known/mta-sts.txt`, for example by Apache with one certificate for all domains:

```
version: STSv1
mode: testing
mx: mail.example.com
max_age: 604800
```

Start in `mode: testing` (receivers only report problems), read the TLS reports for a few weeks, then switch to
`mode: enforce` and change `MTA_STS_ID` in `config.env` (any new value) so that senders reload the policy.
