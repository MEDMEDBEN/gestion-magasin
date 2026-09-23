# Compiler et lancer « Gestion magasin » — procédure autonome

Ce fichier se suffit à lui-même : **tu n'as pas besoin de lire le reste du projet.** Suis les étapes dans
l'ordre. À la fin, l'application de bureau s'ouvre, connectée à un vrai serveur et à une vraie base.

Dépôt : `https://github.com/MEDMEDBEN/gestion-magasin.git` — branche **`develop`**.
Pile : backend **NestJS + Prisma + PostgreSQL**, application **Flutter** (bureau Windows et mobile Android).

---

## 0. Interdits et pièges (à lire avant de taper quoi que ce soit)

1. **Ne touche à aucun conteneur Docker dont le nom commence par `infinit-school-`.** Ils appartiennent à une
   autre application de la même machine (ports 5433, 9002, 9003). Ni `stop`, ni `rm`, ni suppression de
   volume. Les conteneurs de CE projet s'appellent `infra-postgres-1`, `infra-redis-1`, `infra-minio-1`.
2. **Ne lance JAMAIS `flutter build windows --release` pointé sur `http://`.** L'application refuse de
   démarrer (règle de sécurité volontaire : mots de passe et jetons ne doivent pas circuler en clair). Pour un
   test local, c'est `--debug` — voir l'étape 7.
3. **Les fichiers générés Dart ne sont pas dans Git** (`*.g.dart`, `*.freezed.dart`). Si tu sautes l'étape 6
   (`build_runner`), la compilation échouera avec des dizaines d'erreurs « isn't a type » ou « Target of URI
   doesn't exist ». Ce n'est pas un bug : c'est l'étape manquante.
4. **Espace disque** : prévoir **10 Go libres**. C'est le point qui a bloqué les tentatives précédentes.
5. Ne modifie aucun fichier source. Si quelque chose ne compile pas, **arrête-toi et rapporte** (voir §9).

---

## 1. Prérequis — vérifie-les, ne les suppose pas

Lance ces commandes ; chacune doit répondre sans erreur.

| Outil | Commande de vérification | Attendu |
|---|---|---|
| Git | `git --version` | ≥ 2.40 |
| Node.js | `node --version` | **v20 ou v22** (v18 ne suffit pas) |
| Docker | `docker ps` | la liste s'affiche (démon démarré) |
| Flutter | `flutter --version` | **3.44.x**, canal `stable` |
| Espace disque | `Get-PSDrive C` (PowerShell) | ≥ 10 Go libres |

**Pour compiler l'application Windows**, il faut en plus, dans Visual Studio (installeur → « Modifier » →
onglet « Composants individuels ») :
- **Outils de build C++ pour Desktop** ;
- le composant **`C++ ATL` (`Microsoft.VisualStudio.Component.VC.ATL`)** — sans lui, l'erreur est
  `atlstr.h: No such file or directory`.

Vérification : `flutter doctor -v` ne doit signaler aucun problème sur la ligne « Visual Studio ».

