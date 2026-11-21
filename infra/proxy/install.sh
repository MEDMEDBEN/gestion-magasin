#!/usr/bin/env sh
# Premier démarrage du socle (à lancer dans /opt/proxy). Rejouable sans risque.
set -eu
cd "$(dirname "$0")"

# 1. Réseau commun à toutes les applis (une seule fois).
docker network inspect proxy >/dev/null 2>&1 || docker network create proxy

# 2. Réglages : e-mail Let's Encrypt.
if [ ! -f .env ]; then
  cp .env.example .env
  echo "→ Renseignez ACME_EMAIL dans $(pwd)/.env puis relancez ./install.sh"
  exit 1
fi

# 3. Stockage des certificats : fichier privé (Traefik l'exige en 600).
mkdir -p letsencrypt sites
[ -f letsencrypt/acme.json ] || touch letsencrypt/acme.json
chmod 600 letsencrypt/acme.json

# 4. Démarrage, puis contrôle de la configuration Nginx.
docker compose up -d
sleep 2
docker compose exec -T nginx nginx -t
echo "Socle démarré : Traefik (80/443) + Nginx. Sites : $(ls traefik/dynamic | grep -v '^_' | sed 's/\.yml$//' | tr '\n' ' ')"
