/// Points de rupture AMPÈRE (`docs/design-system.md` §9).
///
/// - `< 768`        : **mobile** — coquille à onglets, palette mobile, cibles 44+ ;
/// - `768 – 1180`   : **tablette** — coquille desktop avec sidebar en rail
///                    d'icônes 64 px, grilles sur 1 colonne ;
/// - `≥ 1180`       : **desktop** — sidebar complète 246 px.
///
/// Le mobile n'est PAS une copie miniature du desktop (spec §29) : les deux
/// coquilles sont des mises en page distinctes, sur une logique métier commune.
const double kTabletMinWidth = 768;
const double kDesktopMinWidth = 1180;

/// Mise en page « desktop » (tablette comprise) : tableaux, panneau latéral,
/// palette desktop. En dessous, on est sur mobile.
bool isDesktopWidth(double width) => width >= kTabletMinWidth;
