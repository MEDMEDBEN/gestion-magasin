import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../widgets/ampere_controls.dart';
import '../widgets/form_panel.dart';

/// CLAVIER — une seule convention pour toute l'application (demande MEDMEDBEN
/// du 2026-11-13 : « comme les grands logiciels, selon les standards »).
///
/// Fenêtres (dialogues)   Entrée = bouton principal · Échap = annuler
/// Panneaux de saisie      Entrée = champ suivant · Ctrl+S / Ctrl+Entrée =
///                         enregistrer · Échap = fermer
/// Pages (listes)          Ctrl+F = rechercher · Ctrl+N ou Inser = nouveau
///                         (navigateur : Chrome garde Ctrl+N, Inser marche)
/// Partout                 F1 = aide clavier · Ctrl+K = assistant ·
///                         Alt+Origine = accueil · Alt+1…9 = menu
/// Vente (caisse)          F2 chercher/scanner · F4 acheteur · F6 remise ·
///                         F7 devis · F9 encaisser · Ctrl+Suppr vider
///
/// `kShortcuts` est LA liste : l'aide F1 l'affiche telle quelle.
const kShortcuts = <(String, List<(String, String)>)>[
  (
    'Partout',
    [
      ('F1', 'Aide : ces raccourcis'),
      ('Ctrl+K', 'Assistant (chercher une page, une action)'),
      ('Alt+Origine', 'Retour à l’accueil'),
      ('Alt+1 … Alt+9', 'Ouvrir l’entrée 1 à 9 du menu'),
    ],
  ),
  (
    'Pages',
    [
      ('Ctrl+F', 'Aller dans la recherche'),
      ('Ctrl+N ou Inser', 'Nouveau (produit, client, commande…)'),
      ('Échap', 'Dans une recherche : l’effacer'),
    ],
  ),
  (
    'Fenêtres de confirmation',
    [
      ('Entrée', 'Valider (bouton principal)'),
      ('Échap', 'Annuler / fermer'),
      ('Tab / Maj+Tab', 'Bouton ou champ suivant / précédent'),
    ],
  ),
  (
    'Panneaux de saisie',
    [
      ('Entrée', 'Champ suivant'),
      ('Ctrl+S ou Ctrl+Entrée', 'Enregistrer'),
      ('Échap', 'Fermer sans enregistrer'),
    ],
  ),
  (
    'Vente (caisse)',
    [
      ('F2', 'Chercher / scanner un produit'),
      ('Entrée', 'Dans la recherche : ajouter le produit trouvé'),
      ('F4', 'Choisir l’acheteur'),
      ('F6', 'Remise sur la facture'),
      ('F7', 'Faire un devis'),
      ('F9', 'Encaisser'),
      ('Ctrl+Suppr', 'Vider le panier (avec confirmation)'),
    ],
  ),
];

/// Actions clavier d'une PAGE (Ctrl+F, Ctrl+N). La page visible la plus
/// récemment montée et sans fenêtre ouverte par-dessus les reçoit.
class PageShortcuts extends StatefulWidget {
  const PageShortcuts({
    super.key,
    this.onSearch,
    this.onCreate,
    required this.child,
  });

  final VoidCallback? onSearch;
  final VoidCallback? onCreate;
  final Widget child;

  @override
  State<PageShortcuts> createState() => _PageShortcutsState();
}

class _PageShortcutsState extends State<PageShortcuts> {
  static final _mounted = <_PageShortcutsState>[];

  @override
  void initState() {
    super.initState();
    _mounted.add(this);
  }

  @override
  void dispose() {
    _mounted.remove(this);
    super.dispose();
  }

