import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/photos.dart';
import 'package:gestion_magasin/core/providers.dart';
import 'package:gestion_magasin/data/models/page_meta.dart';
import 'package:gestion_magasin/features/auth/data/auth_models.dart';
import 'package:gestion_magasin/features/catalog/application/catalog_controller.dart';
import 'package:gestion_magasin/features/messaging/application/conversations_controller.dart';
import 'package:gestion_magasin/features/messaging/data/conversation_models.dart';
import 'package:gestion_magasin/features/problems/presentation/problem_form.dart';
import 'package:gestion_magasin/features/problems/data/problem_models.dart';
import 'package:gestion_magasin/features/problems/data/problems_api.dart';
import 'package:gestion_magasin/features/problems/presentation/problems_screen.dart';
import 'package:gestion_magasin/ui/theme/ampere_colors.dart';
import 'package:gestion_magasin/ui/theme/app_theme.dart';

import 'support/fakes.dart';

/// Signalements (P1 n°18) : l'écran ne propose que les actions que le serveur
/// accepterait — un bouton qui refuse est un piège.
class _FakeProblemsApi extends ProblemsApi {
  _FakeProblemsApi(this.items) : super(Dio());

  List<Problem> items;
  final started = <String>[];
  final closed = <String>[];
  final resolved = <(String, String)>[];
  final assigned = <(String, String)>[];
  final photos = <(String, int)>[];
  final created = <Map<String, Object?>>[];

  @override
  Future<ProblemPage> list({
    int page = 1,
    int limit = 50,
    ProblemStatus? status,
    bool mine = false,
  }) async {
    final visible = [
      for (final p in items)
        if (status == null || p.status == status) p,
    ];
    return ProblemPage(
      data: visible,
      meta: PageMeta(page: page, limit: limit, total: visible.length),
    );
  }

  @override
  Future<Problem> start(String id) async {
    started.add(id);
    return items.firstWhere((p) => p.id == id);
  }

  @override
  Future<Problem> resolve(String id, String resolution) async {
    resolved.add((id, resolution));
    return items.firstWhere((p) => p.id == id);
  }

  @override
  Future<Problem> close(String id) async {
    closed.add(id);
    return items.firstWhere((p) => p.id == id);
  }

  @override
  Future<Problem> assign(String id, String assignedToId) async {
    assigned.add((id, assignedToId));
    return items.firstWhere((p) => p.id == id);
  }

  @override
  Future<Problem> attachPhoto(String id, Uint8List bytes) async {
    photos.add((id, bytes.length));
    return items.firstWhere((p) => p.id == id).copyWith(hasPhoto: true);
  }

  @override
  Future<Uint8List> photoBytes(String id) async => _onePixelPng;

  @override
  Future<Problem> create({
    required String title,
    required ProblemCategory category,
    required String description,
    required ProblemPriority priority,
    String? productId,
    String? locationId,
  }) async {
    created.add({
      'title': title,
      'category': category.wire,
      'description': description,
      'priority': priority.wire,
      'productId': productId,
    });
    return _problem(title: title);
  }
}

/// PNG 1x1 : `Image.memory` doit pouvoir le decoder pour de vrai.
final _onePixelPng = Uint8List.fromList([
  137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, //
  0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, //
  120, 156, 99, 252, 207, 192, 240, 31, 0, 5, 5, 2, 0, 95, 200, 241, 210, 0, //
  0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
]);

Problem _problem({
  String id = 'p1',
  String title = 'Stock faux sur le câble 2,5 mm²',
  ProblemStatus status = ProblemStatus.open,
  ProblemPriority priority = ProblemPriority.normal,
  String? assignedToId,
  String? assignedToName,
  String? resolution,
  String reportedById = 'moi',
  bool hasPhoto = false,
}) => Problem(
  id: id,
  title: title,
  category: ProblemCategory.wrongStock,
  description: 'Le système annonce 40, il y en a 12 sur l’étagère.',
  priority: priority,
  status: status,
  productName: 'Câble 2,5 mm²',
  hasPhoto: hasPhoto,
  reportedById: reportedById,
  reportedByName: 'Nadia Kaci',
  assignedToId: assignedToId,
  assignedToName: assignedToName,
  resolution: resolution,
  createdAt: DateTime.utc(2026, 9, 24, 9),
);

AuthUser _magasinier() => authUser(
  id: 'moi',
  fullName: 'Nadia Kaci',
  roles: const ['MAGASINIER'],
  permissions: const ['product.read'],
);

AuthUser _admin() =>
    authUser(id: 'chef', fullName: 'Radhi', roles: const ['ADMIN']);

