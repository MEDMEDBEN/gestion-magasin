import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../ui/navigation.dart';
import '../../ui/widgets/form_panel.dart';
import '../auth/data/auth_models.dart';
import '../catalog/application/catalog_controller.dart';
import '../catalog/data/catalog_models.dart';
import '../catalog/presentation/catalog_screen.dart';
import '../catalog/presentation/product_form.dart';
import 'guide_screen.dart';

/// Assistant de l'app (demande MEDMEDBEN du 2026-10-05) : PAS une IA. Une
/// liste d'actions PRÉPARÉES, reconnues par des mots-clés en français, en
/// darija (écrite en lettres latines) et en anglais. « ajoute câble 3G2,5 »,
/// « zid câble 3G2,5 » et « add câble 3G2,5 » ouvrent la même fiche produit,
/// le nom déjà rempli. Une action n'est proposée que si le compte a l'écran
/// correspondant (mêmes droits que le menu).
class AssistantCommand {
  const AssistantCommand({
    required this.title,
    required this.example,
    required this.icon,
    required this.keywords,
    required this.run,
    this.destination,
    this.allowed,
  });

  final String title;

  /// Exemple affiché sous le titre (ce qu'on peut taper).
  final String example;
  final IconData icon;

  /// Mots qui déclenchent l'action, déjà « pliés » (minuscules, sans accent).
  final List<String> keywords;

  /// Écran requis (libellé du menu) ; `null` = toujours proposée.
  final String? destination;

  /// Condition de droit supplémentaire (ex. créer un produit).
  final bool Function(AuthUser user)? allowed;

  /// Exécute l'action ; `argument` = le reste de la phrase (ex. le nom).
  final Future<void> Function(
    BuildContext context,
    WidgetRef ref,
    AuthUser user,
    String argument,
  )
  run;
}

/// Minuscules, sans accents : « Étiquette » et « etiquette » se valent.
String fold(String text) {
  const from = 'àâäáãåçéèêëíìîïñóòôöõúùûüýÿœ';
  const to = 'aaaaaaceeeeiiiinooooouuuuyyo';
  final lower = text.toLowerCase();
  final out = StringBuffer();
  for (final rune in lower.runes) {
    final ch = String.fromCharCode(rune);
    final i = from.indexOf(ch);
    out.write(i >= 0 ? to[i] : ch);
  }
  return out.toString();
}

/// Mots sans intérêt pour l'argument (« ajoute UN produit … »).
const _filler = {
  'un',
  'une',
  'le',
  'la',
  'les',
  'du',
  'de',
  'des',
  'd',
  'l',
  'a',
  'au',
  'produit',
  'article',
  'nouveau',
  'nouvel',
  'nouvelle',
  'new',
  'the',
  'w',
  'pour',
  'moi',
  'li',
  'wahed',
  'wa7ed',
  'please',
  'stp',
  'svp',
};

/// Résultat de la reconnaissance : l'action et le reste de la phrase.
typedef AssistantMatch = ({AssistantCommand command, String argument});

/// Les actions qui correspondent à `input`, les meilleures d'abord. Une
/// phrase vide rend toutes les actions permises, dans l'ordre de la liste.
List<AssistantMatch> matchCommands(
  String input,
  List<AssistantCommand> commands,
) {
  final words = input.trim().split(RegExp(r'\s+'))
    ..removeWhere((w) => w.isEmpty);
  if (words.isEmpty) {
    return [for (final c in commands) (command: c, argument: '')];
  }
  final folded = [for (final w in words) fold(w)];
  final scored = <(int, AssistantMatch)>[];
  for (final command in commands) {
    var score = 0;
    final used = <int>{};
    for (final keyword in command.keywords) {
      final parts = keyword.split(' ');
      for (var i = 0; i + parts.length <= folded.length; i++) {
        var hit = true;
        for (var j = 0; j < parts.length; j++) {
          final w = folded[i + j];
          // Un mot-clé d'au moins 4 lettres reconnaît aussi son début tapé
          // (« etiq » → « etiquette ») ; plus court, il doit être exact.
          final ok =
              w == parts[j] ||
              (parts[j].length >= 4 && w.length >= 3 && parts[j].startsWith(w));
          if (!ok) {
            hit = false;
            break;
          }
        }
        if (hit) {
          score += keyword.length;
          for (var j = 0; j < parts.length; j++) {
            used.add(i + j);
          }
        }
      }
    }
    if (score == 0) continue;
    final argument = [
      for (var i = 0; i < words.length; i++)
        if (!used.contains(i) && !_filler.contains(folded[i])) words[i],
    ].join(' ');
    scored.add((score, (command: command, argument: argument)));
  }
  scored.sort((a, b) => b.$1.compareTo(a.$1));
  return [for (final (_, m) in scored) m];
}

