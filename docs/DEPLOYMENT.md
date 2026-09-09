# Déploiement — guide complet

## Ce que tu dois fournir avant de déployer

| Élément | Détail | Où ça sert |
|---|---|---|
| **VPS** | Minimum recommandé pour ce volume : 2 vCPU / 4 Go RAM / 50-80 Go SSD (ex: offre "starter" chez OVH, Hetzner, DigitalOcean) | Héberge tout (backend + DB + fichiers) |
| **Système du VPS** | Ubuntu 22.04 LTS (le plus simple à supporter) | — |
| **Nom de domaine** | 1 domaine acheté (ex: chez OVH, Namecheap) — ex: `tondomaine.com` | HTTPS + accès stable (pas juste une IP) |
| **Sous-domaines DNS** | `api.tondomaine.com` → IP du VPS · `storage.tondomaine.com` → IP du VPS (enregistrements DNS de type A) | Le backend et le stockage fichiers sont séparés par sous-domaine |
| **Accès SSH au VPS** | Clé SSH générée par toi, ajoutée au VPS à la création | Pour déployer et administrer |
| **Email valide** | Pour Let's Encrypt (certificats HTTPS gratuits) | Notifications d'expiration de certificat |

## Ce qui est déjà préparé dans `infra/`

```
infra/
├── docker-compose.yml       ← production (VPS uniquement)
├── docker-compose.dev.yml   ← dev local (PostgreSQL/Redis/MinIO seulement)
└── .env.example             ← toutes les variables à remplir, copier en `.env`
```

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
   ├── api.tondomaine.com     → backend NestJS (port 3000 interne)
   └── storage.tondomaine.com → MinIO (port 9000 interne)
                                     │
                    backend ─────────┼──── PostgreSQL (jamais exposé publiquement)
                                     └──── Redis (jamais exposé publiquement)
```

PostgreSQL et Redis ne sont **jamais accessibles depuis l'extérieur** — uniquement via le réseau interne Docker, seul le backend leur parle. C'est une mesure de sécurité de base : moins de surface d'attaque exposée sur Internet.

## Étapes de déploiement (une fois le code prêt)

1. Créer le VPS, pointer le DNS des deux sous-domaines vers son IP
2. `ssh` sur le VPS, installer Docker + Docker Compose
3. Cloner le repo Git sur le VPS
4. Copier `infra/.env.example` → `infra/.env`, remplir toutes les valeurs (mots de passe, clés JWT générées aléatoirement)
5. `cd infra && docker compose up -d --build`
6. Vérifier que `https://api.tondomaine.com` répond (Traefik doit avoir généré le certificat automatiquement en quelques secondes)
7. Lancer les migrations Prisma une fois : `docker compose exec backend npx prisma migrate deploy`

## Gestion des sessions / authentification

Le projet est **stateless côté serveur** (pas de session stockée en mémoire) :
- **Access token JWT** (15 min) : envoyé à chaque requête, vérifié par signature, jamais stocké côté serveur
- **Refresh token** (30 jours) : stocké **hashé** dans une table PostgreSQL (`RefreshToken` — à ajouter au schéma Prisma en Phase 0), avec une date d'expiration et un lien vers l'utilisateur/appareil

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