Future<_FakeProblemsApi> _pump(
  WidgetTester tester, {
  required List<Problem> items,
  AuthUser? user,

  /// Photo choisie par l'utilisateur, et membres a qui confier : injectes ici
  /// parce qu'ils viennent du telephone et du serveur, pas de l'ecran.
  Future<Uint8List?> Function()? pickPhoto,
  List<ConversationRecipient>? members,

  /// L.écran ouvre sur le filtre « Ouvert » : pour voir un signalement résolu,
  /// il faut cliquer sur son onglet, comme un utilisateur le ferait.
  ProblemStatus? show,
}) async {
  useScreenSize(tester, const Size(700, 1400));
  final api = _FakeProblemsApi(items);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        problemsApiProvider.overrideWithValue(api),
        currentUserIdProvider.overrideWithValue(user?.id ?? 'moi'),
        if (pickPhoto != null) pickPhotoProvider.overrideWithValue(pickPhoto),
        if (members != null)
          conversationRecipientsProvider.overrideWith((ref) async => members),
      ],
      child: MaterialApp(
        theme: AppTheme.mobile(dark: true),
        home: Scaffold(body: ProblemsScreen(user: user ?? _magasinier())),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (show != null) {
    await tester.tap(find.widgetWithText(FilterChip, show.label));
    await tester.pumpAndSettle();
  }
  return api;
}

