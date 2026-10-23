# Migrer un domaine depuis un autre hébergeur

Objectif : passer `client-a.org` de son fournisseur de messagerie actuel à votre serveur sans perdre un seul message.

## 1. La veille : baisser les TTL

Chez l'hébergeur DNS actuel, régler le TTL des enregistrements MX et SPF à 300 secondes. Attendre la durée de l'ancien
TTL (souvent 3600 s ou plus) pour que la bascule se propage ensuite en quelques minutes.

## 2. Faire l'inventaire

- **Boîtes** : les lister dans l'espace client de l'ancien fournisseur (ou via son API : Gandi
  `GET /v5/email/mailboxes/<domaine>`).
- **Alias et redirections** (`contact@` → adresse personnelle de quelqu'un…) : les recréer dans mailcow
  (*E-mail → Configuration → Alias*).
- **Qui envoie au nom du domaine** : formulaire de contact du site, newsletter, CRM, facturation… Leurs mécanismes SPF
  doivent rester dans le nouveau SPF (`SPF_EXTRA`), ou ces outils doivent passer par le SMTP authentifié de votre
  serveur.

## 3. Préparer le serveur (sans impact)

```bash
sudo ./scripts/03-add-domain.sh client-a.org
sudo ./scripts/05-add-mailbox.sh jeanne@client-a.org "Jeanne Dupont" 5120 --force-password-change
```

Tant que le MX n'a pas changé, rien n'arrive dans les nouvelles boîtes. On peut déjà publier DKIM et DMARC : ils ne
gênent pas la distribution chez l'ancien fournisseur.

## 4. Copier les mails existants (premier passage)

Dans mailcow, pour chaque boîte : *E-mail → Configuration → Tâches de synchronisation → Créer*, avec l'ancien serveur
IMAP et l'ancien mot de passe de l'utilisateur. imapsync tourne en arrière-plan et copie dossiers et marqueurs.

Pour beaucoup de boîtes, on peut aussi lancer imapsync directement :

```bash
docker run --rm gilleslamiral/imapsync imapsync \
  --host1 imap.ancien-hebergeur.net --user1 jeanne@client-a.org --password1 'ANCIEN' \
  --host2 mail.exemple.com          --user2 jeanne@client-a.org --password2 'NOUVEAU' \
  --automap --syncinternaldates
```

## 5. Basculer

```bash
sudo ./scripts/04-dns-publish.sh client-a.org      # ou publier à la main les enregistrements affichés par 03
```

Puis relancer les synchronisations une dernière fois (second passage) : elles ne copient que ce qui est arrivé chez
l'ancien fournisseur pendant la propagation.

## 6. Vérifier

```bash
sudo ./scripts/check.sh
TEST_SMTP_USER=jeanne@client-a.org TEST_SMTP_PASS='...' sudo -E ./scripts/check.sh --send-test vous@gmail.com
```

Dans Gmail, ouvrir le message de test → *Afficher l'original* : SPF, DKIM et DMARC doivent tous être `PASS`.
Y répondre pour tester la réception.

## 7. Ensuite

- Garder les anciennes boîtes deux semaines (mails tardifs d'expéditeurs au cache DNS périmé), puis les fermer.
- Configurer téléphones et logiciels : serveur `mail.exemple.com`, IMAP 993 SSL, SMTP 587 STARTTLS, adresse complète
  comme identifiant. L'autodiscover (enregistrements SRV) remplit cela automatiquement pour la plupart des logiciels.
- Lire les rapports DMARC quelques semaines, puis durcir la politique (voir [exploitation](exploitation.md)).
