# Hébergeurs DNS

`04-dns-publish.sh` publie les enregistrements mail d'un domaine là où sa zone DNS est hébergée. Le fournisseur se
choisit dans `config.env` (`DNS_PROVIDER`), ou à chaque lancement avec `--provider` quand les domaines de vos clients
sont chez plusieurs hébergeurs.

Quel que soit le fournisseur, le script :

1. sauvegarde les enregistrements actuels dans `/root/dns-backups/<domaine>-<fournisseur>-<date>.json` ;
2. demande confirmation avant de remplacer un MX existant (cela déplace les mails du domaine vers votre serveur) ;
3. remplace l'ancien SPF et **conserve les autres TXT de l'apex** (vérifications de site…) ; les expéditeurs autorisés
   par l'ancien SPF (`include:` de newsletter, formulaire, SaaS) sont listés, et gardés seulement avec
   `--spf-extra "include:..."` (par domaine) ou `SPF_EXTRA` (tous les domaines), après confirmation ;
4. publie MX, SPF, DKIM, DMARC, les SRV d'autodiscover/IMAP/SMTP et le CNAME `webmail` ;
5. vérifie sur les serveurs faisant autorité du domaine que MX, SPF, DKIM et DMARC sont bien servis.

| `DNS_PROVIDER` | Hébergeurs | Identifiants dans `config.env` |
|---|---|---|
| `gandi` | Gandi LiveDNS | `GANDI_PAT` : jeton d'accès personnel, permission *Gérer la configuration technique des domaines* |
| `cloudflare` | Cloudflare | `CLOUDFLARE_API_TOKEN` : jeton d'API avec *Zone:Read* et *DNS:Edit* sur les zones |
| `lexicon` | plus de 100 hébergeurs via [dns-lexicon](https://github.com/dns-lexicon/dns-lexicon) | `LEXICON_PROVIDER` + `LEXICON_<FOURNISSEUR>_<OPTION>` |
| `manual` | tous les autres (panneau du registrar, de l'hébergeur web, BIND maison…) | aucun |

## Gandi

Créez le jeton dans *Organisation → Partage → Jetons d'accès personnels*, limité aux domaines gérés. Gandi répond
parfois « mis à jour » sans servir la nouvelle valeur TXT ; le script le détecte et republie avec un autre TTL, ce qui
force la publication.

## Cloudflare

*Mon profil → Jetons d'API → Créer un jeton → Modifier le DNS de la zone*, en ajoutant *Zone:Read*. Les
enregistrements sont créés en mode « DNS uniquement » : le mail ne passe jamais par le proxy de Cloudflare, et le
CNAME `webmail` ne doit pas l'être non plus (le certificat est celui de votre serveur).

## dns-lexicon (OVH, AWS Route 53, GoDaddy, Namecheap, Infomaniak, DigitalOcean, Hetzner, Scaleway…)

```bash
pipx install dns-lexicon            # ou : pip install dns-lexicon
lexicon --help                      # liste des fournisseurs
lexicon ovh --help                  # options d'un fournisseur
```

Chaque option devient une variable `LEXICON_<FOURNISSEUR>_<OPTION>` dans `config.env`. Exemple OVH (créer les clés sur
<https://eu.api.ovh.com/createToken/> avec GET/POST/PUT/DELETE sur `/domain/zone/*`) :

```bash
DNS_PROVIDER=lexicon
LEXICON_PROVIDER=ovh
LEXICON_OVH_AUTH_ENTRYPOINT=ovh-eu
LEXICON_OVH_AUTH_APPLICATION_KEY=...
LEXICON_OVH_AUTH_APPLICATION_SECRET=...
LEXICON_OVH_AUTH_CONSUMER_KEY=...
```

Route 53 : `LEXICON_PROVIDER=route53` avec `LEXICON_ROUTE53_AUTH_ACCESS_KEY` / `LEXICON_ROUTE53_AUTH_ACCESS_SECRET`.
Les fournisseurs gèrent certains détails différemment (priorité MX, longs TXT) : lancez `scripts/check.sh` après la
publication, il compare ce qui est servi avec ce que mailcow attend.

## Manuel (tout autre hébergeur DNS)

```bash
sudo ./scripts/04-dns-publish.sh client-a.org --provider manual
```

Rien n'est modifié : le script lit les enregistrements actuels par le DNS, fusionne le SPF avec les TXT existants et
écrit `/root/dns-backups/<domaine>-mail-records-<date>.zone` :

```
@                        3600 IN MX    10 mail.exemple.com.
@                        3600 IN TXT   "google-site-verification=..."
@                        3600 IN TXT   "v=spf1 mx a:mail.exemple.com ~all"
dkim._domainkey          3600 IN TXT   "v=DKIM1;k=rsa;t=s;s=email;p=MIIBIjANBg..." "...IDAQAB"
...
```

Recréez ces enregistrements dans le panneau de l'hébergeur, en remplaçant ceux de même nom et de même type, puis lancez
`scripts/check.sh`. La plupart des panneaux acceptent la longue valeur DKIM collée d'un seul bloc (sans les guillemets).

## Ajouter un fournisseur

Un fournisseur est un fichier `scripts/dns/<nom>.sh` avec cinq fonctions (voir le contrat en tête de
`scripts/dns/engine.sh`) : `dns_check_config`, `dns_backup FICHIER`, `dns_get NOM TYPE`,
`dns_set NOM TYPE TTL VALEUR...` et, en option, `dns_republish NOM TYPE`. `tests/fake-dns.sh` est un exemple complet
utilisé par les tests. Les contributions sont les bienvenues.

## MTA-STS (chiffrement imposé entre serveurs de messagerie)

`04-dns-publish.sh` publie aussi `mta-sts.<domaine>` (CNAME vers le serveur mail), `_mta-sts` (identifiant de la
politique) et `_smtp._tls` (rapports TLS envoyés à l'adresse des rapports DMARC). La politique elle-même doit être
servie en HTTPS à `https://mta-sts.<domaine>/.well-known/mta-sts.txt`, par exemple par Apache avec un seul certificat
pour tous les domaines :

```
version: STSv1
mode: testing
mx: mail.exemple.com
max_age: 604800
```

Commencez en `mode: testing` (les destinataires signalent seulement les problèmes), lisez les rapports TLS quelques
semaines, puis passez en `mode: enforce` et changez `MTA_STS_ID` dans `config.env` (n'importe quelle nouvelle valeur)
pour que les expéditeurs rechargent la politique.