  /// La page au premier plan : sa route est la route courante (aucune
  /// fenêtre par-dessus) et elle est affichée (pas une page masquée).
  static _PageShortcutsState? get active {
    for (final page in _mounted.reversed) {
      if (!page.mounted) continue;
      if (ModalRoute.of(page.context)?.isCurrent == false) continue;
      if (!TickerMode.valuesOf(page.context).enabled) continue;
      return page;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Racine clavier, posée UNE fois autour de l'application (`main.dart`).
/// Ne prend que les touches que personne d'autre n'a traitées.
class KeyboardRoot extends StatelessWidget {
  const KeyboardRoot({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, event) =>
          handleKey(event) ? KeyEventResult.handled : KeyEventResult.ignored,
      child: child,
    );
  }

  static bool handleKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final keys = HardwareKeyboard.instance;
    final key = event.logicalKey;
    final ctrl = keys.isControlPressed || keys.isMetaPressed;
    final enter =
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter;

    if (key == LogicalKeyboardKey.f1 && !ctrl) return _showHelp();
    if (ctrl && (key == LogicalKeyboardKey.keyS || enter)) return _submit();
    if (enter && !ctrl && !keys.isAltPressed && !keys.isShiftPressed) {
      return _enter();
    }
    if (ctrl && key == LogicalKeyboardKey.keyF) {
      final action = _PageShortcutsState.active?.widget.onSearch;
      if (action != null) {
        action();
        return true;
      }
      return _focusSearchField();
    }
    if ((ctrl && key == LogicalKeyboardKey.keyN) ||
        (key == LogicalKeyboardKey.insert && !ctrl)) {
      final action = _PageShortcutsState.active?.widget.onCreate;
      if (action != null) {
        action();
        return true;
      }
      return _pressCreateButton();
    }
    return false;
  }

  /// Parcourt ce qui est À L'ÉCRAN : page courante (pas une page masquée,
  /// pas une page sous une fenêtre). `visit` rend `true` pour s'arrêter.
  static void _visibleElements(bool Function(Element) visit) {
    var done = false;
    void walk(Element e) {
      if (done) return;
      final w = e.widget;
      if (w is Offstage && w.offstage) return;
      if (w is Visibility && !w.visible) return;
      if (w is TickerMode && !w.enabled) return;
      if (visit(e)) {
        done = true;
        return;
      }
      e.visitChildElements(walk);
    }

    final root = WidgetsBinding.instance.rootElement;
    if (root != null) walk(root);
  }

  static bool _onCurrentRoute(Element e) => ModalRoute.of(e)?.isCurrent ?? true;

  /// Icônes qui marquent un champ de RECHERCHE (loupe ; douchette en Vente).
  static final _searchIcons = {
    LucideIcons.search,
    Icons.search,
    LucideIcons.scanBarcode,
  };

  /// Ctrl+F : le champ de recherche de la page (celui à la loupe).
  static bool _focusSearchField() {
    FocusNode? node;
    _visibleElements((e) {
      final w = e.widget;
      if (w is TextField &&
          w.decoration?.prefixIcon is Icon &&
          _searchIcons.contains((w.decoration!.prefixIcon! as Icon).icon) &&
          _onCurrentRoute(e)) {
        void find(Element c) {
          if (node != null) return;
          if (c.widget is EditableText) {
            node = (c.widget as EditableText).focusNode;
            return;
          }
          c.visitChildElements(find);
        }

        find(e);
        return node != null;
      }
      return false;
    });
    node?.requestFocus();
    return node != null;
  }

  /// Ctrl+N / Inser : le bouton « Nouveau… » / « Nouvelle… » de la page.
  static bool _pressCreateButton() {
    VoidCallback? press;
    bool isCreate(String? text) {
      final t = (text ?? '').trimLeft().toLowerCase();
      return t.startsWith('nouveau') || t.startsWith('nouvelle');
    }

    String? labelOf(Element e) {
      String? found;
      void find(Element c) {
        if (found != null) return;
        if (c.widget is Text) {
          found = (c.widget as Text).data;
          return;
        }
        c.visitChildElements(find);
      }

      find(e);
      return found;
    }

    _visibleElements((e) {
      final w = e.widget;
      if (!_onCurrentRoute(e) || ModalRoute.of(e) is PopupRoute) return false;
      if (w is ButtonStyleButton &&
          w.onPressed != null &&
          isCreate(labelOf(e))) {
        press = w.onPressed;
        return true;
      }
      if (w is IconButton && w.onPressed != null && isCreate(w.tooltip)) {
        press = w.onPressed;
        return true;
      }
      return false;
    });
    press?.call();
    return press != null;
  }

  /// Entrée : bouton principal d'une fenêtre ; champ suivant d'un panneau.
  static bool _enter() {
    final focused = FocusManager.instance.primaryFocus;
    final context = focused?.context;
    if (context == null) return false;
    // Le focus est-il DANS ce qui est au premier plan ? (Sinon il est resté
    // sur la page sous une fenêtre : seul le bouton de la fenêtre compte.)
    final onTop = ModalRoute.of(context)?.isCurrent ?? true;
    final editable = onTop
        ? context.findAncestorWidgetOfExactType<EditableText>()
        : null;
    if (onTop) {
      // Un bouton, une case, une ligne de liste a le focus : Entrée l'active
      // (comportement natif) — jamais le bouton principal à sa place.
      if (context.findAncestorWidgetOfExactType<InkWell>() != null) {
        return false;
      }
      // Texte sur plusieurs lignes : Entrée va à la ligne. Un champ qui a
      // SON geste pour Entrée (recherche, montant…) le garde.
      if (editable != null &&
          (editable.maxLines != 1 || editable.onSubmitted != null)) {
        return false;
      }
    }
    final container = _container(context);
    final inPanel =
        onTop &&
        context.findAncestorWidgetOfExactType<FormPanelFrame>() != null;
    return switch (container?.widget) {
      FormPanelFrame() when editable != null && inPanel => focused!.nextFocus(),
      FormPanelFrame() => false,
      AlertDialog() || Dialog() => _pressPrimary(container!),
      _ => false,
    };
  }

  /// Ctrl+S / Ctrl+Entrée : enregistrer le panneau, valider la fenêtre.
  static bool _submit() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    final container = _container(context);
    final widget = container?.widget;
    if (widget is FormPanelFrame) {
      widget.onSubmit?.call();
      return widget.onSubmit != null;
    }
    if (widget is AlertDialog || widget is Dialog) {
      return _pressPrimary(container!);
    }
    return false;
  }

