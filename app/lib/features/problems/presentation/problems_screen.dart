import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'dart:typed_data';

import '../../../core/dates.dart';
import '../../../core/error/api_exception.dart';
import '../../../core/photos.dart';
import '../../../ui/breakpoints.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/screen_state.dart';
import '../../auth/data/auth_models.dart';
import '../../messaging/application/conversations_controller.dart';
import '../application/problems_controller.dart';
import '../data/problem_models.dart';
import '../data/problems_api.dart';
import 'problem_form.dart';

/// Droits du signalement, MIROIRS des guards serveur : signaler est ouvert aux
/// trois rôles, décider (attribuer, fermer) est réservé à l'admin.
class ProblemRights {
  ProblemRights(this.user) : isAdmin = user.hasRole('ADMIN');

  final AuthUser user;
  final bool isAdmin;

  /// Travailler dessus : le responsable désigné, l'admin, ou n'importe qui
  /// tant que personne n'est désigné (le premier qui s'en saisit).
  bool canWork(Problem problem) =>
      !problem.isClosed &&
      (isAdmin ||
          problem.assignedToId == null ||
          problem.assignedToId == user.id);

  /// Joindre une photo : l'auteur du signalement, ou l'admin. Même règle que le
  /// serveur — l'auteur est celui qui a la chose sous les yeux.
  bool canAttachPhoto(Problem problem) =>
      !problem.isClosed && (isAdmin || problem.reportedById == user.id);
}

StatusTone toneOf(Problem problem) => switch (problem.status) {
  ProblemStatus.open =>
    problem.priority == ProblemPriority.urgent ||
            problem.priority == ProblemPriority.high
        ? StatusTone.error
        : StatusTone.warn,
  ProblemStatus.inProgress => StatusTone.info,
  ProblemStatus.resolved => StatusTone.ok,
  ProblemStatus.closed => StatusTone.neutral,
  ProblemStatus.unknown => StatusTone.neutral,
};

/// Signalements (spec §26) : ce que l'équipe constate sur le terrain et que
/// personne ne peut corriger seul.
///
/// L'écran ne corrige RIEN : un stock faux se répare par un inventaire ou un
/// ajustement tracé. Ici on fait savoir, on prend en charge, on clôt en disant
/// ce qui a été fait.
class ProblemsScreen extends ConsumerStatefulWidget {
  const ProblemsScreen({super.key, required this.user});

  final AuthUser user;

  @override
  ConsumerState<ProblemsScreen> createState() => _ProblemsScreenState();
}

class _ProblemsScreenState extends ConsumerState<ProblemsScreen> {
  ProblemStatus? _status = ProblemStatus.open;
  bool _mine = false;

  ProblemFilter get _filter => (status: _status, mine: _mine);

