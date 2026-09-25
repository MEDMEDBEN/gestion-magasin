# Compiler « Gestion magasin » sur un PC neuf — recette complète

Ce fichier se suffit à lui-même. **Tu n'as rien à analyser dans le projet** : suis les étapes dans l'ordre,
de l'installation des outils jusqu'à l'exécutable Windows, puis l'application mobile.

- Dépôt : `https://github.com/MEDMEDBEN/gestion-magasin.git` — version à compiler : le tag **`v0.4.0-rc1`**
- Pile : backend **NestJS + Prisma + PostgreSQL**, application **Flutter** (Windows et Android).
  Un SEUL service externe : PostgreSQL. Les fichiers joints vivent sur le disque du serveur.
- Résultat attendu : un **`.exe` Windows** qui s'ouvre et se connecte à un vrai serveur local, puis un **APK**

**Machine cible** : Windows 10 ou 11 (64 bits), droits administrateur, connexion Internet, et **15 Go libres pour les OUTILS de compilation** (Visual Studio, SDK Flutter, Docker, dépendances). L'application produite, elle, pèse 25 à 45 Mo — ces 15 Go sont le coût de l'atelier, pas du produit.

---

## Règles de conduite

1. **Ne modifie aucun fichier source du projet.** Si quelque chose ne compile pas, arrête-toi et rapporte
   (§10). Tout ce qui suit fonctionne sans retoucher une ligne de code.
2. **Cinq pièges connus**, traités aux étapes 1, 4, 6, 7 (deux) et 9.3. Si tu les sautes, la compilation
   échoue avec des messages trompeurs. Les étapes 1 à 6 ont été **rejouées entièrement sur un clone neuf le
   2026-09-25** : elles passent. La compilation Windows elle-même n'a pas pu être vérifiée, faute d'ATL sur
   la machine de développement — c'est justement ce que tu vas prouver.
3. Rends compte avec les **sorties réelles** collées, jamais « ça devrait marcher ».

---

## 1. Installer les outils

### 1.1 Git, Node.js, Docker Desktop

Dans un PowerShell **administrateur** :

```powershell
winget install --id Git.Git -e
winget install --id OpenJS.NodeJS.LTS -e   # si une autre version est déjà là : désinstalle-la d'abord
winget install --id Docker.DockerDesktop -e
```

Ferme et rouvre PowerShell, puis vérifie :

```powershell
git --version          # ≥ 2.40
node --version         # v20 ou v22 EXACTEMENT — ni v18, ni v24 (non testées)
npm --version
```

Lance **Docker Desktop** et attends que son icône indique « Engine running ». Vérifie :

```powershell
docker ps              # doit afficher un tableau vide, sans erreur
```

### 1.2 Visual Studio — PIÈGE N°1

Flutter compile l'application Windows avec le compilateur C++ de Visual Studio. Il faut **la charge de travail
Desktop C++ ET le composant ATL** — sans ATL, l'erreur est `atlstr.h: No such file or directory`.

```powershell
winget install --id Microsoft.VisualStudio.2022.BuildTools -e --override "--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.VC.ATL --includeRecommended"
```

L'installation prend 10 à 20 minutes. Si Visual Studio est déjà présent : ouvre « Visual Studio Installer » →
**Modifier** → onglet **Composants individuels** → coche **`C++ ATL pour les outils de build v143 (x86/x64)`**.

⚠️ **`flutter doctor` vert sur « Visual Studio » NE PROUVE PAS qu'ATL est installé.** Il vérifie le
compilateur, pas ce composant. Vérifié le 2026-09-25 : une machine avec Build Tools 2019 sans ATL affiche
`[√] Visual Studio` et échoue quand même à la compilation. Le seul contrôle fiable :

```powershell
# Doit renvoyer au moins un chemin. Rien = ATL absent = la compilation échouera.
Get-ChildItem "C:\Program Files*\Microsoft Visual Studio\*\*\VC" -Recurse -Filter atlstr.h -ErrorAction SilentlyContinue | Select-Object -First 1 FullName
```

Le plugin qui l'exige est `flutter_secure_storage_windows` (il stocke les jetons de session dans le coffre
Windows). Sa **dernière version inclut toujours `atlstr.h`** : il n'y a pas de contournement par mise à jour,
et le composant ATL n'est pas optionnel.

### 1.3 Flutter

Télécharge le SDK stable et décompresse-le dans **`C:\flutter`** (un chemin **sans espace ni accent**) :
`https://docs.flutter.dev/get-started/install/windows/desktop`

