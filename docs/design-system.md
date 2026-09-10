# Design system — AMPÈRE (référence VISUELLE)

> **Portée : APPARENCE UNIQUEMENT.** Ce document ne définit que le style visuel (couleurs, typographie, espacements, rayons, élévation, mouvement, icônes, aspect des composants et des états). **Il ne change AUCUNE logique du projet** : rôles, schéma de données, permissions, numérotation, features, workflows — tout cela reste régi par `CLAUDE.md`, `docs/spec-fonctionnelle.md`, `docs/plan.md`, `docs/permissions.md` et `docs/context.md`, qui font foi. En cas de contradiction entre ce document et la logique du projet, **la logique du projet gagne** ; ce document ne sert qu'à habiller les écrans.
>
> Rôles du projet = **3** (ADMIN, VENDEUR, MAGASINIER). Les tableaux de bord par rôle décrits ici sont un guide de **mise en page**, mappé sur ces 3 rôles — pas un modèle de permissions.

Plateformes : **desktop web** (1440–1920, utilisable dès 1180) et **mobile Flutter** (390×844, dépôt peu éclairé, une main). Langue fr-FR, champ désignation produit en doublon arabe (RTL sur ce champ uniquement). Monnaie DA, TVA 19 %.

---

## 1. Principes visuels

1. **Logiciel professionnel** : aucun dégradé de fond, aucun glassmorphisme, aucun néon, aucune animation décorative. La densité et la hiérarchie typographique font le travail.
2. **La densité est une fonctionnalité** : desktop dense et réglable, mobile spacieux et non réglable.
3. **Un écran = une action principale**, en bleu accent, unique.
4. **L'accent est rare** : le bleu marque l'action principale, l'élément actif et la donnée vivante. Pas de bleu partout.
5. **Contrastes** : texte courant ≥ 4,5:1, titres/chiffres ≥ 3:1. Ne pas appliquer d'opacité à du texte porteur d'information.

Seuls effets non plats autorisés : l'aire dégradée du graphique principal, et le flou de la barre supérieure. Rien d'autre (voir §20 des interdictions, plus bas).

---

## 2. Couleurs

Quatre familles : **Surfaces · Encre · Accent · Statuts**. Chaque statut a un ton de trait/texte (`-fg`) et un fond désaturé (`-bg`), toujours utilisés ensemble. Les deux thèmes portent les **mêmes noms de variables** ; aucun composant ne connaît le thème actif ; le choix est persisté par utilisateur.

### 2.1 Desktop — sombre (défaut)
```css
--bg:#0a0f19; --bg-alt:#070b12; --card:#111a29; --card-alt:#16202f;
--line:#22304a; --line-soft:#1a2537;
--ink:#e8eef8; --ink-2:#93a2bd; --ink-3:#63748f;
--accent:#2f7df6; --accent-hi:#5aa0ff; --accent-bg:#12233d;
--ok:#12b981; --ok-bg:#0d2b25; --warn:#f0a521; --warn-bg:#2d2210;
--error:#ef4b4b; --error-bg:#2d1418; --info:#5aa0ff; --info-bg:#12233d;
--neutral:#93a2bd; --neutral-bg:#16202f; --viz-alt:#8b7cf6;
```

### 2.2 Desktop — clair (accents assombris pour tenir le contraste, ce n'est pas une inversion)
```css
--bg:#f2f5fa; --bg-alt:#e8edf6; --card:#ffffff; --card-alt:#f7f9fd;
--line:#dbe3ef; --line-soft:#e8edf6;
--ink:#0f1a2b; --ink-2:#5a6b85; --ink-3:#8494ac;
--accent:#1c62d8; --accent-hi:#1552bd; --accent-bg:#e5eefc;
--ok:#0e8a60; --ok-bg:#e2f4ec; --warn:#8a5c05; --warn-bg:#fbf1dc;
--error:#c9302c; --error-bg:#fbe6e5; --info:#1552bd; --info-bg:#e5eefc;
--neutral:#5a6b85; --neutral-bg:#f7f9fd; --viz-alt:#6d5bd0;
```

