# Les pièges rencontrés et leurs solutions

Chaque point s'est réellement produit lors d'une installation sur un VPS partagé. Les scripts les gèrent tous.

## Serveur et Docker

**1. Plus de sous-réseau Docker libre.** mailcow utilise `172.22.1.0/24` par défaut. Sur un serveur avec beaucoup de
projets compose, toutes les plages `172.17-31.x` peuvent être prises, et `docker compose up` échoue avec
*« Pool overlaps with other one on this address space »*. → Régler `MAILCOW_IPV4_NETWORK` sur une plage libre
(par ex. `10.77.1`). `00-preflight.sh` liste les sous-réseaux utilisés.

**2. « denied » en téléchargeant des images publiques.** Un ancien `docker login ghcr.io` dans
`~/.docker/config.json` de root fait envoyer de mauvais identifiants, même pour des images *publiques*.
→ `01-install-mailcow.sh` télécharge avec un `DOCKER_CONFIG` vide, sans toucher à vos connexions existantes.

**3. Mémoire insuffisante.** ClamAV seul consomme ~1 Go, jusqu'à ~2 Go pendant le rechargement des signatures. Sur un
serveur chargé, le noyau tue alors un conteneur au hasard. → `templates/docker-compose.override.yml` limite chaque
conteneur mailcow ; `check.sh` signale les conteneurs tués par manque de mémoire. Sans antivirus :
`MAILCOW_SKIP_CLAMD=y`.

**4. IPv6 à moitié configurée.** Si mailcow active l'IPv6 alors que le serveur n'a pas d'IPv6 globale (ou pas de PTR
IPv6), Postfix essaie d'abord en IPv6 et les destinataires refusent. → `MAILCOW_ENABLE_IPV6=false` tant que l'IPv6
n'est pas complète.

## Apache et certificats

**5. Apache occupe déjà 80/443.** → mailcow écoute sur `127.0.0.1:8080/8443` (`HTTP_BIND`/`HTTPS_BIND`), son client
ACME est coupé (`SKIP_LETS_ENCRYPT=y`) et Apache lui transmet les requêtes, y compris `/websocket` et
`/Microsoft-Server-ActiveSync`, avec des délais longs.

**6. Site normal, certificat mail expiré.** certbot renouvelle le certificat d'Apache, mais Postfix et Dovecot lisent
leur propre copie dans `data/assets/ssl/`. Les logiciels de messagerie échouent 90 jours plus tard. → Le hook
certbot copie chaque renouvellement et redémarre postfix, dovecot et nginx-mailcow.

**7. certbot échoue à cause d'un seul nom mort.** Un certificat qui contient encore un nom ne pointant plus vers le
serveur ne peut plus être renouvelé du tout. → Ne demander que des noms qui pointent vers le serveur (les scripts
vérifient chaque nom avant), et ajouter les autres plus tard avec `--expand`.

**8. DNS joker + vhost par défaut = alerte « Site dangereux ».** Avec `*.exemple.com` pointant vers le serveur, tout
sous-domaine inconnu est servi par le *premier* vhost d'Apache, parfois le site d'un autre client. Les navigateurs
voient alors le même site sous des noms aléatoires, ce qui ressemble à de l'hameçonnage. → Ajouter un vhost par
défaut (chargé en premier) qui répond 403 aux noms inconnus.

**9. HSTS `includeSubDomains`.** Placé sur le nom du serveur mail, il impose HTTPS à tous les sous-noms du domaine.
→ Le modèle envoie HSTS sans `includeSubDomains`.

## DNS

**10. DNS inverse (PTR).** Les hébergeurs mettent un PTR générique (par ex. `vmi123456.hebergeur.net`). Gmail et
Outlook refusent ou classent en spam les mails d'une IP dont le PTR ne correspond pas au nom du serveur. → Régler le
PTR sur `MAIL_HOSTNAME` dans l'espace client de l'hébergeur (il n'est pas dans votre zone DNS). `00-preflight.sh` et
`check.sh` le vérifient.

**11. Port 25 sortant bloqué.** Plusieurs hébergeurs cloud le bloquent par défaut ; les mails restent alors en file
d'attente. → Demander l'ouverture à l'hébergeur, ou relayer les envois par un serveur intermédiaire (admin mailcow →
Configuration → Routage).

**12. Deux enregistrements SPF.** Un domaine qui avait déjà `v=spf1 include:ancien-hebergeur ~all` et reçoit un
second SPF échoue complètement (`permerror`). → Garder exactement un TXT commençant par `v=spf1`.
`04-dns-gandi.sh` remplace l'ancien et conserve les autres TXT (vérifications de site…) ; `SPF_EXTRA` garde les
services tiers qui envoient en votre nom.

**13. MX sans point final.** Dans une zone ou certaines API DNS, `10 mail.exemple.com` (sans point final) est relatif :
il devient `mail.exemple.com.exemple.org`. → Toujours écrire `mail.exemple.com.`.

**14. DKIM de plus de 255 caractères.** Une clé de 2048 bits ne tient pas dans une seule chaîne TXT. → La découper en
plusieurs chaînes entre guillemets dans le même enregistrement (`"v=DKIM1; k=rsa; p=MIIB..." "...suite"`). Le script
Gandi le fait.

**15. Gandi LiveDNS accepte une modification mais garde l'ancien TXT.** Constaté plusieurs fois : l'API répond
« mis à jour », mais les serveurs faisant autorité servent toujours l'ancienne valeur. → Republier les mêmes valeurs
avec un autre TTL force la publication. `04-dns-gandi.sh` vérifie les serveurs faisant autorité et le fait
automatiquement.

**16. Un domaine qui reste chez un autre fournisseur.** Si `exemple.com` reste chez Google Workspace (ou autre), ne
**pas** l'ajouter à mailcow : mailcow livrerait en local les mails envoyés depuis votre serveur vers `@exemple.com`, au
lieu de les envoyer chez Google.

**17. Pas de MX = mails envoyés vers l'enregistrement A.** Les expéditeurs livrent à l'adresse A d'un domaine sans MX
(MX implicite). Avec un DNS joker, cela peut marcher par hasard, puis casser le jour où l'A change. → Toujours publier
un MX explicite.

## Scripts

**18. Un script passé par l'entrée standard s'arrête en plein milieu.** `ssh serveur 'bash -s' < script.sh` avec un
`docker compose exec -T ...` dans une boucle : la commande du conteneur lit la suite du script sur l'entrée standard et
la boucle s'arrête sans erreur après le premier tour. → Ajouter `</dev/null` aux `docker compose exec` des scripts.

**19. L'API refuse les requêtes du serveur.** Avec `API_ALLOW_FROM=127.0.0.1`, les appels au port publié arrivent
quand même sur nginx-mailcow depuis la passerelle Docker (`x.x.x.1`). → Autoriser les deux (`01-install-mailcow.sh`
le fait).