Ajoute `C:\flutter\bin` au `Path` de l'utilisateur, rouvre PowerShell, puis :

```powershell
flutter --version      # 3.44.x, canal stable
flutter config --enable-windows-desktop
flutter doctor -v
```

`flutter doctor` doit être **vert sur « Visual Studio »**. Ignore une éventuelle ligne rouge sur Android tant
que tu es à l'étape Windows ; elle ne concerne que l'APK (§9).

---

## 2. Récupérer le code

```powershell
cd C:\
git clone https://github.com/MEDMEDBEN/gestion-magasin.git
cd gestion-magasin
git checkout v0.4.0-rc1   # version figée et testée ; « develop » bouge pendant que tu travailles
```

---

## 3. Démarrer la base de données

```powershell
cd C:\gestion-magasin\infra
docker compose -f docker-compose.dev.yml up -d
docker ps
```

Tu dois voir **un seul** conteneur en marche : PostgreSQL, port **5432**. Il se télécharge au premier
lancement (une minute environ).

> Un seul service, c'est voulu. Les photos sont écrites sur le disque du serveur, il n'y a plus de
> service de stockage à installer. Si tu trouves de vieilles instructions parlant de MinIO ou de Redis,
> elles sont périmées : ce fichier fait foi.

---

## 4. Configurer le backend — PIÈGE N°2 : la clé JWT

```powershell
cd C:\gestion-magasin\backend
Copy-Item .env.example .env
```

Le serveur **refuse volontairement de démarrer** tant que la clé d'exemple est en place. Génère la tienne :

```powershell
$b = New-Object byte[] 48
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
[Convert]::ToBase64String($b)
```

Ouvre `C:\gestion-magasin\backend\.env` et remplace **uniquement** la ligne :

```
JWT_ACCESS_SECRET=CHANGER_CETTE_CLE_ALEATOIRE
```

par la valeur affichée. C'est la **seule** valeur à changer : toutes les autres correspondent déjà au
conteneur de l'étape 3. Il n'y a aucun autre secret à obtenir, aucun compte à créer nulle part.

Ce fichier `.env` t'appartient : il n'est pas dans Git et ne doit jamais y être ajouté.

---

## 5. Installer le backend, créer la base et le compte administrateur

```powershell
cd C:\gestion-magasin\backend
npm ci
npx prisma migrate deploy
npx prisma generate
npm run seed
```

Le seed crée l'administrateur : **`admin@magasin.dz`** / **`ChangeMoi123!`**

**Vérification — ne passe pas à la suite si elle échoue :**

```powershell
npm run build
npm test
```

Attendu : build sans erreur, puis **89 tests passés** (16 suites).

Laisse maintenant le serveur tourner dans **ce terminal, ouvert** :

```powershell
npm run start:dev
```

Il écoute sur `http://localhost:3000`. Vérifie dans un navigateur : **`http://localhost:3000/docs`** affiche
la documentation interactive de l'API (les routes, elles, vivent sous `/api`).

---

## 6. Préparer l'application Flutter — PIÈGE N°3

Les fichiers Dart générés **ne sont pas dans Git** : il faut les produire. Sans cette étape, la compilation
échoue avec des dizaines de `isn't a type` ou `Target of URI doesn't exist` — ce n'est pas un bug du projet.

Ouvre un **deuxième** terminal PowerShell :

```powershell
cd C:\gestion-magasin\app
flutter pub get
dart run build_runner build
```

La dernière commande dure **2 à 4 minutes** (la moitié à compiler les générateurs) et se termine par
`Built with build_runner`. Elle écrit environ **426 fichiers**.

> N'ajoute pas `--delete-conflicting-outputs` : l'option a été **retirée** de `build_runner`, elle est ignorée
> avec un avertissement. Si tu la vois dans de vieilles instructions, elle est périmée.

Vérification :

```powershell
flutter analyze
flutter test
```