*(Pour l'APK Android seulement : un NDK fonctionnel est nécessaire. Sur la machine d'origine il est cassé ;
si `flutter doctor` signale le NDK, saute l'étape 8 et dis-le dans ton rapport.)*

---

## 2. Récupérer le code

```bash
git clone https://github.com/MEDMEDBEN/gestion-magasin.git
cd gestion-magasin
git checkout develop
git pull
```

Si le dépôt est déjà sur la machine : `cd` dedans, puis `git checkout develop && git pull`.

---

## 3. Démarrer la base de données et le stockage de fichiers

```bash
cd infra
docker compose -f docker-compose.dev.yml up -d
docker ps
```

Tu dois voir **trois** conteneurs de ce projet en marche : `infra-postgres-1` (port 5432),
`infra-redis-1` (6379), `infra-minio-1` (9000/9001).

> Si le port 5432 est déjà pris par autre chose, **n'arrête rien** : signale-le et arrête-toi. Une autre
> application tourne peut-être sur cette machine.

---

## 4. Configurer le backend

```bash
cd ../backend
cp .env.example .env
```

Ouvre `backend/.env` et remplace **une seule valeur** :

```
JWT_ACCESS_SECRET=CHANGER_CETTE_CLE_ALEATOIRE
```

par une clé aléatoire d'au moins 32 octets. Génère-la avec :

```bash
openssl rand -base64 48
```

> Le serveur **refuse de démarrer** avec la valeur d'exemple ou une clé trop courte : c'est voulu.
> Toutes les autres valeurs du fichier correspondent déjà aux conteneurs de l'étape 3, n'y touche pas.

---

## 5. Installer, migrer, créer le compte administrateur

```bash
npm ci
npx prisma migrate deploy
npx prisma generate
npm run seed
```

`npm run seed` crée l'administrateur avec les identifiants lus dans `.env` :
**`admin@magasin.dz` / `ChangeMoi123!`** (à changer à la première connexion — l'application l'exigera).

**Vérification obligatoire avant de continuer :**

```bash
npm run build
npm test
```

`npm run build` doit finir sans erreur, et `npm test` afficher **84 tests passés**. Si ce n'est pas le cas,
arrête-toi et rapporte : inutile de compiler l'application si le serveur ne tient pas.

Laisse ensuite le serveur tourner **dans un terminal dédié** :

```bash
npm run start:dev
```

Il écoute sur `http://localhost:3000`. Laisse ce terminal ouvert.

---

## 6. Préparer l'application Flutter (étape à ne PAS sauter)

Dans un **second** terminal :

```bash
cd gestion-magasin/app
flutter pub get
dart run build_runner build --delete-conflicting-outputs
```

La dernière commande génère les fichiers `*.g.dart` / `*.freezed.dart`, absents de Git. Elle prend une à deux
minutes et se termine par `Built with build_runner`.

Vérification :

```bash
flutter analyze
flutter test
```

Attendu : `No issues found!` puis **345 tests passés** (≈ 46 ignorés, c'est normal — ce sont les captures
d'écran, désactivées par défaut).

---

## 7. Compiler et lancer l'application de bureau

Le serveur local est en `http://`, donc **build de débogage** (voir le piège n°2) :

```bash
flutter build windows --debug
```

Le binaire sort dans `app\build\windows\x64\runner\Debug\`. Lance-le, ou plus simplement :

```bash
flutter run -d windows
```

**Connexion** : `admin@magasin.dz` / `ChangeMoi123!`. L'application demandera un nouveau mot de passe à la
première connexion — c'est le comportement attendu, choisis-en un et note-le.

> Si tu veux une vraie build `--release`, il faut un serveur en HTTPS et passer son adresse :
> `flutter build windows --release --dart-define=API_BASE_URL=https://ton-domaine/api`.
> Avec `http://`, l'application se fermera au démarrage, volontairement.

---

## 8. (Optionnel) APK Android

À ne tenter que si `flutter doctor` ne signale aucun problème de NDK :

```bash
flutter build apk --debug
```

Sortie : `app\build\app\outputs\flutter-apk\app-debug.apk`.

Sur un téléphone, `localhost` ne désigne pas le PC : il faut l'adresse du PC sur le réseau local, par exemple
`flutter build apk --debug --dart-define=API_BASE_URL=http://192.168.1.20:3000/api`.

---

## 9. Ce que tu dois rapporter

Rends compte de façon factuelle, en collant les sorties réelles — jamais « ça devrait marcher » :

1. Résultat de `flutter doctor -v` (la partie Visual Studio / Android).
2. Résultat de `npm test` (nombre de tests) et de `npm run build`.
3. Résultat de `flutter analyze` et `flutter test` (nombre de tests).
4. L'application s'ouvre-t-elle ? Une **capture d'écran** de la fenêtre après connexion.
5. Tout message d'erreur **complet**, tel quel.

### Pannes connues et ce qu'elles veulent dire

| Message | Cause | Action |
|---|---|---|
| `atlstr.h: No such file or directory` | composant ATL absent de Visual Studio | installer `C++ ATL` (§1) |
| Dizaines d'erreurs « isn't a type », « Target of URI doesn't exist » | `build_runner` non lancé | refaire l'étape 6 |
| `JWT_ACCESS_SECRET` / refus de démarrer | clé d'exemple ou trop courte | refaire l'étape 4 |
| `API_BASE_URL doit être en https://` | build `--release` sur `http://` | utiliser `--debug` (§7) |
| `Can't reach database server at localhost:5432` | conteneurs arrêtés | refaire l'étape 3 |
| Disque plein en cours de build | < 10 Go libres | libérer de la place, **ne rien supprimer dans le projet** sauf `app/build` et `app/.dart_tool`, qui se régénèrent |

---

## 10. Ce que le projet fait (contexte minimal, pour reconnaître un écran correct)

Gestion d'un magasin de matériel électrique et de son dépôt : produits, stock, ventes et caisse, clients et
fournisseurs, achats et réceptions, transferts magasin ↔ dépôt, inventaires, planning, tableau de bord,
notifications. Trois rôles : **Admin**, **Vendeur/Caissier**, **Magasinier** — l'écran d'accueil et le menu
varient selon les droits du compte connecté. L'interface est en français, thème sombre.

Après connexion en administrateur, tu dois voir une barre latérale gauche (Accueil, Vente, Catalogue, Stock,
Tâches, Transferts, Achats, Inventaire, Fournisseurs, Utilisateurs, Historique, Notifications, Mon profil) et
un tableau de bord d'accueil. La base étant neuve, les chiffres seront à zéro et les listes vides : **c'est
normal**, ce n'est pas une panne.
