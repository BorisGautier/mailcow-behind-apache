# Migrating a domain from another provider

Goal: move `client-a.org` from its current mail provider to your server without losing a message.

## 1. One day before: lower the TTLs

At the current DNS provider, set the TTL of the MX and SPF records to 300 seconds. Wait for the old TTL
(often 3600 s or more) so that the switch later propagates in minutes.

## 2. Inventory what exists

- **Mailboxes**: list them in the old provider's panel (or its API: Gandi `GET /v5/email/mailboxes/<domain>`).
- **Aliases and forwards** (`contact@` → someone's personal address…): recreate them in mailcow
  (*Email → Configuration → Aliases*).
- **Who sends as the domain**: website contact forms, newsletters, CRM, billing… Their SPF mechanisms must stay
  in the new SPF (`SPF_EXTRA`), or they must be moved to authenticated SMTP on your server.

## 3. Prepare the server (no impact yet)

```bash
sudo ./scripts/03-add-domain.sh client-a.org
sudo ./scripts/05-add-mailbox.sh jane@client-a.org "Jane Doe" 5120 --force-password-change
```

As long as the MX has not changed, nothing reaches the new mailboxes. You can publish the DKIM and DMARC records
now: they do not affect delivery to the old provider.

## 4. Copy the existing mail (first pass)

In mailcow, for each mailbox: *Email → Configuration → Sync jobs → Create*, with the old IMAP server and the user's
old password. It runs imapsync in the background and copies folders and flags.

For many boxes, imapsync can also be run directly:

```bash
docker run --rm gilleslamiral/imapsync imapsync \
  --host1 imap.old-provider.net --user1 jane@client-a.org --password1 'OLD' \
  --host2 mail.example.com      --user2 jane@client-a.org --password2 'NEW' \
  --automap --syncinternaldates
```

## 5. Switch

```bash
sudo ./scripts/04-dns-gandi.sh client-a.org      # or publish the records printed by 03 by hand
```

Then run the sync jobs once more (second pass): it copies only what arrived at the old provider during
propagation.

## 6. Check

```bash
sudo ./scripts/check.sh
TEST_SMTP_USER=jane@client-a.org TEST_SMTP_PASS='...' sudo -E ./scripts/check.sh --send-test you@gmail.com
```

In Gmail, open the test message → *Show original*: SPF, DKIM and DMARC must all be `PASS`.
Reply to it to test incoming mail.

## 7. Afterwards

- Keep the old mailboxes for two weeks (late mail from senders with stale DNS caches), then close them.
- Configure users' phones and mail clients: server `mail.example.com`, IMAP 993 SSL, SMTP 587 STARTTLS,
  full email address as username. Autodiscover (SRV records) fills this in automatically for most clients.
- Read the DMARC reports for a few weeks, then tighten the policy (see [operations](operations.md)).
