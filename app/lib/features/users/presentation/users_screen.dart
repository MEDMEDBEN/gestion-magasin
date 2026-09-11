import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/providers.dart';
import '../../../ui/breakpoints.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/screen_state.dart';
import '../application/users_controller.dart';
import '../data/user_models.dart';
import 'desktop/users_table.dart';
import 'mobile/users_list.dart';
import 'user_form.dart';

/// Gestion des comptes — **ADMIN uniquement** (`docs/permissions.md`
/// §Administration). Le backend refuse de toute façon (accès relu en base) :
/// l'UI ne fait que masquer ce qui serait rejeté.
///
/// Hébergé dans une coquille : pas d'`AppBar` propre, la coquille porte le
/// titre (revue C10). Tableau dense sur desktop, lignes tactiles sur mobile
/// (AMPÈRE §9 — aucun tableau sur mobile). UNE seule action principale :
/// « Nouvel utilisateur » (§6).
class UsersScreen extends ConsumerStatefulWidget {
  const UsersScreen({super.key});

  @override
  ConsumerState<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends ConsumerState<UsersScreen> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _openCreate() async {
    final created = await openUserForm(context);
    if (created != null) {
      _showSnack(
        'Compte créé pour ${created.fullName}. '
        'Il devra changer son mot de passe à la première connexion.',
      );
    }
  }

  Future<void> _openEdit(ManagedUser user) async {
    final updated = await openUserForm(
      context,
      existing: user,
      currentUserId: ref.read(currentUserIdProvider),
    );
    if (updated != null && updated != user) {
      _showSnack('${updated.fullName} mis à jour.');
    }
  }

  Future<void> _loadMore() async {
    try {
      await ref.read(usersControllerProvider.notifier).loadMore();
    } on ApiException catch (error) {
      _showSnack(error.userMessage);
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          // Toast §6 : « Fermer », jamais « Annuler » sur une action écrite.
          action: SnackBarAction(label: 'Fermer', onPressed: () {}),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final isDesktop = isDesktopWidth(MediaQuery.sizeOf(context).width);
    final margin = isDesktop
        ? AmpereGeometry.screenMarginDesktop
        : AmpereGeometry.screenMarginMobile;
    final usersAsync = ref.watch(usersControllerProvider);
    final searchTerm = ref.watch(userSearchProvider);
    final currentUserId = ref.watch(currentUserIdProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(margin, 14, margin, 12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _search,
                  style: (isDesktop ? AmpereType.bodyDesktop : AmpereType.input)
                      .copyWith(color: colors.ink),
                  decoration: InputDecoration(
                    hintText: 'Rechercher un nom, un email, un téléphone',
                    prefixIcon: const Icon(LucideIcons.search, size: 17),
                    suffixIcon: searchTerm.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Effacer',
                            icon: const Icon(LucideIcons.x, size: 17),
                            onPressed: () {
                              _search.clear();
                              ref.read(userSearchProvider.notifier).clear();
                            },
                          ),
                  ),
                  onSubmitted: (value) =>
                      ref.read(userSearchProvider.notifier).set(value),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: _openCreate,
                icon: const Icon(LucideIcons.plus, size: 17),
                label: Text(isDesktop ? 'Nouvel utilisateur' : 'Nouveau'),
              ),
            ],
          ),
        ),
        Expanded(
          child: usersAsync.when(
            loading: () => const AmpereSkeletonList(rows: 6),
            error: (error, _) => ScreenStateView(
              status: error is ApiException && error.isOffline
                  ? ScreenStatus.offline
                  : ScreenStatus.error,
              message: error is ApiException ? error.userMessage : null,
              onRetry: () =>
                  ref.read(usersControllerProvider.notifier).refresh(),
            ),
            data: (state) {
              if (state.items.isEmpty) {
                // « Vide » et « aucun résultat » sont deux états distincts (§8).
                // L'action principale est déjà dans l'en-tête : l'état vide
                // n'en ajoute pas une seconde (un seul primaire par écran).
                return searchTerm.isEmpty
                    ? const ScreenStateView(
                        status: ScreenStatus.empty,
                        title: 'Aucun utilisateur',
                        message: 'Créez le premier compte de votre équipe.',
                      )
                    : ScreenStateView(
                        status: ScreenStatus.noResults,
                        searchTerm: searchTerm,
                      );
              }
              return isDesktop
                  ? UsersTable(
                      state: state,
                      currentUserId: currentUserId,
                      onLoadMore: _loadMore,
                      onEdit: _openEdit,
                      onMessage: _showSnack,
                    )
                  : UsersList(
                      state: state,
                      currentUserId: currentUserId,
                      onRefresh: () =>
                          ref.read(usersControllerProvider.notifier).refresh(),
                      onLoadMore: _loadMore,
                      onEdit: _openEdit,
                      onMessage: _showSnack,
                    );
            },
          ),
        ),
      ],
    );
  }
}
