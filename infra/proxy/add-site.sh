#!/usr/bin/env sh
# Ajoute un site au socle (à lancer dans /opt/proxy).
#
#   ./add-site.sh blog.mondomaine.com
#       → site web seul : déposez ses fichiers dans sites/blog.mondomaine.com/
#   ./add-site.sh shop.mondomaine.com shop-backend:3000
#       → fichiers web + /api/ vers le conteneur « shop-backend » port 3000
#   ./add-site.sh shop.mondomaine.com shop-backend:3000 /backend/
#       → même chose, avec un autre préfixe que /api/
#
# Avant : l'enregistrement DNS A du domaine doit pointer vers ce VPS (sinon pas
# de certificat), et le conteneur backend doit être sur le réseau « proxy ».
set -eu
cd "$(dirname "$0")"

DOMAIN="${1:-}"
BACKEND="${2:-}"
PREFIX="${3:-/api/}"
if [ -z "$DOMAIN" ]; then
  sed -n '2,13p' "$0"
  exit 1
fi
case "$DOMAIN" in
  *[!a-zA-Z0-9.-]*) echo "Domaine invalide : $DOMAIN"; exit 1 ;;
esac

CONF="nginx/conf.d/$DOMAIN.conf"
ROUTE="traefik/dynamic/$DOMAIN.yml"
if [ -e "$CONF" ] || [ -e "$ROUTE" ]; then
  echo "Le site $DOMAIN existe déjà ($CONF / $ROUTE) : rien n'est modifié."
  exit 1
fi

ROUTER=$(echo "$DOMAIN" | tr '.' '-')
mkdir -p "sites/$DOMAIN"
if [ -z "$(ls -A "sites/$DOMAIN")" ]; then
  echo "<!doctype html><meta charset=utf-8><title>$DOMAIN</title><p>$DOMAIN est en ligne." > "sites/$DOMAIN/index.html"
fi

if [ -n "$BACKEND" ]; then
  sed -e "s#__DOMAIN__#$DOMAIN#g" -e "s#__BACKEND__#$BACKEND#g" -e "s#__PREFIX__#$PREFIX#g" \
    templates/site-api.conf.tpl > "$CONF"
else
  sed -e "s#__DOMAIN__#$DOMAIN#g" templates/site-static.conf.tpl > "$CONF"
fi
sed -e "s#__DOMAIN__#$DOMAIN#g" -e "s#__ROUTER__#$ROUTER#g" \
  templates/router.yml.tpl > "$ROUTE"

# Nginx : on vérifie AVANT de recharger ; une erreur annule l'ajout.
if docker compose exec -T nginx nginx -t; then
  docker compose exec -T nginx nginx -s reload
else
  rm -f "$CONF" "$ROUTE"
  echo "Configuration refusée par Nginx : ajout annulé."
  exit 1
fi
# Traefik relit traefik/dynamic tout seul ; le certificat arrive au 1er accès.
echo "Site ajouté : https://$DOMAIN"
echo "  Nginx   : $CONF"
echo "  Traefik : $ROUTE"
echo "  Fichiers: sites/$DOMAIN/"