### 2.3 Mobile — sombre (défaut ; bleu nuit plus chaud, accent plus cyan)
```
bg=#0B1017  surface=#121A24  surface2=#18222E  surface3=#1E2A38
line=#223141  lineSoft=#1A2532
ink=#E9EFF6  ink2=#93A5B8  ink3=#63768A
accent=#2FA8FF  accentHi=#7CD0FF  accentBg=#0E2436  onAccent=#04121D
ok=#17B98A okBg=#0C2621  warn=#F2AB3C warnBg=#2A2013
error=#F2604C errorBg=#2B1614  info=#7CD0FF infoBg=#0E2436
neutral=#93A5B8 neutralBg=#1E2A38
```

### 2.4 Mobile — clair
```
bg=#F4F7FB  surface=#FFFFFF  surface2=#EDF2F8  surface3=#DFE7F0
line=#D5DEEA  lineSoft=#E7EDF4
ink=#0C1621  ink2=#55677D  ink3=#8496A9
accent=#0C6FC4  accentHi=#0A5CA9  accentBg=#E2EFFA  onAccent=#FFFFFF
ok=#0B7F5D okBg=#E0F2EC  warn=#8A5A10 warnBg=#FAF0DC
error=#C43D2C errorBg=#FBE7E4  info=#0A5CA9 infoBg=#E2EFFA
neutral=#55677D neutralBg=#EDF2F8
```

### 2.5 Sémantique des statuts (même notion = même couleur partout)
- **ok** : terminé, conforme, payé, reçu, synchronisé, stock au-dessus du seuil.
- **warn** : en attente d'un tiers, partiel, en transit, sous le seuil, opération en file hors-ligne.
- **error** : rupture totale, écart d'inventaire, retard de paiement, crédit bloqué, échec.
- **info** : en cours, demandé, à approuver, information neutre datée.
- **neutral** : brouillon, non commencé, sans objet.

### 2.6 Graphiques (desktop uniquement — AUCUN graphique sur mobile)
Série principale `--accent`, trait 2,4 px, aire dégradée 34 %→0 % (le seul dégradé autorisé). Grille `--line-soft` 1 px horizontale, 5 lignes. Donut : `accent → ok → warn → viz-alt`. Barres de progression : hauteur 6-8, piste `surface3`, rayon 999. Sparkline KPI : 78×26, trait 1,8, couleur = statut du KPI, sans axes.

---

## 3. Typographie

Famille unique : **Archivo** (variable 400–800). `font-feature-settings:"tnum"` sur tout nombre.

### 3.1 Desktop
| Rôle | px/interligne | Poids | Suivi |
|---|---|---|---|
| Display | 34/1.1 | 800 | −.03em |
| H1 | 26/1.15 | 800 | −.03em |
| H2 | 21/1.2 | 800 | −.02em |
| H3 | 19/1.25 | 700 | −.02em |
| H4 | 16/1.3 | 600 | −.02em |
| Card title | 14.5/1.35 | 600 | 0 |
| KPI | 26/1.1 | 700 | −.03em |
| KPI large | 28/1.1 | 800 | −.03em |
| Body | 13.5/1.5 | 400 | 0 |
| Body strong | 13/1.4 | 600 | 0 |
| Meta | 11.5/1.45 | 400 | 0 |
| Label | 10/1.3 | 600 | .14em MAJ |
| Mono | 11.5/1.3 | 400 | −.02em |

Plancher desktop 10 px (labels capitales uniquement). Aucune donnée sous 11,5 px.

### 3.2 Mobile
| Rôle | px/interligne | Poids |
|---|---|---|
| Screen title | 23/1.2 | 800 |
| Section title | 17/1.25 | 800 |
| Numeric hero | 34/1.1 | 700 |
| Numeric | 24–28/1.1 | 700 |
| Row title | 14.5/1.35 | 600 |
| Body | 15/1.55 | 400 |
| Meta | 12.5/1.5 | 400 |
| Label | 10.5/1.3 | 600 .14em MAJ |
| Input | 16–26 | 600–700 (16 min : évite le zoom iOS) |
| Mono | 11.5 | 400 |

Plancher mobile 11 px ; corps jamais sous 15, méta sous 12,5.

### 3.3 Formats de nombres
Montant `184 600 DA` (espace insécable, `DA` suffixé) ; abrégé `2,21 M DA` ; quantité + unité `400 rouleau` ; pourcentage `31,8 %` ; écart signé `−7 / +2 / —` ; date `JJ/MM/AAAA` ; horodatage `05/09 08:14` ou relatif < 24 h ; décimale à la virgule. **Tout nombre en chiffres tabulaires, aligné à droite en tableau.**

---

## 4. Espacement, géométrie, élévation, mouvement

