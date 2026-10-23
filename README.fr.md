# mailcow-behind-apache

**Héberger soi-même ses e-mails (et ceux de ses clients) avec [mailcow](https://mailcow.email) sur un VPS qui fait déjà tourner d'autres sites derrière Apache.**

[English version](README.md)

L'installation officielle de mailcow suppose qu'il occupe seul les ports 80/443 et la machine. Sur un VPS partagé,
Apache sert déjà vos sites et certbot gère déjà les certificats. Ces scripts installent mailcow *à côté* :

```
                 Internet
                    │
        ┌───────────┴────────────────────────────────────┐
        │ 80/443                  25 465 587 993 995 4190 │
        ▼                                     ▼
   Apache + certbot  ──proxy──▶  127.0.0.1:8443   mailcow (Postfix, Dovecot, Rspamd,
   (vos autres sites)            nginx-mailcow    webmail SOGo, ClamAV) sous Docker
        │                                     ▲
        └── le hook certbot copie chaque certificat renouvelé ──┘
```

- **Apache garde 80/443.** Le serveur web de mailcow n'écoute qu'en local ; Apache lui transmet l'administration,
  le webmail SOGo, ActiveSync et l'autodiscover.
- **Un seul certificat, géré par certbot.** Un hook copie chaque renouvellement dans mailcow : SMTP et IMAP ne
  présentent jamais un certificat expiré pendant que le site, lui, paraît normal.
- **Plusieurs domaines, un serveur.** `mail.exemple.com` héberge les boîtes de `client-a.org`, `client-b.net`…
  Chaque client peut garder `webmail.client-a.org`, redirigé vers le webmail commun.
- **Un DNS propre.** MX, un seul SPF fusionné, DKIM (2048 bits), DMARC et SRV sont générés, et peuvent être publiés
  automatiquement chez Gandi LiveDNS (zone sauvegardée avant).
- **Sans danger pour un serveur chargé.** Vérifications préalables (ports, sous-réseaux Docker, port 25 sortant,
  DNS inverse) et limites mémoire pour chaque conteneur mailcow.

Écrit à partir d'une vraie migration : 5 domaines quittant un service de messagerie hébergé pour un VPS de 48 Go
qui fait aussi tourner une centaine d'autres conteneurs. Tout ce qui a coincé est dans
[docs/fr/pieges.md](docs/fr/pieges.md).

## Prérequis

| | |
|---|---|
| Système | Debian 12 / Ubuntu 22.04+ (les autres Linux avec systemd devraient convenir) |
| Déjà installés | Docker Engine + plugin compose, Apache 2.4, certbot avec le plugin Apache, `git curl openssl dnsutils jq` |
| Mémoire | 6 Go libres pour mailcow (4 Go sans ClamAV) |
| Réseau | Une IPv4 publique fixe, **le port 25 sortant ouvert** (certains hébergeurs le bloquent), ports 25, 465, 587, 143, 993, 110, 995, 4190 libres |
| DNS | Un enregistrement A pour le nom du serveur mail, et le **DNS inverse (PTR)** de l'IP réglé sur ce nom chez l'hébergeur |

## Démarrage rapide

```bash
git clone https://github.com/BorisGautier/mailcow-behind-apache.git
cd mailcow-behind-apache
cp config.example.env config.env && nano config.env      # nom, IP, fuseau, sous-réseau Docker libre...

sudo ./scripts/00-preflight.sh          # vérifications seulement, ne modifie rien
sudo ./scripts/01-install-mailcow.sh    # mailcow sur 127.0.0.1:8080/8443, réseau dédié, limites
sudo ./scripts/02-apache-proxy.sh       # vhost Apache, certificat Let's Encrypt, hook de copie
# se connecter à https://mail.exemple.com/admin (admin / moohoo) : changer le mot de passe, activer la 2FA

sudo ./scripts/03-add-domain.sh client-a.org          # domaine + DKIM, affiche les enregistrements DNS
sudo ./scripts/04-dns-gandi.sh client-a.org           # facultatif : les publier chez Gandi LiveDNS
sudo ./scripts/05-add-mailbox.sh contact@client-a.org "Contact"
sudo ./scripts/06-webmail-redirects.sh client-a.org   # facultatif : webmail.client-a.org -> webmail commun
sudo ./scripts/check.sh                               # vérification complète (à mettre aussi en cron)
```

Tous les scripts peuvent être relancés : ils réappliquent leurs réglages sans rien dupliquer.

## Les scripts

| Script | Rôle |
|---|---|
| `00-preflight.sh` | Mémoire/disque, outils, modules Apache, ports libres, port 25 sortant, sous-réseau Docker libre, enregistrements A et PTR. Ne modifie rien. |
| `01-install-mailcow.sh` | Clone mailcow, génère `mailcow.conf`, l'attache à l'interface locale, coupe son client ACME, règle le sous-réseau Docker, l'IPv6, ClamAV, l'API (hôte uniquement) et les limites, télécharge et démarre. |
| `02-apache-proxy.sh` | Active les modules Apache, obtient le certificat (ajoute autodiscover/autoconfig seulement s'ils pointent ici), écrit le vhost, installe le hook certbot et l'exécute une fois. |
| `03-add-domain.sh` | Crée le domaine et sa clé DKIM via l'API mailcow et affiche tous les enregistrements DNS. |
| `04-dns-gandi.sh` | Sauvegarde la zone puis publie MX, SPF fusionné, DKIM (découpé en chaînes de 255 caractères), DMARC, SRV et le CNAME `webmail`. Demande confirmation avant de remplacer un MX existant. Vérifie sur les serveurs faisant autorité. |
| `05-add-mailbox.sh` | Crée une boîte avec un mot de passe aléatoire, enregistré dans un fichier lisible par root seulement. |
| `06-webmail-redirects.sh` | `webmail.<client>` → webmail commun, avec son propre certificat. |
| `check.sh` | Conteneurs, arrêts pour manque de mémoire, ports, file d'attente, expiration des certificats sur 465/587/993, PTR, listes noires, et pour chaque domaine MX/SPF/DKIM (comparé à la clé de mailcow)/DMARC. `--send-test` envoie un vrai message. |

## Documentation

- [Les pièges rencontrés et leurs solutions](docs/fr/pieges.md)
- [Migrer un domaine depuis un autre hébergeur](docs/fr/migration.md) (sans perdre de mails)
- [Exploitation](docs/fr/exploitation.md) : sauvegardes, mises à jour, supervision, envoi depuis vos applications, durcissement DMARC

## Sécurité

- `config.env` (jeton Gandi) et le fichier des mots de passe ne sont jamais commités (`.gitignore`). Gardez-les lisibles par root seulement.
- La clé d'API mailcow générée à l'installation n'accepte que les requêtes venant du serveur lui-même.
- Changez le mot de passe administrateur par défaut et activez la double authentification dès l'installation.

## Licence

[MIT](LICENSE). mailcow est sous GPL-3.0 et se télécharge depuis son dépôt officiel au moment de l'installation.
