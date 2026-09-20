# ─────────────────────────────────────────────────────────
# Image de production du backend NestJS.
# Deux étages : on compile avec toutes les dépendances, on n'embarque que le
# résultat et les dépendances de production.
# ─────────────────────────────────────────────────────────
FROM node:22-alpine AS build

WORKDIR /app

# Les dépendances d'abord : cette couche ne se reconstruit que si elles changent.
COPY package.json package-lock.json ./
RUN npm ci

# Le client Prisma est GÉNÉRÉ (src/generated/prisma, non versionné) : il faut le
# schéma avant de compiler.
COPY prisma ./prisma
COPY prisma.config.ts ./
RUN npx prisma generate

COPY . .
RUN npm run build

# ─────────────────────────────────────────────────────────
FROM node:22-alpine AS runtime

# `dumb-init` : PID 1 correct, donc arrêt propre du conteneur (SIGTERM relayé).
RUN apk add --no-cache dumb-init

ENV NODE_ENV=production
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

# Schéma et configuration Prisma : les migrations et le seed tournent au
# démarrage. Le client généré est déjà compilé dans `dist/generated`.
COPY --from=build /app/prisma ./prisma
COPY --from=build /app/prisma.config.ts ./
COPY --from=build /app/dist ./dist

# Jamais root dans le conteneur : `node` existe déjà dans l'image officielle.
USER node

EXPOSE 3000

# Migrations, seed, puis démarrage. La base est toujours au niveau du code
# déployé ; `migrate deploy` n'applique que des migrations déjà écrites, jamais
# de modification destructive improvisée. Le seed est IDEMPOTENT et fait
# autorité sur les rôles et permissions — il crée aussi le PREMIER compte
# administrateur, sans quoi personne ne pourrait se connecter (règle 14 :
# aucune inscription publique).
CMD ["dumb-init", "sh", "-c", "npx prisma migrate deploy && node dist/seed.js && node dist/main.js"]