**Échelle base 4** : 2,4,6,7,8,9,10,12,14,16,18,20,22,26 px puis multiples de 4.
Marge d'écran : 20 desktop / 16 mobile. Padding carte 14–18 / 14. Gouttière 14 / 10.

**Rayons** : carte 12 (desktop) / 14 (mobile) · champ & bouton 8 / 10 · pastille d'icône 9-11 / 11 · feuille modale 20 (haut) · badge & barre de progression 999 · cadre de scan 12.

**Bordures** : une seule épaisseur 1 px. `--line` délimite un conteneur, `--line-soft` sépare les lignes. Dernière ligne d'une liste sans séparateur.

**Élévation** : 0 = cartes/tableaux/sidebar = **aucune ombre**, la bordure suffit. 1 = popover `0 18px 46px rgba(0,0,0,.45)` (sombre). 2 = dialogue/feuille `0 30px 80px rgba(0,0,0,.55)`. 3 = toast. Aucune ombre sur un élément qui ne flotte pas.

**Mouvement** : apparitions 120-160 ms ease-out (translation Y +5→0) ; feuille modale 200 ms (+30→0) ; survol/focus 100 ms ; nav mobile 260 ms native ; ligne de scan 2 s alternée ; squelette 1,4 s. Rien d'autre n'est animé. Respecter `prefers-reduced-motion` (ne garder que les fondus).

---

## 5. Icônes — Lucide, trait uniquement

`stroke-linecap/join: round`, `fill:none`, couleur = `currentColor` ou le `-fg` du statut.
Tailles : nav desktop 17/1.9 · pastille 16-19/1.9 · bouton 15-17/1.9 · onglet mobile 21/1.8 · état vide 26-32/1.7-2.4.

Correspondance (même notion = même icône) : Tableau de bord `layout-grid` · Caisse/vente `shopping-cart` · Ticket/facture `receipt` · Produit `package` · Stock `layers` · Transfert `arrow-left-right` · Réception/achat `truck` · Inventaire `clipboard-list` · Client `user` · Fournisseur `users` · Rapport `bar-chart-3` · Rôles/sécurité `shield` · Audit `history` · Paramètres `settings` · Alerte `alert-triangle` · Scanner `scan-line` · Trésorerie `wallet` · Mobile/terrain `smartphone` · Marque produit `zap` (le seul éclair du système).

---

## 6. Composants desktop (aspect)

**Bouton** — Primaire (fond `--accent`, texte blanc, **une seule par écran**) · Secondaire (`--card-alt`, bordure `--line`) · Fantôme (transparent, `--accent-hi`) · Icône (34×34) · Danger (transparent, bordure+texte `--error`, jamais rempli). Hauteurs 36 (défaut) / 40 (action de formulaire) / 30-32 (en-tête) / 28 (cellule). Padding H 14, écart icône-texte 7, poids 600, 13 px. Focus clavier `outline:2px solid var(--accent); offset 2px`. Désactivé opacité 45 %.

**Champ** — hauteur 38 (34 en-tête, 42-44 montant), fond `--card-alt`, bordure `--line`, rayon 8, texte 13,5. Focus : bordure `--accent` + halo 3px à 22 %. Erreur : bordure `--error` + message 11,5 en dessous (jamais en infobulle). **Étiquette au-dessus** (Label 10 px capitales `--ink-3`), jamais de placeholder en guise d'étiquette.

**Carte** — fond `--card`, bordure `--line`, rayon 12, **aucune ombre**. En-tête optionnel (padding 14/16, séparateur bas `--line-soft`, titre 14,5/600). Carte contenant un tableau : pas de padding sur le corps ; large → `overflow-x:auto`.

**KPI** — étiquette (Label) + pastille d'icône 34×34 rayon 10 (fond `-bg`, icône `-fg`) + valeur 26/700 + sous-texte couleur du statut + sparkline 78×26. **Max 6 KPI** (4 pour un rôle opérationnel).

**Tableau** — en-tête Label 10,5 capitales `--ink-3`, séparateur bas `--line`. Cellule 13,5, séparateur `--line-soft`. Survol de ligne : fond accent 8 %. Colonne numérique à droite, chiffres tabulaires. Cellule d'identité : libellé 13/600 + SKU mono `--ink-3` en dessous. Statut en badge. Actions 28 px à droite. Ligne cliquable `cursor:pointer` sur toute la ligne. **Densité réglable/persistée** : dense (py 6, 13) · normal (py 10, 13,5) · aéré (py 13, 14).

