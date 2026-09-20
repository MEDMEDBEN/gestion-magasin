# Déploiement — guide complet

## Ce que tu dois fournir avant de déployer

| Élément | Détail | Où ça sert |
|---|---|---|
| **VPS** | Minimum recommandé pour ce volume : 2 vCPU / 4 Go RAM / 50-80 Go SSD (ex: offre "starter" chez OVH, Hetzner, DigitalOcean) | Héberge tout (backend + DB + fichiers) |
| **Système du VPS** | Ubuntu 22.04 LTS (le plus simple à supporter) | — |
| **Nom de domaine** | 1 domaine acheté (ex: chez OVH, Namecheap) — ex: `tondomaine.com` | HTTPS + accès stable (pas juste une IP) |
| **Sous-domaine DNS** | `api.tondomaine.com` → IP du VPS (enregistrement DNS de type A) | Seul le backend est publié. MinIO n'est PAS exposé : le backend sert les fichiers lui-même |
| **Accès SSH au VPS** | Clé SSH générée par toi, ajoutée au VPS à la création | Pour déployer et administrer |
| **Email valide** | Pour Let's Encrypt (certificats HTTPS gratuits) | Notifications d'expiration de certificat |

## Ce qui est déjà préparé dans `infra/`

```
infra/
├── docker-compose.yml         ← production (VPS uniquement)
├── docker-compose.dev.yml     ← dev local (PostgreSQL/Redis/MinIO seulement)
├── .env.example               ← variables à remplir, copier en `.env`
└── .env.minio-root.example    ← compte ADMIN de MinIO, copier en `.env.minio-root`
```

Le compte **root** de MinIO est dans un fichier SÉPARÉ, chargé uniquement par MinIO et par le service
de provisionnement `minio-init`. Le backend ne le reçoit jamais : il utilise un **compte de service
limité au seul bucket**, créé automatiquement au premier démarrage.

**Traefik** gère automatiquement le HTTPS (renouvellement de certificat inclus) — pas besoin de configurer nginx/certbot à la main.

## Comment tout est relié

```
Internet
   │
   ▼
Nom de domaine (DNS → IP du VPS)
   │
   ▼
Traefik (ports 80/443, HTTPS auto)
   │
   └── api.tondomaine.com → backend NestJS (port 3000 interne)
                                │
                backend ────────┼──── PostgreSQL (jamais exposé publiquement)
                                ├──── Redis      (jamais exposé publiquement)
                                └──── MinIO      (jamais exposé publiquement)
```

PostgreSQL, Redis et MinIO ne sont **jamais accessibles depuis l'extérieur** — uniquement via le réseau
interne Docker, seul le backend leur parle. Les images de produits transitent par le backend, qui vérifie
les droits : aucune URL de stockage n'est distribuée. Un seul port ouvert sur Internet, c'est autant de
surface d'attaque en moins.

## Étapes de déploiement (une fois le code prêt)

1. Créer le VPS, pointer le DNS des deux sous-domaines vers son IP
2. `ssh` sur le VPS, installer Docker + Docker Compose
3. Cloner le repo Git sur le VPS
4. Copier `infra/.env.example` → `infra/.env` ET `infra/.env.minio-root.example` → `infra/.env.minio-root`,
   remplir toutes les valeurs (mots de passe, clés JWT générées aléatoirement). **`STORE_NAME`, `STORE_NIF`, `STORE_RC`** (et NIS/AI/adresse/téléphone) : sans NIF ni RC, les factures PDF sont refusées.
   Le backend **refuse de démarrer** si `JWT_ACCESS_SECRET` vaut la valeur d'exemple ou fait moins de 32 octets
   (`openssl rand -base64 48`). Garder **`TRUST_PROXY_HOPS=1`** (Traefik est le seul proxy) : sans lui, le quota
   anti-brute-force est partagé par tous les clients et l'audit enregistre l'IP de Traefik ; ne jamais mettre plus
   que le nombre réel de proxys.