  @override
  Widget build(BuildContext context) {
    final rights = ProblemRights(widget.user);
    final margin = isDesktopWidth(MediaQuery.sizeOf(context).width)
        ? 24.0
        : 16.0;
    final problems = ref.watch(problemsProvider(_filter));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(margin, 14, margin, 10),
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final status in [
                        ProblemStatus.open,
                        ProblemStatus.inProgress,
                        ProblemStatus.resolved,
                        ProblemStatus.closed,
                      ])
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: FilterChip(
                            label: Text(status.label),
                            selected: _status == status,
                            onSelected: (on) =>
                                setState(() => _status = on ? status : null),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: FilterChip(
                          label: const Text('Les miens'),
                          selected: _mine,
                          onSelected: (on) => setState(() => _mine = on),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: () => openProblemForm(context),
                icon: const Icon(LucideIcons.plus, size: 17),
                label: const Text('Signaler'),
              ),
            ],
          ),
        ),
        Expanded(
          child: problems.when(
            loading: () => const AmpereSkeletonList(rows: 5),
            error: (error, _) => ScreenStateView(
              status: error is ApiException && error.isOffline
                  ? ScreenStatus.offline
                  : ScreenStatus.error,
              message: error is ApiException
                  ? error.userMessage
                  : 'Les signalements n’ont pas pu être chargés.',
              onRetry: () => ref.invalidate(problemsProvider(_filter)),
            ),
            data: (page) => page.data.isEmpty
                ? ScreenStateView(
                    status: ScreenStatus.empty,
                    title: 'Aucun signalement',
                    message:
                        'Stock faux, produit abîmé, poste en panne : ce qui '
                        'doit être su et que personne ne peut corriger seul.',
                    action: FilledButton.icon(
                      onPressed: () => openProblemForm(context),
                      icon: const Icon(LucideIcons.plus, size: 17),
                      label: const Text('Signaler'),
                    ),
                  )
                : ListView(
                    padding: EdgeInsets.fromLTRB(margin, 0, margin, 24),
                    children: [
                      for (final problem in page.data)
                        _ProblemTile(
                          problem: problem,
                          rights: rights,
                          filter: _filter,
                        ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

class _ProblemTile extends ConsumerWidget {
  const _ProblemTile({
    required this.problem,
    required this.rights,
    required this.filter,
  });

  final Problem problem;
  final ProblemRights rights;
  final ProblemFilter filter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);

    return Card(
      child: ListTile(
        minTileHeight: AmpereGeometry.listRowMin,
        title: Text(problem.title, style: AmpereType.rowTitle),
        subtitle: Text(
          [
            problem.category.label,
            ?problem.productName,
            problem.assignedToName == null
                ? 'personne ne s’en occupe'
                : 'suivi par ${problem.assignedToName}',
            formatDateTime(problem.createdAt),
          ].join(' · '),
          style: AmpereType.meta.copyWith(color: colors.ink3),
        ),
        trailing: AmpereBadge(
          label: problem.priority == ProblemPriority.urgent
              ? 'URGENT'
              : problem.status.label,
          tone: toneOf(problem),
        ),
        onTap: () => _openActions(context, ref),
      ),
    );
  }

  /// Actions proposées = celles que le serveur accepterait à cet instant. Un
  /// bouton qui refuse est un piège ; le serveur revérifie de toute façon.
  Future<void> _openActions(BuildContext context, WidgetRef ref) async {
    final action = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(problem.title),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Text(problem.description),
          ),
          if (problem.hasPhoto)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: _ProblemPhoto(problemId: problem.id),
            ),
          if (problem.resolution case final resolution?)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: AmpereInlineAlert(
                tone: StatusTone.ok,
                message: 'Résolu : $resolution',
              ),
            ),
          if (rights.canWork(problem) && problem.status == ProblemStatus.open)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop('start'),
              child: const Text('Je m’en occupe'),
            ),
          if (rights.canWork(problem))
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop('resolve'),
              child: const Text('Marquer résolu…'),
            ),
          if (rights.isAdmin && problem.status == ProblemStatus.resolved)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop('close'),
              child: const Text('Fermer le signalement'),
            ),
          if (rights.isAdmin && !problem.isClosed)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop('assign'),
              child: const Text('Confier à un membre…'),
            ),
          if (rights.canAttachPhoto(problem))
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop('photo'),
              child: Text(
                problem.hasPhoto ? 'Remplacer la photo…' : 'Joindre une photo…',
              ),
            ),
        ],
      ),
    );
    if (action == null || !context.mounted) return;

    if (action == 'photo') {
      final bytes = await ref.read(pickPhotoProvider)();
      // `null` = annulé, ou fichier illisible : rien à envoyer, le serveur le
      // refuserait de toute façon.
      if (bytes == null || !context.mounted) return;
      await _run(context, ref, () async {
        final updated = await ref
            .read(problemsApiProvider)
            .attachPhoto(problem.id, bytes);
        ref.invalidate(problemPhotoProvider(problem.id));
        return updated;
      });
      return;
    }

    if (action == 'assign') {
      final memberId = await _askMember(context, ref);
      if (memberId == null || !context.mounted) return;
      await _run(
        context,
        ref,
        () => ref.read(problemsApiProvider).assign(problem.id, memberId),
      );
      return;
    }

    if (action == 'resolve') {
      final resolution = await _askResolution(context);
      if (resolution == null || !context.mounted) return;
      await _run(
        context,
        ref,
        () => ref.read(problemsApiProvider).resolve(problem.id, resolution),
      );
      return;
    }
    await _run(context, ref, () {
      final api = ref.read(problemsApiProvider);
      return action == 'start' ? api.start(problem.id) : api.close(problem.id);
    });
  }

  /// À qui confier. La liste des membres vient de la route dédiée (id + nom) —
  /// celle des comptes complets est réservée à l'admin et porte bien plus que
  /// ce qu'il faut ici.
  Future<String?> _askMember(BuildContext context, WidgetRef ref) async {
    final members = await ref.read(conversationRecipientsProvider.future);
    if (!context.mounted || members.isEmpty) return null;
    return showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Confier à'),
        children: [
          for (final member in members)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(member.id),
              child: Text(member.fullName),
            ),
        ],
      ),
    );
  }

  /// L'explication est OBLIGATOIRE (spec §26) : on la demande ici, le serveur
  /// la réexige.
  Future<String?> _askResolution(BuildContext context) async {
    final resolution = await showDialog<String>(
      context: context,
      builder: (context) => const _ResolutionDialog(),
    );
    return (resolution ?? '').isEmpty ? null : resolution;
  }

  Future<void> _run(
    BuildContext context,
    WidgetRef ref,
    Future<Problem> Function() action,
  ) async {
    try {
      await action();
      ref.invalidate(problemsProvider(filter));
    } on ApiException catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(error.userMessage)));
    }
  }
}