**Badge de statut** — rayon 999, padding 3/9, 11/600, fond `-bg`, texte `-fg`, sans bordure. Badge vide masqué.

**Sidebar** — 246 px, fond `--bg-alt`, bordure droite `--line`, fixe. Marque → sélecteur de site actif → groupes → astuce → utilisateur. Élément 36 px, rayon 8, icône 17 + libellé 13. **Actif** : dégradé accent 26 %→transparent + trait accent 2 px à gauche (`inset 2px 0 0`). Le menu est dérivé des permissions ; un groupe vide disparaît (logique côté projet — ici, juste l'aspect).

**Barre supérieure** — 56 px, fond `--bg` 92 % + `blur(8px)`, séparateur bas, collante. Recherche globale (raccourci `Ctrl K` affiché), à droite : densité, thème, notifications.

**Recherche globale** — menu sous le champ, hauteur max 392, élévation 1, ligne `82px 1fr auto`, résultats groupés par type (5 max/type), état vide reprenant le terme.

**Dialogue** — `min(540px,100%)`, fond `--card`, rayon 12, padding 20, élévation 2, scène `rgba(3,7,14,.62)`. Réservé à une décision financière ou destructive.

**Panneau latéral** (notifications) — 384 px à droite, `--bg-alt`, bordure gauche. **Toast** — bas gauche, `--card`, rayon 12, élévation 3, auto-disparition 5 s ; libellé « Fermer », jamais « Annuler » sur un mouvement déjà écrit.

**Indicateur d'étapes** (transfert, réception) — cercle 26 numéroté + trait de liaison 2 px + libellé 12/600. États : franchi (`ok`), courant (`info`), à venir (`neutral`) ; étape annulée = ligne entière en `error`.

---

## 7. Composants mobile (Flutter, aspect)

**Cibles tactiles** — plancher 44, défaut 48, action principale 52-56 ; jamais deux cibles à < 8 px. Ligne de liste ≥ 56, champ 52 (46 en liste dense), onglet 56, bouton flottant scan 58 (rayon 19).

**Bouton** — rayon 10, padding H 16, texte 15,5-17/600, icône 19 avant le libellé, **libellé aligné à gauche** (pleine largeur ne centre pas). Primaire fond `accent`/texte `onAccent` ; secondaire `surface2`+bordure `line` ; fantôme 44 px sans fond `accentHi`.

**Ligne de liste** — `surface`, séparateur `lineSoft`, padding 13/16, ≥ 56. Pastille 38 rayon 11 + libellé 14,5/600 + méta 12,5 `ink3` (1 ligne, ellipse) + badge/chevron. Appui : `surface2`.

**Pas de quantité** — `−` 56 | champ 56 texte 24-26/700 centré | `+` 56. Champ **pré-rempli avec la valeur attendue** (confirmer > saisir). Clavier numérique, bouton « Tout ». Conséquence écrite en clair sous le champ (« Stock dépôt après validation : 180 pce »).

**Feuille modale basse** — rayon 20 haut, poignée 44×4, padding 18/16/20, montée 200 ms, scène `rgba(4,7,11,.66)`. Pour résultat de scan, encaissement, choix de client — jamais de saisie longue ni de navigation.

**Barre d'onglets** — **4 onglets max**, le 4ᵉ = « Plus ». `surface`, séparateur haut `line`, icône 21 + libellé 10,5/600, actif `accentHi`. Métiers qui scannent : bouton flottant central de scan 58 (rayon 19, bordure 4 px de la couleur de la barre, −24 px au-dessus).

**Bandeau d'alerte en ligne** — fond `-bg`, bordure du ton assombri, rayon 10, padding 12, icône 15 + texte 12,5 `-fg` + action à droite si réponse existe.

**Badge de synchronisation** — **permanent dans l'en-tête** : `✓ Synchronisé` (`ok`) ou `⟳ 3 en attente` (`warn`, nombre exact). Une opération en file n'est jamais « confirmée » : « enregistrée · en attente de synchronisation ».

---

## 8. États obligatoires (chaque liste/écran de données)

**Chargement** : squelettes aux dimensions réelles (3-8), pulsation 1,4 s — jamais de roue centrée. **Vide** : titre 17-18/700 + explication ≤ 56 car. + action de sortie (mobile : icône 56 dans pastille `surface2`) — jamais d'illustration. **Aucun résultat** : reprend le terme recherché. **Erreur** : dire ce qui a échoué + garantir les données saisies + « Réessayer » (la saisie n'est jamais perdue). **Hors-ligne** (mobile) : badge de sync + libellés adaptés.

