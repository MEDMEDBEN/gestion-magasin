import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/dates.dart';
import 'package:gestion_magasin/core/error/api_exception.dart';
import 'package:gestion_magasin/data/models/page_meta.dart';
import 'package:gestion_magasin/features/auth/data/auth_models.dart';
import 'package:gestion_magasin/features/planning/application/planning_controller.dart';
import 'package:gestion_magasin/features/planning/data/planning_api.dart';
import 'package:gestion_magasin/features/planning/data/planning_models.dart';
import 'package:gestion_magasin/features/planning/presentation/planning_screen.dart';
import 'package:gestion_magasin/features/users/data/users_api.dart';
import 'package:gestion_magasin/ui/navigation.dart';
import 'package:gestion_magasin/ui/theme/app_theme.dart';

import 'support/fakes.dart';

PlanningTask _task({
  String id = 't1',
  String title = 'Compter les câbles',
  PlanningTaskStatus status = PlanningTaskStatus.todo,
  bool isLate = false,
  String assignedToId = 'v',
  String? result,
  String scheduledFor = '2026-09-21',
  String dueDate = '2026-09-23',
}) => PlanningTask(
  id: id,
  title: title,
  type: PlanningTaskType.count,
  status: status,
  isLate: isLate,
  assignedToId: assignedToId,
  createdById: 'a',
  zone: 'Zone A',
  scheduledFor: scheduledFor,
  dueDate: dueDate,
  result: result,
  updatedAt: DateTime.utc(2026, 9, 21),
);

class _FakePlanningApi extends PlanningApi {
  _FakePlanningApi(this.tasks, {this.failure, this.total, this.writeFailure})
    : super(Dio());

  final List<PlanningTask> tasks;
  final ApiException? failure;
  final ApiException? writeFailure;
  final int? total;
  final List<({String? assignedToId, PlanningView view})> listed = [];
  Map<String, Object?>? created;
  (String, Map<String, Object?>)? updated;
  String? startedId;
  (String, String, String?)? completed;
  String? removedId;

  @override
  Future<PlanningTaskPage> list({
    String? assignedToId,
    PlanningView view = PlanningView.open,
    int limit = 200,
  }) async {
    if (failure != null) throw failure!;
    listed.add((assignedToId: assignedToId, view: view));
    return PlanningTaskPage(
      data: tasks,
      meta: PageMeta(page: 1, limit: limit, total: total ?? tasks.length),
    );
  }

  @override
  Future<PlanningTask> update(String id, Map<String, Object?> changes) async {
    updated = (id, changes);
    return _task(assignedToId: changes['assignedToId'] as String? ?? 'v');
  }

  @override
  Future<PlanningTask> create(Map<String, Object?> fields) async {
    created = fields;
    return _task(title: fields['title']! as String);
  }

  @override
  Future<PlanningTask> start(String id) async {
    if (writeFailure != null) throw writeFailure!;
    startedId = id;
    return _task(status: PlanningTaskStatus.inProgress);
  }

  @override
  Future<PlanningTask> complete(
    String id,
    String result,
    String? comment,
  ) async {
    completed = (id, result, comment);
    return _task(status: PlanningTaskStatus.done, result: result);
  }

  @override
  Future<void> remove(String id) async => removedId = id;
}

AuthUser _vendeur() => authUser(
  id: 'v',
  roles: const ['VENDEUR'],
  permissions: const ['planning.task.read'],
);

AuthUser _admin() => authUser(
  id: 'a',
  roles: const ['ADMIN'],
  permissions: const ['planning.task.read', 'planning.manage', 'user.manage'],
);

