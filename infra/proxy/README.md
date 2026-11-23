# Socle commun du VPS — un Traefik + un Nginx pour tous les sites

```
Internet ──► Traefik (ports 80/443, HTTPS Let's Encrypt automatique)
                └──► Nginx (un fichier par site)
                       ├─ fichiers web       → /opt/proxy/sites/<domaine>/
                       └─ /api/… (option)    → backend de l'appli (réseau « proxy »)
```

- **Traefik** : seule porte d'entrée. Il obtient et renouvelle les certificats, redirige
  http → https, ajoute HSTS, et envoie TOUT à Nginx. Ses routes sont dans
  `traefik/dynamic/` (un fichier par domaine) : il n'a pas accès à Docker.
- **Nginx** : un seul pour tous les sites. Un fichier par domaine dans `nginx/conf.d/`.
  Il sert les fichiers du site et redirige un préfixe (ex. `/api/`) vers le backend.
- **Réseau `proxy`** : réseau Docker commun. Une appli qui a un backend y branche
  son conteneur ; sa base de données, elle, n'y va JAMAIS.

## Arborescence

| Chemin | Rôle |
|---|---|
| `docker-compose.yml` | Traefik + Nginx |
| `.env` | `ACME_EMAIL` (copie de `.env.example`) |
| `traefik/dynamic/_common.yml` | service Nginx + en-tête HSTS (commun) |
| `traefik/dynamic/<domaine>.yml` | route HTTPS d'un domaine |
| `nginx/conf.d/00-common.conf` | réglages communs, domaine inconnu refusé |
| `nginx/conf.d/<domaine>.conf` | le site (fichiers + redirections) |
| `nginx/snippets/` | morceaux réutilisables (appli web, proxy, en-têtes) |
| `sites/<domaine>/` | fichiers web servis |
| `letsencrypt/acme.json` | certificats (privé, ne pas partager) |
| `install.sh` | premier démarrage |
| `add-site.sh` | ajouter un site |

## 1. Installation (une fois)

```bash
cd /gestion-magasin && git pull
sudo cp -r /gestion-magasin/infra/proxy /opt/proxy
cd /opt/proxy
cp .env.example .env && nano .env        # ACME_EMAIL=ton.email@…
chmod +x install.sh add-site.sh
```

## 2. Passer gestion-magasin sur le socle (depuis l'ancien Traefik du projet)

**Les données ne partent pas** : la base et les fichiers sont dans les volumes
Docker `infra_postgres_data` et `infra_backend_storage`. L'ancien et le nouveau
compose utilisent les mêmes (nom de projet figé : `name: infra`). `down` arrête
les conteneurs sans toucher aux volumes ; seul `down -v` les efface — ne JAMAIS
l'utiliser. Par prudence, une sauvegarde avant de commencer :
```bash
cd /gestion-magasin/infra
docker volume ls | grep infra_                     # infra_postgres_data doit exister
docker compose -f docker-compose.standalone.yml exec -T postgres \
  sh -c 'pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"' > ~/sauvegarde-$(date +%F).sql
ls -lh ~/sauvegarde-*.sql                          # le fichier ne doit pas être vide
```

```bash
# a0. Arrêter l'ancien portfolio (il est sur le réseau de l'ancien Traefik).
#     AVANT son git pull : c'est l'ancien fichier qui connaît ses conteneurs.
cd /portfolio && docker compose down

# a. Arrêter l'ancien Traefik et l'ancien Nginx du projet (libère 80/443).
#    Les DONNÉES restent : jamais « -v ».
cd /gestion-magasin/infra
docker compose -f docker-compose.standalone.yml down

# b. Garder les certificats déjà obtenus (évite de les redemander).
sudo cp /gestion-magasin/infra/traefik/letsencrypt/acme.json /opt/proxy/letsencrypt/acme.json

# c. Démarrer le socle (crée le réseau « proxy »).
cd /opt/proxy && ./install.sh

# d. Dans /gestion-magasin/infra/.env, ajouter :
#      SITES_DIR=/opt/proxy/sites
#    (TRUST_PROXY_HOPS est fixé à 2 par le compose, rien à faire.)

# e. Relancer le magasin : backend + publication de la version web.
cd /gestion-magasin/infra
docker compose up -d --build --remove-orphans

# f. Relancer le portfolio sur le socle (site publié + API de simulation).
#    Sa conf est déjà là : nginx/conf.d/mohamedbennabi.tech.conf (+ www → racine)
#    et traefik/dynamic/mohamedbennabi.tech.yml.
cd /portfolio && git pull
docker compose up -d --build --remove-orphans
```

