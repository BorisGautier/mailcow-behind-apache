# Operations

## Backups

mailcow ships a backup tool. Daily backup of everything (mail, database, configuration, DKIM keys), kept 7 days:

```bash
cat > /etc/cron.d/mailcow-backup <<'EOF'
MAILCOW_BACKUP_LOCATION=/var/backups/mailcow
30 3 * * * root /opt/mailcow-dockerized/helper-scripts/backup_and_restore.sh backup all --delete-days 7 >/var/log/mailcow-backup.log 2>&1
EOF
```

Also keep a copy of `mailcow.conf` and `docker-compose.override.yml`, and send the backups to another machine:
a backup on the same disk does not survive the loss of the server. Restore with
`backup_and_restore.sh restore`.

## Updates

```bash
cd /opt/mailcow-dockerized && ./update.sh --check   # anything new?
./update.sh                                          # backs up the configuration, pulls, restarts
sudo /path/to/mailcow-behind-apache/scripts/check.sh
```

`update.sh` keeps `mailcow.conf` and `docker-compose.override.yml`. Read the release notes first: they announce
the changes that need manual action.

## Monitoring

- `scripts/check.sh` exits with a non-zero code on any problem: run it from cron and mail its output on failure,
  or call it from your monitoring tool.
- mailcow's watchdog sends alerts when a service restarts: set `WATCHDOG_NOTIFY_EMAIL` in `mailcow.conf`, then
  `docker compose up -d`.
- From outside, probe ports 25, 465, 587 and 993 and the expiry of the certificate on 993 (e.g. a Prometheus
  blackbox exporter with `tcp_connect` and `tls` modules).
- Watch the Postfix queue: `docker compose exec postfix-mailcow mailq`. A growing queue means outgoing mail is
  refused (blocklist, port 25, receiver issue).

## Sending from your applications

Instead of a paid sending service, applications can send through the server:

1. Create a dedicated mailbox, e.g. `noreply@client-a.org` (`05-add-mailbox.sh`).
2. In the application: host `mail.example.com`, port 587, STARTTLS, that address and its password.
3. The domain's SPF and DKIM already cover it.

For applications running in Docker on the same server, use the public name (`mail.example.com`), not a container
name: the certificate is issued for it. Keep the volume reasonable (transactional mail): for bulk newsletters, a
dedicated sending service protects the reputation of your IP.

## Hardening DMARC

1. Start with `p=none` and `rua=mailto:postmaster@domain`: receivers send daily XML reports.
2. After a few weeks, check that every legitimate sender passes SPF or DKIM (a report viewer such as
   *parsedmarc* or an online DMARC analyzer helps).
3. Move to `p=quarantine`, then to `p=reject`. Change `DMARC_POLICY` in `config.env` and run
   `04-dns-gandi.sh` again, or edit the `_dmarc` record by hand.

## Rotating a DKIM key

mailcow admin → Configuration → ARC/DKIM keys: generate a new key with a new selector (e.g. `dkim2026`), publish it,
wait 48 h, switch the domain to it, then remove the old record a week later.

## Useful commands

```bash
cd /opt/mailcow-dockerized
docker compose ps                                    # state of the containers
docker compose logs -f --tail=100 postfix-mailcow    # live SMTP log
docker compose exec postfix-mailcow postqueue -f     # retry the queue now
docker compose exec dovecot-mailcow doveadm quota get -u user@domain
```