/// Refermer la fiche avant de repartir : `pumpWidget` ne demonte pas la route
/// du dialogue, et son titre resterait trouvable deux fois.
Future<void> _closeSheet(WidgetTester tester) async {
  await tester.tapAt(const Offset(5, 5));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('aucun signalement : l’écran dit à quoi ça sert', (tester) async {
    await _pump(tester, items: const []);

    expect(find.text('Aucun signalement'), findsOneWidget);
    expect(find.textContaining('poste en panne'), findsOneWidget);
  });

  testWidgets('un signalement urgent se distingue', (tester) async {
    await _pump(tester, items: [_problem(priority: ProblemPriority.urgent)]);

    expect(find.text('URGENT'), findsOneWidget);
    expect(
      toneOf(_problem(priority: ProblemPriority.urgent)),
      StatusTone.error,
    );
  });

  testWidgets('personne n’est responsable : l’écran le DIT', (tester) async {
    await _pump(tester, items: [_problem()]);

    expect(find.textContaining('personne ne s’en occupe'), findsOneWidget);
  });

  testWidgets('« Je m’en occupe » n’est offert que sur un signalement OUVERT', (
    tester,
  ) async {
    final api = await _pump(tester, items: [_problem()]);

    await tester.tap(find.text('Stock faux sur le câble 2,5 mm²'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Je m’en occupe'));
    await tester.pumpAndSettle();

    expect(api.started, ['p1']);
  });

  /// Le serveur refuse qu'un tiers reprenne un signalement confié : l'écran ne
  /// doit donc pas le proposer.
  testWidgets('un signalement confié à un autre n’offre aucune action', (
    tester,
  ) async {
    await _pump(
      tester,
      items: [
        _problem(assignedToId: 'quelqu-un-dautre', assignedToName: 'Karim'),
      ],
    );

    await tester.tap(find.text('Stock faux sur le câble 2,5 mm²'));
    await tester.pumpAndSettle();

    expect(find.text('Je m’en occupe'), findsNothing);
    expect(find.text('Marquer résolu…'), findsNothing);
    // Mais on voit qui s'en occupe.
    expect(find.textContaining('suivi par Karim'), findsWidgets);
  });

  testWidgets('FERMER n’est proposé qu’à l’admin, et sur un RÉSOLU', (
    tester,
  ) async {
    // Magasinier sur un résolu : pas de fermeture.
    await _pump(
      tester,
      items: [_problem(status: ProblemStatus.resolved, resolution: "Ajusté.")],
      show: ProblemStatus.resolved,
    );
    await tester.tap(find.text("Stock faux sur le câble 2,5 mm²"));
    await tester.pumpAndSettle();
    expect(find.text("Fermer le signalement"), findsNothing);

    // Admin sur un OUVERT : pas de fermeture non plus (rien n'a été traité).
    await _pump(tester, items: [_problem()], user: _admin());
    await tester.tap(find.text('Stock faux sur le câble 2,5 mm²'));
    await tester.pumpAndSettle();
    expect(find.text('Fermer le signalement'), findsNothing);
  });

  testWidgets('l’admin ferme un signalement résolu', (tester) async {
    final api = await _pump(
      tester,
      items: [_problem(status: ProblemStatus.resolved, resolution: "Ajusté.")],
      user: _admin(),
      show: ProblemStatus.resolved,
    );

    await tester.tap(find.text('Stock faux sur le câble 2,5 mm²'));
    await tester.pumpAndSettle();
    // L'explication de la résolution est visible avant de fermer.
    expect(find.textContaining('Résolu : Ajusté.'), findsOneWidget);

    await tester.tap(find.text('Fermer le signalement'));
    await tester.pumpAndSettle();

    expect(api.closed, ['p1']);
  });

  testWidgets('résoudre EXIGE une explication : vide, rien n’est envoyé', (
    tester,
  ) async {
    final api = await _pump(tester, items: [_problem()]);

    await tester.tap(find.text('Stock faux sur le câble 2,5 mm²'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Marquer résolu…'));
    await tester.pumpAndSettle();

    // Champ laissé vide : le bouton ne doit rien envoyer.
    await tester.tap(find.text('Marquer résolu'));
    await tester.pumpAndSettle();
    expect(api.resolved, isEmpty);
  });

  testWidgets('résoudre envoie l’explication saisie', (tester) async {
    final api = await _pump(tester, items: [_problem()]);

    await tester.tap(find.text('Stock faux sur le câble 2,5 mm²'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Marquer résolu…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Inventaire fait, ajusté.');
    await tester.tap(find.text('Marquer résolu'));
    await tester.pumpAndSettle();

    expect(api.resolved, [('p1', 'Inventaire fait, ajusté.')]);
  });

  testWidgets('l’auteur joint une photo ; elle s’affiche ensuite', (
    tester,
  ) async {
    final api = await _pump(
      tester,
      items: [_problem()],
      pickPhoto: () async => _onePixelPng,
    );

    await tester.tap(find.text('Stock faux sur le câble 2,5 mm²'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Joindre une photo…'));
    await tester.pumpAndSettle();

    expect(api.photos, [('p1', _onePixelPng.length)]);
    await _closeSheet(tester);

    // Une fois jointe, la fiche la montre.
    await _pump(
      tester,
      items: [_problem(hasPhoto: true)],
      pickPhoto: () async => _onePixelPng,
    );
    await tester.tap(find.text('Stock faux sur le câble 2,5 mm²'));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
  });

  /// Le serveur n'accepte la photo que de l'auteur ou de l'admin : l'écran ne
  /// doit pas l'offrir à un tiers.
  testWidgets('un tiers ne peut pas joindre de photo, l’admin oui', (
    tester,
  ) async {
    await _pump(tester, items: [_problem(reportedById: 'quelqu-un-dautre')]);
    await tester.tap(find.text('Stock faux sur le câble 2,5 mm²'));
    await tester.pumpAndSettle();
    expect(find.text('Joindre une photo…'), findsNothing);
    await _closeSheet(tester);

    await _pump(
      tester,
      items: [_problem(reportedById: 'quelqu-un-dautre')],
      user: _admin(),
    );
    await tester.tap(find.text('Stock faux sur le câble 2,5 mm²'));
    await tester.pumpAndSettle();
    expect(find.text('Joindre une photo…'), findsOneWidget);
  });

  testWidgets('seul l’admin confie un signalement à un membre', (tester) async {
    const recipients = [
      ConversationRecipient(id: 'karim', fullName: 'Karim Belkacem'),
    ];

    // Magasinier : l'action n'existe pas.
    await _pump(tester, items: [_problem()], members: recipients);
    await tester.tap(find.text('Stock faux sur le câble 2,5 mm²'));
    await tester.pumpAndSettle();
    expect(find.text('Confier à un membre…'), findsNothing);
    await _closeSheet(tester);

    final api = await _pump(
      tester,
      items: [_problem()],
      user: _admin(),
      members: recipients,
    );
    await tester.tap(find.text('Stock faux sur le câble 2,5 mm²'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confier à un membre…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Karim Belkacem'));
    await tester.pumpAndSettle();

    expect(api.assigned, [('p1', 'karim')]);
  });

  group('formulaire de signalement', () {
    Future<_FakeProblemsApi> pumpForm(WidgetTester tester) async {
      useScreenSize(tester, const Size(700, 1400));
      final api = _FakeProblemsApi([]);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            problemsApiProvider.overrideWithValue(api),
            currentUserIdProvider.overrideWithValue('moi'),
            activeProductsProvider.overrideWith(
              (ref) => Stream.value(const []),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.mobile(dark: true),
            home: const Scaffold(body: ProblemForm()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return api;
    }

    testWidgets('titre et description sont EXIGÉS avant tout envoi', (
      tester,
    ) async {
      final api = await pumpForm(tester);

      await tester.tap(find.text('Envoyer'));
      await tester.pumpAndSettle();

      expect(api.created, isEmpty);
      expect(find.text('Titre trop court'), findsOneWidget);
      expect(find.text('Décrivez ce qui a été constaté'), findsOneWidget);
    });

    testWidgets('un signalement complet part avec la catégorie CHOISIE', (
      tester,
    ) async {
      final api = await pumpForm(tester);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Titre'),
        'Poste 2 en panne',
      );
      // La catégorie est vraiment changée : sinon le test ne prouve que la
      // valeur par défaut, et un menu câblé à l'envers passerait.
      await tester.tap(find.text(ProblemCategory.wrongStock.label));
      await tester.pumpAndSettle();
      await tester.tap(find.text(ProblemCategory.hardware.label).last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Ce que vous avez constaté'),
        'L’écran ne s’allume plus depuis ce matin.',
      );
      await tester.tap(find.text('Envoyer'));
      await tester.pumpAndSettle();

      expect(api.created, [
        {
          'title': 'Poste 2 en panne',
          'category': 'PROBLEME_MATERIEL',
          'description': 'L’écran ne s’allume plus depuis ce matin.',
          'priority': 'NORMALE',
          'productId': null,
        },
      ]);
    });
  });
}