Rédaction : dire ce qui s'est passé, pas le code. « Le serveur n'a pas répondu. Vos quantités sont conservées. » — pas « Erreur 500 ».

---

## 9. Grille et adaptation

**Desktop** : sidebar 246 fixe, contenu marge 20. KPI `repeat(auto-fit, minmax(196px,1fr))` gouttière 14. Rangée dashboard `1.5fr 1fr 1fr` → 1 colonne sous 1180. Détail `1.6fr 1fr` → empilé sous 1180. Caisse `1fr 386px` → ticket sous le catalogue sous 1180. **Tableau > 6 colonnes** : carte `overflow-x:auto`, `min-width:max-content`, 1ʳᵉ colonne (identité) lisible ; jamais de colonne hors écran sans défilement.

**Tablette (768-1180)** : sidebar en rail d'icônes 64 px, grilles 1 colonne, tableaux en défilement H ; réception/préparation/comptage adoptent les cibles tactiles mobiles.

**Mobile** : 1 colonne, marge 16. Aucun tableau (toute donnée tabulaire → liste ou paire étiquette/valeur). Deux tuiles côte à côte max.

---

## 10. Tableaux de bord — mise en page mappée sur les 3 rôles du projet

Structure commune : salutation + date → grille de KPI → graphique principal + répartition + file d'action → activité récente + top produits + tâches. **Ne jamais montrer une info hors du métier d'un rôle** (un magasinier ne voit aucun CA).

| Rôle projet | KPI (max 6) | Action principale |
|---|---|---|
| **ADMIN** (regroupe Administrateur + Gérant du design) | CA du jour · CA du mois vs objectif · Marge brute · Valeur du stock · Ruptures · À traiter | Nouvelle vente / Exporter le rapport |
| **VENDEUR** (regroupe Caissier + Responsable magasin) | Mes ventes du jour · Panier moyen · Tickets en attente · Sous le seuil · Encours client · Ma caisse | Nouvelle vente |
| **MAGASINIER** | Réceptions du jour · Transferts à préparer · Colis à expédier · Références dépôt · Écarts · Emplacement saturé | Réceptionner |

Navigation mobile (4 onglets + bouton flottant) : VENDEUR = Accueil · Ventes · Stock · Plus (+ Scanner) ; MAGASINIER = Accueil · Demandes · Réceptions · Plus (+ Scanner) ; ADMIN = Accueil · Activité · Stock · Plus.

---

## 11. Implémentation

**Desktop** : thème et densité = deux attributs sur `<html>` (`data-theme`, `data-density`), aucun composant ne lit le thème. Tokens en variables CSS (voir §2).

**Mobile Flutter** : `ThemeExtension<AmpereColors>` portant tous les tokens ci-dessus ; `ThemeData(fontFamily:'Archivo')` avec le `TextTheme` de §3.2 ; police Archivo bundlée en asset. Deux thèmes (dark défaut + light).

---

## 12. Interdictions visuelles

1. Afficher un montant sans sa devise, ou une quantité sans son unité.
2. Masquer le SKU au profit du seul libellé produit.
3. Mettre un graphique sur mobile.
4. Utiliser la couleur seule pour un statut (toujours un libellé texte en plus).
5. Descendre une cible tactile sous 44 px.
6. « Annuler » sur un toast confirmant un mouvement déjà écrit.
7. Un dialogue de confirmation sur une action non destructive.
8. Un rayon hors de la liste du §4.
9. Un dégradé, un flou décoratif ou une lueur — hors l'aire du graphique principal et le flou de la barre supérieure.
10. `outline:none` sur un élément interactif (focus toujours visible : `2px solid var(--accent)`).

Accessibilité : texte ≥ 4,5:1, titres ≥ 3:1 ; focus visible partout ; clavier complet sur desktop (`Échap` ferme toute couche) ; cibles 44 px mobile/tablette ; `prefers-reduced-motion` respecté ; zoom texte 200 % utilisable ; champ désignation arabe en `direction:rtl`, interface LTR.

---

*Référence visuelle AMPÈRE. Toute valeur absente se dérive des tokens des §2 à §5. Ce document n'affecte aucune logique du projet.*
