import 'package:flutter/material.dart';

/// Guide d'utilisation (demande MEDMEDBEN du 2026-10-05) : les gestes du
/// quotidien, en phrases courtes. Ouvert depuis l'assistant (« aide »).
class GuideScreen extends StatelessWidget {
  const GuideScreen({super.key});

  static const _sections = <(String, List<String>)>[
    (
      'L’assistant',
      [
        'Ouvrez-le avec le bouton ✦ en haut de l’écran (Ctrl+K sur le poste).',
        'Tapez ce que vous voulez faire, en français, en darija ou en '
            'anglais : « ajoute câble 3G2,5 », « zid câble », « bi3 », '
            '« chof disjoncteur », « stock gaine », « aide ».',
        '« Entrée » lance la première action proposée.',
      ],
    ),
    (
      'Vendre',
      [
        'Ouvrez votre caisse (fond de caisse) avant le premier encaissement.',
        'Scannez le code-barres (douchette ou caméra du téléphone) ou cherchez '
            'le produit : il entre dans le panier.',
        'Le crayon modifie le prix d’une ligne : le prix d’achat est affiché, '
            'on ne descend jamais en dessous.',
        'Encaissez : montant reçu, la monnaie à rendre est calculée. Sans '
            'réseau, la vente part en attente et se synchronise ensuite.',
        'En fin de journée, clôturez la caisse : comptez, l’écart est calculé.',
      ],
    ),
    (
      'Catalogue',
      [
        '« Nouveau produit » : nom, référence, unité (pièce, mètre, boîte), '
            'prix ; le code-barres est généré s’il n’y en a pas.',
        'Sur chaque ligne : étiquette, modifier, supprimer (le produit sort du '
            'catalogue, son historique reste).',
        '« Sélectionner » : cochez des produits pour les exporter (PDF, Excel) '
            'ou imprimer leurs étiquettes.',
        'Le seuil minimum déclenche l’alerte de stock et la proposition de '
            'réapprovisionnement.',
      ],
    ),
    (
      'Stock et dépôt',
      [
        'Stock : quantités au magasin et au dépôt, cherchez par nom ou '
            'code-barres.',
        'Transferts : le magasin demande, le dépôt prépare et expédie, le '
            'magasin réceptionne.',
        'Achats : commande au fournisseur, puis réception (même partielle) ; '
            'une facture peut être lue par photo.',
      ],
    ),
    (
      'Historique et rapports',
      [
        'Chaque liste d’historique a un filtre « Période » : un jour précis, ou '
            'du … au … .',
        'Rapports : chiffre d’affaires, marge (prix de vente − dernier prix '
            'd’achat), stock, achats.',
      ],
    ),
    (
      'Sans réseau',
      [
        'L’application s’ouvre sur le dernier compte connecté (72 h au plus).',
        'Ventes, caisse, paiements et transferts sont gardés « en attente de '
            'synchronisation » et partent au retour du réseau.',
        'Le serveur revérifie tout : une opération impossible (stock '
            'insuffisant) est refusée et signalée.',
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Guide d’utilisation')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final (title, steps) in _sections)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    for (final step in steps)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text('•  $step'),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