/// Ouvre la fiche « nouveau produit », le nom pré-rempli.
Future<void> _addProduct(
  BuildContext context,
  WidgetRef ref,
  AuthUser user,
  String name,
) async {
  final rights = CatalogRights(user);
  final saved = await openFormPanel<Product>(
    context,
    ProductForm(
      initialName: name.isEmpty ? null : name,
      canEdit: rights.canWriteProducts,
      canDisable: rights.canDisableProducts,
      canReadStock: rights.canReadStock,
      canReadSuppliers: rights.canReadSuppliers,
      canSetPrices: rights.canSetPrices,
    ),
  );
  if (saved != null && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${saved.name} créé — code-barres ${saved.barcode}.'),
      ),
    );
  }
}

/// Va à un écran ; avec un texte, le cherche dans le catalogue (le filtre
/// des produits est partagé par Catalogue et Stock).
Future<void> Function(BuildContext, WidgetRef, AuthUser, String) _goTo(
  String label, {
  bool search = false,
}) => (context, ref, user, argument) async {
  if (search && argument.isNotEmpty) {
    ref.read(requestedSearchProvider.notifier).ask(argument);
  }
  goToDestination(ref, label);
};

/// Toutes les actions préparées. L'ordre est celui de la liste « vide ».
final assistantCommands = <AssistantCommand>[
  AssistantCommand(
    title: 'Ajouter un produit',
    example: 'ajoute câble 3G2,5 · zid câble · add cable',
    icon: LucideIcons.packagePlus,
    keywords: const [
      'ajoute',
      'ajouter',
      'ajout',
      'cree',
      'creer',
      'nouveau produit',
      'zid',
      'zidli',
      'dir produit',
      'add',
      'create',
      'new product',
    ],
    allowed: (user) => CatalogRights(user).canWriteProducts,
    run: _addProduct,
  ),
  AssistantCommand(
    title: 'Nouvelle vente',
    example: 'vente · vendre · bi3 · sell',
    icon: LucideIcons.shoppingCart,
    keywords: const [
      'vente',
      'vendre',
      'vends',
      'encaisser',
      'caisse',
      'ticket',
      'bi3',
      'nbi3',
      'bi3a',
      'sell',
      'sale',
      'checkout',
    ],
    destination: 'Vente',
    run: _goTo('Vente'),
  ),
  AssistantCommand(
    title: 'Chercher un produit',
    example: 'cherche disjoncteur · hawes · find',
    icon: LucideIcons.search,
    keywords: const [
      'cherche',
      'chercher',
      'recherche',
      'trouve',
      'trouver',
      'prix',
      'hawes',
      'chof',
      'chouf',
      'find',
      'search',
      'price',
    ],
    destination: 'Catalogue',
    run: _goTo('Catalogue', search: true),
  ),
  AssistantCommand(
    title: 'Voir le stock',
    example: 'stock câble · kayen · combien',
    icon: LucideIcons.boxes,
    keywords: const [
      'stock',
      'quantite',
      'combien',
      'reste',
      'kayen',
      'chhal',
      'inventory',
      'how many',
    ],
    destination: 'Stock',
    run: _goTo('Stock', search: true),
  ),
  AssistantCommand(
    title: 'Étiquette : trouver le produit',
    example: 'étiquette câble · tiquette · label',
    icon: LucideIcons.tag,
    keywords: const ['etiquette', 'etiquettes', 'tiquette', 'label', 'labels'],
    destination: 'Catalogue',
    run: _goTo('Catalogue', search: true),
  ),
  AssistantCommand(
    title: 'Demander un transfert',
    example: 'transfert · jib men depot · transfer',
    icon: LucideIcons.arrowLeftRight,
    keywords: const [
      'transfert',
      'transferer',
      'depot',
      'jib',
      'jibli',
      'transfer',
    ],
    destination: 'Transferts',
    run: _goTo('Transferts'),
  ),
  AssistantCommand(
    title: 'Commande fournisseur',
    example: 'commande · acheter · chri · order',
    icon: LucideIcons.truck,
    keywords: const [
      'commande',
      'commander',
      'acheter',
      'achat',
      'achats',
      'fournisseur',
      'chri',
      'nechri',
      'order',
      'purchase',
      'buy',
    ],
    destination: 'Achats',
    run: _goTo('Achats'),
  ),
  AssistantCommand(
    title: 'Rapports et chiffre d’affaires',
    example: 'rapport · chiffre · marge · report',
    icon: LucideIcons.chartColumn,
    keywords: const [
      'rapport',
      'rapports',
      'chiffre',
      'marge',
      'benefice',
      'report',
      'revenue',
      'profit',
      '9edach',
    ],
    destination: 'Rapports',
    run: _goTo('Rapports'),
  ),
  AssistantCommand(
    title: 'Historique',
    example: 'historique · qui a fait · history',
    icon: LucideIcons.history,
    keywords: const ['historique', 'journal', 'audit', 'history', 'log'],
    destination: 'Historique',
    run: _goTo('Historique'),
  ),
  AssistantCommand(
    title: 'Scanner un code-barres',
    example: 'scanner · scan',
    icon: LucideIcons.scanBarcode,
    keywords: const ['scanner', 'scan', 'code barre', 'codebarre', 'barcode'],
    destination: 'Scanner',
    run: _goTo('Scanner'),
  ),
  AssistantCommand(
    title: 'Guide d’utilisation',
    example: 'aide · comment · kifach · help',
    icon: LucideIcons.bookOpen,
    keywords: const [
      'aide',
      'guide',
      'comment',
      'aider',
      'kifach',
      'kifech',
      'help',
      'how',
    ],
    run: (context, ref, user, argument) => Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const GuideScreen())),
  ),
];