Attendu : `No issues found!` puis **368 tests passés, 46 ignorés** (les ignorés sont les captures d'écran,
désactivées par défaut — ce n'est pas un échec). `flutter analyze` prend 2 à 3 minutes la première fois.

---

## 7. Compiler l'exécutable Windows

Le serveur local est en `http://`. L'application **refuse une build `--release` sur une adresse non chiffrée**
(les mots de passe et jetons passeraient en clair). Pour un test local, compile en **`--profile`** : c'est une
build optimisée, sans les outils de débogage, et qui accepte `http://localhost`.

```powershell
cd C:\gestion-magasin\app
flutter build windows --profile
```

### PIÈGE N°5 : le build télécharge pdfium, et ne réessaie pas

La génération des PDF (tickets, factures) passe par le paquet `printing`, qui **télécharge une bibliothèque
pdfium (2,6 Mo) depuis GitHub pendant la configuration CMake** — pas au moment du `pub get`, mais du build.
C'est le seul téléchargement réseau de cette étape, et **CMake ne réessaie pas** : une seule coupure donne ce
message, qui ne dit pas qu'il s'agit du réseau :

```
CMake Error at flutter/ephemeral/.plugin_symlinks/printing/windows/DownloadProject.cmake:179 (message):
  Build step for pdfium failed: 1
...
Unable to generate build files
```

**Que faire** : relancer `flutter build windows --profile`, simplement. Une fois l'archive récupérée, elle est
mise en cache et le problème ne revient pas. Vu le 2026-09-25 : trois tentatives ont été nécessaires.
Pour vérifier que c'est bien le réseau et non l'URL :

```powershell
curl.exe -sIL -o NUL -w "%{http_code}`n" https://github.com/bblanchon/pdfium-binaries/releases/download/chromium/5200/pdfium-win-x64.tgz
```

`200` = l'URL est bonne, relance le build. `000` = ta connexion vers GitHub tombe ; réessaie.
Si l'archive est arrivée mais vide, supprime `app\build\windows` et relance.

L'exécutable et ses DLL sont dans :

```
C:\gestion-magasin\app\build\windows\x64\runner\Profile\
```

Lance **`gestion_magasin.exe`** depuis ce dossier (le serveur de l'étape 5 doit tourner).

> **Pour transmettre l'application à quelqu'un**, copie le **dossier `Profile` entier**, pas seulement le
> `.exe` : il a besoin des DLL et du dossier `data` qui l'accompagnent. Compresse-le en `.zip`.

### Première connexion

- Identifiant : **`admin@magasin.dz`** — Mot de passe : **`ChangeMoi123!`**
- L'application **exigera un nouveau mot de passe** dès la première connexion : c'est le comportement prévu.
  Choisis-en un (12 caractères, majuscule, minuscule, chiffre, symbole) et **note-le dans ton rapport**.

### Ce que tu dois voir

Un thème sombre, en français, avec une barre latérale gauche : Accueil, Vente, Catalogue, Stock, Tâches,
Transferts, Achats, Inventaire, Fournisseurs, Utilisateurs, Historique, Messages, Notifications, Mon profil. L'accueil
affiche un tableau de bord. **La base est neuve : tous les chiffres sont à zéro et les listes vides. C'est
normal, ce n'est pas une panne.**

### Build `--release` (seulement avec un serveur HTTPS)

```powershell
flutter build windows --release --dart-define=API_BASE_URL=https://ton-domaine.com/api
```

Avec `http://`, l'application se fermera au démarrage — volontairement.

---

## 8. Vérifier que l'application parle vraiment au serveur

Après connexion, va dans **Catalogue → Nouveau produit**, crée un produit avec un nom et un prix,
enregistre-le, puis reviens sur la liste : il doit y apparaître. Le terminal du backend (étape 5) doit montrer
la requête correspondante. **C'est cette vérification qui prouve que la chaîne complète fonctionne**, pas
seulement l'ouverture de la fenêtre.

---

## 9. Application mobile (APK) — après la build Windows

> **À ne faire que si l'APK est explicitement demandée.** C'est nettement plus lourd que le desktop :
> compte **15 à 20 Go de disque en plus POUR LES OUTILS** (Android Studio, SDK, éventuellement NDK, cache Gradle ; l'APK produite fait 20 à 70 Mo),
> **10 à 25 minutes pour le premier build** (surtout du téléchargement) puis 1 à 3 minutes,
> et **8 Go de RAM minimum** — Gradle en prend 2 à 4 à lui seul.
> Le desktop suffit à juger les écrans et les enchaînements ; l'APK n'ajoute que le scanner de
> codes-barres et l'ergonomie tactile.

### 9.1 Outils Android

Installe **Android Studio** (`winget install --id Google.AndroidStudio -e`), lance-le une fois et laisse-le
télécharger le SDK. Puis :

```powershell
flutter doctor --android-licenses     # accepter toutes les licences
flutter doctor -v                     # la ligne Android doit être verte
```

Si `flutter doctor` signale un **NDK** absent ou corrompu : ouvre Android Studio → **SDK Manager** → onglet
**SDK Tools** → coche **NDK (Side by side)** et **CMake** → applique.

### 9.2 Adresse du serveur pour un téléphone

Sur un téléphone, `localhost` désigne le téléphone lui-même, pas le PC. De plus **Android bloque le HTTP en
clair** : pointer l'APK sur `http://192.168.x.x` ne fonctionnera pas, l'application apparaîtra « hors ligne ».

Deux solutions, au choix :

- **La plus simple** — exposer temporairement le backend en HTTPS avec un tunnel :
  ```powershell
  winget install --id Cloudflare.cloudflared -e
  cloudflared tunnel --url http://localhost:3000
  ```
  Il affiche une adresse `https://xxxxx.trycloudflare.com`. Utilise-la telle quelle à l'étape 9.3.
  **Laisse ce terminal ouvert** : si le tunnel se ferme, l'APK ne joint plus rien.
- **Sinon** : un vrai serveur en HTTPS, et son adresse à la place.

### 9.3 Construire l'APK — PIÈGE N°4 : `--release` est VOLONTAIREMENT bloqué

Le projet **refuse** de produire une APK `--release` sans clé de signature (`android/key.properties`, jamais
commité) : une application signée avec la clé de debug ne doit jamais sortir. Pour un test, c'est donc
`--profile` — build optimisée, aucune clé nécessaire :

```powershell
cd C:\gestion-magasin\app
flutter build apk --profile --dart-define=API_BASE_URL=https://xxxxx.trycloudflare.com/api
```

L'APK sort dans :

```
C:\gestion-magasin\app\build\app\outputs\flutter-apk\app-profile.apk
```

Environ 30 à 60 Mo. Transfère-le sur le téléphone et installe-le (« Sources inconnues » à autoriser). Le
scanner de codes-barres demandera l'accès à la caméra au premier usage.

> Une vraie APK `--release` (pour distribuer l'application) exige un magasin de clés et un
> `android/key.properties` : ce n'est pas l'objet de ce test, ne le contourne pas.

---

## 10. Ce que tu dois rapporter

Colle les sorties réelles :

1. `flutter doctor -v` (sections Visual Studio et Android).
2. `npm run build` et `npm test` (nombre de tests).
3. `flutter analyze` et `flutter test` (nombre de tests).
4. `flutter build windows --profile` : la ligne finale, et le **chemin du `.exe`** produit.
5. **Une capture d'écran de l'application ouverte, après connexion.**
6. Le résultat de la vérification §8 (le produit créé apparaît-il ?).
7. Le mot de passe administrateur que tu as défini.
8. Pour l'APK : le chemin du fichier, sa taille, et si tu as pu l'installer et te connecter.
9. **Tout message d'erreur, complet et tel quel.**

### Pannes connues

| Message | Cause | Action |
|---|---|---|
| `atlstr.h: No such file or directory` | composant ATL manquant — **même si `flutter doctor` est vert** | §1.2 |
| `Build step for pdfium failed: 1` puis `Unable to generate build files` | téléchargement de pdfium interrompu | relancer le build (§7, piège n°5) |
| `These options have been removed and were ignored: --delete-conflicting-outputs` | option retirée de `build_runner` | simple avertissement, à ignorer (§6) |
| Beaucoup de `isn't a type` / `Target of URI doesn't exist` | `build_runner` non lancé | §6 |
| `API_BASE_URL doit être en https://` | build `--release` sur `http://` | compiler en `--profile` (§7) |
| Le serveur refuse de démarrer, parle de `JWT_ACCESS_SECRET` | clé d'exemple ou trop courte | §4 |
| `Can't reach database server at localhost:5432` | conteneurs arrêtés ou Docker éteint | §3 |
| `Unable to find suitable Visual Studio toolchain` | charge de travail Desktop C++ absente | §1.2 |
| L'APK s'ouvre mais reste « hors ligne » | Android bloque le HTTP en clair | tunnel HTTPS (§9.2) |
| Disque plein pendant la compilation | < 15 Go libres | libérer de la place ; `app\build` et `app\.dart_tool` se régénèrent |

---

## 11. Contexte minimal (pour reconnaître un écran correct)

Logiciel de gestion d'un magasin de matériel électrique et de son dépôt : produits, stock, ventes et caisse,
clients et fournisseurs, achats et réceptions, transferts magasin ↔ dépôt, inventaires, planning, tableau de
bord, notifications. Trois rôles — **Admin**, **Vendeur/Caissier**, **Magasinier** — et le menu change selon
les droits du compte connecté. Interface en français, thème sombre. L'application fonctionne hors ligne pour
la vente et se resynchronise ensuite ; un bandeau l'indique.