5. `cd infra && docker compose up -d --build`
6. Vérifier que `https://api.tondomaine.com` répond (Traefik doit avoir généré le certificat automatiquement en quelques secondes)
7. **Rien à lancer à la main** : au démarrage, le conteneur applique les migrations (`prisma migrate deploy`)
   PUIS le seed (`node dist/seed.js`). Le seed est idempotent, fait autorité sur les permissions des rôles
   (ex. `cost.read` ajoutée le 2026-09-14 : sans re-seed, le magasinier ne voit pas le coût d'achat) et crée
   le **premier compte administrateur** (`SEED_ADMIN_EMAIL` / `SEED_ADMIN_PASSWORD`) — sans lui personne ne
   pourrait se connecter, il n'y a pas d'inscription publique. Vérifié sur une base vierge : le conteneur
   démarre, migre, seede, et l'admin se connecte.

## Gestion des sessions / authentification

Le projet est **stateless côté serveur** (pas de session stockée en mémoire) :
- **Access token JWT** (15 min) : envoyé à chaque requête, vérifié par signature, jamais stocké côté serveur
- **Refresh token** (90 jours glissants, opaque) : stocké **hashé** (SHA-256) dans la table PostgreSQL `RefreshToken`, avec une date d'expiration et un lien vers l'utilisateur/appareil ; rotation à chaque usage, rejeu = toutes les sessions fermées (et tracé)

**Pourquoi une table plutôt que juste un JWT refresh** : ça permet de **révoquer une session précise** (ex: employé qui quitte, téléphone volé) sans attendre l'expiration naturelle — chose impossible avec un JWT refresh pur, qui reste valide jusqu'à expiration même si tu "déconnectes" l'utilisateur ailleurs.

**Sur le desktop et le mobile** : le refresh token est stocké de façon sécurisée (`flutter_secure_storage`, chiffré par l'OS), jamais en clair dans une base locale Drift classique.

## Sauvegardes (critique, ne pas oublier)

Ajouter un cron sur le VPS pour un dump PostgreSQL quotidien :
```bash
docker compose exec -T postgres pg_dump -U magasin_prod gestion_magasin > backup_$(date +%F).sql
```
À stocker hors du VPS lui-même (ex: envoyé vers un stockage externe) — un backup sur la même machine que la prod ne protège pas contre une panne du VPS.

## Structure complète du projet (vue d'ensemble finale)

```
gestion-magasin/
├── backend/                    ← NestJS
│   ├── src/
│   ├── prisma/schema.prisma
│   ├── test/
│   └── Dockerfile
├── app/                        ← Flutter (desktop + mobile, un seul code)
│   ├── lib/
│   └── test/
├── infra/                      ← tout le déploiement
│   ├── docker-compose.yml
│   ├── docker-compose.dev.yml
│   ├── .env.example
│   └── traefik/                ← certificats générés automatiquement (ne pas committer)
├── docs/                       ← plan, tasks, context, ce guide
│   ├── plan.md
│   ├── tasks.md
│   ├── context.md
│   └── DEPLOYMENT.md
├── .claude/                    ← config Claude Code
│   ├── settings.json
│   ├── agents/
│   └── commands/
├── CLAUDE.md
└── .gitignore                  ← DOIT exclure : .env, infra/traefik/letsencrypt, node_modules, build/
```

**Pas d'autre dossier nécessaire** pour ce projet à ce stade — cette structure couvre les 4 couches (front, back, infra, doc/gouvernance de projet). Si le projet grandit plus tard (P2/P3 avec e-commerce), un dossier `packages/` (code partagé entre plusieurs apps) pourrait devenir utile, mais ce serait prématuré de le créer maintenant.

## Application Android — signature de production

La release n'est **plus signée avec la clé de debug**. Avant le premier `flutter build apk --release` :

1. Créer le magasin de clés **une seule fois**, et le **sauvegarder** (perdu, plus aucune mise à jour de
   l'application n'est possible — il faut republier sous une nouvelle identité) :
   ```
   keytool -genkeypair -v -keystore gestion-magasin.jks -storetype PKCS12 \
     -keyalg RSA -keysize 2048 -validity 10000 -alias gestion-magasin
   ```
2. Copier `app/android/key.properties.example` → `app/android/key.properties` et y mettre le chemin du
   magasin de clés et les mots de passe. Ce fichier et les `*.jks` sont **ignorés par Git** : ils ne
   quittent jamais la machine de build.
3. Sans `key.properties`, le build release échoue — c'est voulu : aucune APK signée avec une clé de test
   ne doit sortir d'ici.