/// Actions permises à ce compte.
List<AssistantCommand> commandsFor(AuthUser user) {
  final open = destinationsFor(user).map((d) => d.label).toSet();
  return [
    for (final c in assistantCommands)
      if ((c.destination == null || open.contains(c.destination)) &&
          (c.allowed?.call(user) ?? true))
        c,
  ];
}

/// Ouvre l'assistant. L'action choisie s'exécute APRÈS la fermeture de la
/// fenêtre (le contexte de l'écran, pas celui de la fenêtre).
Future<void> showAssistant(
  BuildContext context,
  WidgetRef ref,
  AuthUser user,
) async {
  final picked = await showDialog<AssistantMatch>(
    context: context,
    builder: (_) => _AssistantDialog(commands: commandsFor(user)),
  );
  if (picked == null || !context.mounted) return;
  await picked.command.run(context, ref, user, picked.argument);
}

class _AssistantDialog extends StatefulWidget {
  const _AssistantDialog({required this.commands});

  final List<AssistantCommand> commands;

  @override
  State<_AssistantDialog> createState() => _AssistantDialogState();
}

class _AssistantDialogState extends State<_AssistantDialog> {
  String _input = '';

  @override
  Widget build(BuildContext context) {
    final matches = matchCommands(_input, widget.commands);
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: SizedBox(
        width: 560,
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: TextField(
                autofocus: true,
                autocorrect: false,
                decoration: const InputDecoration(
                  prefixIcon: Icon(LucideIcons.sparkles, size: 18),
                  hintText: 'Que voulez-vous faire ? (ex. ajoute câble 3G2,5)',
                ),
                onChanged: (v) => setState(() => _input = v),
                // « Entrée » lance la première action proposée.
                onSubmitted: (value) {
                  // Le texte VALIDÉ, pas celui du dernier affichage : « Entrée »
                  // juste après la frappe ne doit pas lancer une action périmée.
                  final submitted = matchCommands(value, widget.commands);
                  if (submitted.isNotEmpty) {
                    Navigator.of(context).pop(submitted.first);
                  }
                },
              ),
            ),
            Expanded(
              child: matches.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Aucune action ne correspond. Tapez « aide » pour '
                        'le guide d’utilisation.',
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView(
                      children: [
                        for (final m in matches)
                          ListTile(
                            leading: Icon(m.command.icon),
                            title: Text(
                              m.argument.isEmpty
                                  ? m.command.title
                                  : '${m.command.title} : « ${m.argument} »',
                            ),
                            subtitle: Text(m.command.example),
                            onTap: () => Navigator.of(context).pop(m),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