Future<_FakePlanningApi> _pump(
  WidgetTester tester,
  AuthUser user, {
  List<PlanningTask> tasks = const [],
  ApiException? failure,
  ApiException? writeFailure,
  int? total,
}) async {
  useScreenSize(tester, const Size(500, 1400));
  final api = _FakePlanningApi(
    tasks,
    failure: failure,
    writeFailure: writeFailure,
    total: total,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        planningApiProvider.overrideWithValue(api),
        usersApiProvider.overrideWithValue(
          FakeUsersApi(
            users: [
              managedUser(id: 'v', fullName: 'Nadia Kaci'),
              managedUser(
                id: 'm',
                fullName: 'Karim Ould',
                roles: const ['MAGASINIER'],
              ),
              managedUser(id: 'x', fullName: 'Ancien', isActive: false),
            ],
          ),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.mobile(dark: true),
        home: Scaffold(body: PlanningScreen(user: user)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

void main() {
  test('un jour civil s’affiche sans glisser de fuseau', () {
    expect(formatIsoDay('2026-09-23'), '23/09/2026');
    expect(isoDay(DateTime(2026, 1, 5)), '2026-01-05');
  });

  testWidgets('le membre voit SES tâches ; le retard prime sur le statut', (
    tester,
  ) async {
    await _pump(
      tester,
      _vendeur(),
      tasks: [
        _task(title: 'Réception oubliée', isLate: true),
        _task(id: 't2', title: 'Saisie', status: PlanningTaskStatus.inProgress),
      ],
    );
    // Badge de la carte (« En retard » est AUSSI le nom d'une vue en haut).
    Finder badge(String label) =>
        find.descendant(of: find.byType(Card), matching: find.text(label));
    expect(badge('En retard'), findsOneWidget);
    expect(badge('En cours'), findsOneWidget);
    // Jour civil formaté, jamais un DateTime décalé.
    expect(find.textContaining('échéance 23/09/2026'), findsNWidgets(2));
    // Le membre ne planifie pas, et ne filtre pas par collègue.
    expect(find.text('Nouvelle tâche'), findsNothing);
    expect(find.text('Toute l’équipe'), findsNothing);
  });

  testWidgets('le membre commence puis termine avec son résultat', (
    tester,
  ) async {
    final api = await _pump(tester, _vendeur(), tasks: [_task()]);

    await tester.tap(find.text('Compter les câbles'));
    await tester.pumpAndSettle();
    expect(find.text('Modifier / réassigner'), findsNothing);
    expect(find.text('Supprimer la tâche'), findsNothing);
    await tester.tap(find.text('Commencer'));
    await tester.pumpAndSettle();
    expect(api.startedId, 't1');

    await tester.tap(find.text('Compter les câbles'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Terminer et donner le résultat'));
    await tester.pumpAndSettle();
    // Sans résultat : refusé AVANT l'envoi (miroir du serveur).
    await tester.tap(find.widgetWithText(FilledButton, 'Terminer'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Indiquez le résultat'), findsOneWidget);
    expect(api.completed, isNull);

    await tester.enterText(
      find.widgetWithText(TextField, 'Résultat'),
      '120 m comptés',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Terminer'));
    await tester.pumpAndSettle();
    expect(api.completed, ('t1', '120 m comptés', null));
  });

  testWidgets('l’admin planifie : intitulé, membre ACTIF et jours partent', (
    tester,
  ) async {
    final api = await _pump(tester, _admin());

    await tester.tap(find.text('Nouvelle tâche'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Compter les câbles de la zone A'),
      'Réviser les prix des disjoncteurs',
    );
    await tester.tap(
      find.widgetWithText(DropdownButtonFormField<String>, 'Choisir un membre'),
    );
    await tester.pumpAndSettle();
    // Un compte désactivé n'est pas proposé.
    expect(find.text('Ancien'), findsNothing);
    await tester.tap(find.text('Karim Ould').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enregistrer la tâche'));
    await tester.pumpAndSettle();

    expect(
      api.created,
      containsPair('title', 'Réviser les prix des disjoncteurs'),
    );
    expect(api.created, containsPair('assignedToId', 'm'));
    expect(api.created, containsPair('type', 'COMPTAGE'));
    // Jours civils AAAA-MM-JJ, jamais un instant.
    expect(
      api.created!['scheduledFor'],
      matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')),
    );
    expect(api.created!['dueDate'], matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
    expect(api.created!['id'], isA<String>());
  });

  testWidgets('tâche sans membre : rien ne part', (tester) async {
    final api = await _pump(tester, _admin());
    await tester.tap(find.text('Nouvelle tâche'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Compter les câbles de la zone A'),
      'Sans personne',
    );
    await tester.tap(find.text('Enregistrer la tâche'));
    await tester.pumpAndSettle();
    expect(find.text('Choisissez un membre'), findsOneWidget);
    expect(api.created, isNull);
  });

  testWidgets(
    'l’admin supprime une tâche À FAIRE, jamais une tâche commencée',
    (tester) async {
      final api = await _pump(
        tester,
        _admin(),
        tasks: [
          _task(),
          _task(
            id: 't2',
            title: 'Déjà lancée',
            status: PlanningTaskStatus.inProgress,
          ),
        ],
      );
      await tester.tap(find.text('Déjà lancée'));
      await tester.pumpAndSettle();
      expect(find.text('Supprimer la tâche'), findsNothing);
      expect(find.text('Modifier / réassigner'), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Compter les câbles'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Supprimer la tâche'));
      await tester.pumpAndSettle();
      expect(find.textContaining('reste tracé dans l’audit'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Supprimer'));
      await tester.pumpAndSettle();
      expect(api.removedId, 't1');
    },
  );

  testWidgets('filtres de l’admin : un membre, puis « en retard »', (
    tester,
  ) async {
    final api = await _pump(tester, _admin(), tasks: [_task()]);
    // Le nom du membre remplace son identifiant dans la liste.
    expect(find.textContaining('Nadia Kaci'), findsOneWidget);

    await tester.tap(find.byType(DropdownButtonFormField<String?>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Karim Ould').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('En retard'));
    await tester.pumpAndSettle();

    expect(api.listed.last, (assignedToId: 'm', view: PlanningView.late));
  });

  testWidgets('une tâche terminée montre son résultat dans le détail', (
    tester,
  ) async {
    await _pump(
      tester,
      _vendeur(),
      tasks: [
        _task(
          status: PlanningTaskStatus.done,
          result: '120 m comptés, conforme',
        ),
      ],
    );
    expect(find.text('Terminée'), findsOneWidget);
    await tester.tap(find.text('Compter les câbles'));
    await tester.pumpAndSettle();
    // Close : plus rien à faire dessus.
    expect(find.text('Commencer'), findsNothing);
    expect(find.text('Terminer et donner le résultat'), findsNothing);
    await tester.tap(find.text('Voir le détail'));
    await tester.pumpAndSettle();
    expect(find.text('Résultat : 120 m comptés, conforme'), findsOneWidget);
  });

  testWidgets('aucune tâche : le message dépend du rôle', (tester) async {
    await _pump(tester, _vendeur());
    expect(find.text('Aucune tâche à faire'), findsOneWidget);
    expect(find.textContaining('ne vous est confiée'), findsOneWidget);
  });

  testWidgets('serveur injoignable : l’écran le dit', (tester) async {
    await _pump(
      tester,
      _vendeur(),
      failure: const ApiException(
        statusCode: 503,
        message: 'Serveur injoignable. Réessayez.',
      ),
    );
    expect(find.textContaining('Serveur injoignable'), findsOneWidget);
  });

  testWidgets('réassigner une tâche EN RETARD n’envoie QUE le membre changé', (
    tester,
  ) async {
    // Revue du 2026-09-21, bloquant B1 : l'app renvoyait l'échéance passée
    // inchangée, et le serveur refusait — la tâche ne se réassignait plus.
    final api = await _pump(
      tester,
      _admin(),
      tasks: [
        _task(isLate: true, scheduledFor: '2026-09-10', dueDate: '2026-09-12'),
      ],
    );
    await tester.tap(find.text('Compter les câbles'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Modifier / réassigner'));
    await tester.pumpAndSettle();

    // Le sélecteur s'OUVRE sur une échéance passée (il part d'aujourd'hui) au
    // lieu de lever « initialDate must be on or after firstDate ».
    await tester.tap(find.widgetWithText(OutlinedButton, '12/09/2026'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(DatePickerDialog), findsOneWidget);
    Navigator.of(tester.element(find.byType(DatePickerDialog))).pop();
    await tester.pumpAndSettle();

    await tester.tap(
      find.widgetWithText(DropdownButtonFormField<String>, 'Nadia Kaci'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Karim Ould').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enregistrer la tâche'));
    await tester.pumpAndSettle();

    expect(api.updated!.$1, 't1');
    expect(api.updated!.$2, {'assignedToId': 'm'});
  });

  testWidgets('les trois vues : à faire, en retard, terminées', (tester) async {
    final api = await _pump(tester, _vendeur(), tasks: [_task()]);
    expect(api.listed.last.view, PlanningView.open);
    await tester.tap(find.text('Terminées'));
    await tester.pumpAndSettle();
    expect(api.listed.last.view, PlanningView.done);
    await tester.tap(find.text('En retard'));
    await tester.pumpAndSettle();
    expect(api.listed.last.view, PlanningView.late);
  });

  testWidgets('page tronquée : l’écran le DIT au lieu de perdre des tâches', (
    tester,
  ) async {
    await _pump(tester, _admin(), tasks: [_task()], total: 250);
    expect(find.textContaining('1 tâches affichées sur 250'), findsOneWidget);
  });

  testWidgets(
    'geste refusé (un collègue est passé avant) : message et relecture',
    (tester) async {
      final api = await _pump(
        tester,
        _vendeur(),
        tasks: [_task()],
        writeFailure: const ApiException(
          statusCode: 409,
          code: 'INVALID_STATE_TRANSITION',
          message: 'Tâche déjà terminée : elle ne se modifie plus',
        ),
      );
      final before = api.listed.length;
      await tester.tap(find.text('Compter les câbles'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Commencer'));
      await tester.pumpAndSettle();
      expect(find.textContaining('ne se modifie plus'), findsOneWidget);
      // La liste est relue pour montrer la réalité.
      expect(api.listed.length, greaterThan(before));
    },
  );

  test('seuls les champs RÉELLEMENT modifiés partent au serveur', () {
    final existing = _task(dueDate: '2026-09-12');
    expect(
      planningChanges(existing, (
        title: existing.title,
        type: existing.type,
        assignedToId: 'm',
        scheduledFor: existing.scheduledFor,
        dueDate: existing.dueDate,
        zone: existing.zone,
        description: existing.description,
      )),
      {'assignedToId': 'm'},
    );
  });

  test('menu : « Tâches » pour les trois rôles', () {
    for (final roles in [
      ['ADMIN'],
      ['VENDEUR'],
      ['MAGASINIER'],
    ]) {
      expect(
        destinationsFor(
          authUser(roles: roles, permissions: const ['planning.task.read']),
        ).map((d) => d.label),
        contains('Tâches'),
      );
    }
  });
}