Vérifier :
```bash
docker compose -f /opt/proxy/docker-compose.yml ps     # traefik et nginx « running »
docker compose ps                                       # backend + postgres « running », web « exited (0) »
ls /opt/proxy/sites/elec.mohamedbennabi.tech            # index.html, main.dart.js…
curl -I https://elec.mohamedbennabi.tech                # HTTP/2 200
curl -I https://mohamedbennabi.tech                     # HTTP/2 200 (portfolio)
curl -s https://mohamedbennabi.tech/api/health          # {"status":"ok",…}
```
Le service `web` s'arrête après avoir publié les fichiers : c'est normal (le Nginx
commun les sert). Chaque `docker compose up -d --build` republie la version web.

**Retour arrière** si besoin : `cd /opt/proxy && docker compose down`, puis
`cd /gestion-magasin/infra && docker compose -f docker-compose.standalone.yml up -d --build`.

## 3. Ajouter un site

Prérequis : l'enregistrement **DNS A** du domaine pointe vers l'IP du VPS.

**Site web seul** (vitrine, HTML, appli React/Vue/Flutter déjà compilée) :
```bash
cd /opt/proxy
./add-site.sh blog.mondomaine.com
cp -r /chemin/de/mon/site/* sites/blog.mondomaine.com/
```

**Appli avec un backend** : dans le `docker-compose.yml` de l'appli, branchez le backend
sur le réseau `proxy` avec un nom UNIQUE :
```yaml
services:
  api:
    # …
    networks:
      default: {}
      proxy:
        aliases: [shop-backend]
networks:
  proxy:
    name: proxy
    external: true
```
puis :
```bash
cd /opt/proxy
./add-site.sh shop.mondomaine.com shop-backend:8080          # /api/ → shop-backend:8080
./add-site.sh admin.mondomaine.com admin-api:3000 /backend/   # autre préfixe
./add-site.sh app.mondomaine.com mon-app:3000 /               # TOUT vers le conteneur
```
Le dernier cas (préfixe `/`) est pour une appli qui sert elle-même ses pages
(Next.js, WordPress, Odoo…) : aucun dossier `sites/` n'est créé.

**Où mettre le `.env` de chaque projet** : dans le dossier du projet, à côté de
son `docker-compose.yml` (ex. `/gestion-magasin/infra/.env`, `/shop/.env`). Le
socle n'a que le sien (`/opt/proxy/.env` : `ACME_EMAIL`). Les `.env` ne vont
jamais dans git (secrets) : on garde un `.env.example` sans valeurs réelles.

Le script crée `nginx/conf.d/<domaine>.conf`, `traefik/dynamic/<domaine>.yml` et
`sites/<domaine>/`, vérifie Nginx (`nginx -t`) puis le recharge. Le certificat HTTPS
est obtenu au premier accès au site.

**Règles :**
1. Un alias de backend par appli, jamais deux fois le même (`magasin-backend`, `shop-backend`…).
2. Les bases de données ne rejoignent jamais le réseau `proxy`.
3. Modifier un site à la main : éditer son `.conf`, puis
   `docker compose exec nginx nginx -t && docker compose exec nginx nginx -s reload`.
4. Retirer un site : supprimer ses fichiers `nginx/conf.d/<domaine>.conf` et
   `traefik/dynamic/<domaine>.yml`, puis recharger Nginx.

## Commandes utiles

```bash
cd /opt/proxy
docker compose logs -f traefik        # certificats, routes
docker compose logs -f nginx          # requêtes, erreurs 502 (backend arrêté)
docker compose exec nginx nginx -t    # tester la configuration
docker compose pull && docker compose up -d   # mettre à jour Traefik / Nginx
```