  /// La fenêtre ou le panneau qui contient le focus : en remontant depuis le
  /// champ, ou — focus sur la fenêtre elle-même — en descendant dedans.
  static Element? _container(BuildContext context) {
    bool isContainer(Widget w) =>
        w is FormPanelFrame || w is AlertDialog || w is Dialog;
    Element? found;
    context.visitAncestorElements((e) {
      if (isContainer(e.widget)) {
        found = e;
        return false;
      }
      // Pas plus haut que la route : la page dessous n'est pas concernée.
      return e.widget is! Navigator;
    });
    // Le focus est resté sur la page du dessous (une fenêtre ne le prend pas
    // toujours) : la fenêtre AU PREMIER PLAN, celle de la route courante.
    if (found == null || ModalRoute.of(found!)?.isCurrent == false) {
      found = null;
      _visibleElements((e) {
        if (isContainer(e.widget) && ModalRoute.of(e)?.isCurrent == true) {
          found = e;
          return true;
        }
        return false;
      });
    }
    return found;
  }

  /// Bouton principal = le DERNIER bouton plein (ou « danger ») actif —
  /// convention Material et Windows : il valide, à droite. Jamais « Annuler »
  /// (bouton texte) : une fenêtre sans bouton plein laisse Entrée tranquille.
  static bool _pressPrimary(Element element) {
    final container = element.widget;
    VoidCallback? last;
    void visit(Element e) {
      final w = e.widget;
      final onPressed = switch (w) {
        FilledButton() ||
        ElevatedButton() => (w as ButtonStyleButton).onPressed,
        AmpereDangerButton() => w.onPressed,
        _ => null,
      };
      if (onPressed != null) last = onPressed;
      // On ne descend pas dans un bouton déjà retenu (icône + texte).
      if (w is! ButtonStyleButton) e.visitChildElements(visit);
    }

    if (container is AlertDialog && container.actions != null) {
      // Seules les actions comptent (pas un bouton dans le contenu).
      final actions = container.actions!;
      for (final a in actions.reversed) {
        final onPressed = switch (a) {
          FilledButton() ||
          ElevatedButton() => (a as ButtonStyleButton).onPressed,
          AmpereDangerButton() => a.onPressed,
          _ => null,
        };
        if (onPressed != null) {
          onPressed();
          return true;
        }
      }
    }
    element.visitChildElements(visit);
    last?.call();
    return last != null;
  }

  static bool _showHelp() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null || !context.mounted) return false;
    showKeyboardHelp(context);
    return true;
  }
}

/// F1 : la liste de TOUS les raccourcis, groupés.
Future<void> showKeyboardHelp(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      return AlertDialog(
        title: const Text('Raccourcis clavier'),
        content: SizedBox(
          width: 520,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final (group, rows) in kShortcuts) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 4),
                  child: Text(group, style: theme.textTheme.titleSmall),
                ),
                for (final (keys, label) in rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        SizedBox(width: 170, child: KeyCap(keys)),
                        Expanded(child: Text(label)),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Fermer'),
          ),
        ],
      );
    },
  );
}

/// Touche affichée comme sur un clavier : « F9 », « Ctrl+S ».
class KeyCap extends StatelessWidget {
  const KeyCap(this.keys, {super.key});

  final String keys;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Text(
          keys,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            fontFamily: 'monospace',
          ),
        ),
      ),
    );
  }
}