/// Le champ de saisie appartient au DIALOGUE, qui le libère lui-même.
///
/// Détruire le contrôleur juste après `showDialog` le libérait pendant
/// l'animation de fermeture — le champ était encore reconstruit, et levait
/// « A TextEditingController was used after being disposed » (trouvé par les
/// tests d'écran ; ça se serait vu à l'usage).
class _ResolutionDialog extends StatefulWidget {
  const _ResolutionDialog();

  @override
  State<_ResolutionDialog> createState() => _ResolutionDialogState();
}

class _ResolutionDialogState extends State<_ResolutionDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Qu’avez-vous fait ?'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        minLines: 2,
        maxLines: 4,
        maxLength: 2000,
        decoration: const InputDecoration(
          hintText: 'Inventaire tournant fait, écart ajusté.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('Marquer résolu'),
        ),
      ],
    );
  }
}

/// Photo du signalement, chargée quand la fiche s'ouvre. Une photo qui ne
/// charge pas n'efface pas le texte du signalement : on montre juste un mot.
class _ProblemPhoto extends ConsumerWidget {
  const _ProblemPhoto({required this.problemId});

  final String problemId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);
    // Taille FIXE, jamais `double.infinity` : la fiche est un dialogue, dont la
    // largeur se calcule depuis celle de ses enfants — une largeur infinie la
    // fait planter au calcul de mise en page (vu par le test d'écran).
    return SizedBox(
      width: 240,
      height: 160,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AmpereGeometry.iconChipRadius),
        child: ref
            .watch(problemPhotoProvider(problemId))
            .when(
              loading: () => ColoredBox(color: colors.surface2),
              error: (_, _) => ColoredBox(
                color: colors.surface2,
                child: Center(
                  child: Text(
                    'Photo indisponible',
                    style: AmpereType.meta.copyWith(color: colors.ink3),
                  ),
                ),
              ),
              data: (Uint8List bytes) => Image.memory(bytes, fit: BoxFit.cover),
            ),
      ),
    );
  }
}
