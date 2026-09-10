import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/error/api_exception.dart';
import '../../../data/models/user_models.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/screen_state.dart';
import '../application/users_controller.dart';

/// Feuille modale basse (AMPÈRE §7) — création ou édition d'un compte.
/// Renvoie l'utilisateur enregistré, ou `null` si l'admin a renoncé.
Future<ManagedUser?> showUserFormSheet(
  BuildContext context,
  WidgetRef ref, {
  ManagedUser? existing,
}) {
  return showModalBottomSheet<ManagedUser>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => _UserFormSheet(existing: existing),
  );
}

class _UserFormSheet extends ConsumerStatefulWidget {
  const _UserFormSheet({this.existing});

  final ManagedUser? existing;

  @override
  ConsumerState<_UserFormSheet> createState() => _UserFormSheetState();
}

class _UserFormSheetState extends ConsumerState<_UserFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _fullName;
  late final TextEditingController _email;
  late final TextEditingController _phone;
  final _password = TextEditingController();

  late AppRole _role;
  bool _saving = false;
  String? _error;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _fullName = TextEditingController(text: existing?.fullName ?? '');
    _email = TextEditingController(text: existing?.email ?? '');
    _phone = TextEditingController(text: existing?.phone ?? '');
    // Les rôles sont FIGÉS à 3 (CLAUDE.md) : un compte en porte un principal.
    _role = existing == null
        ? AppRole.vendeur
        : AppRoleCode.fromCode(existing.roles.first) ?? AppRole.vendeur;
  }

  @override
  void dispose() {
    _fullName.dispose();
    _email.dispose();
    _phone.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    final email = _email.text.trim();
    final phone = _phone.text.trim();
    if (email.isEmpty && phone.isEmpty) {
      setState(() => _error = 'Fournir au moins un email ou un téléphone');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    final controller = ref.read(usersControllerProvider.notifier);
    try {
      final saved = _isEdit
          ? await controller.updateUser(
              widget.existing!.id,
              fullName: _fullName.text.trim(),
              email: email.isEmpty ? null : email,
              phone: phone.isEmpty ? null : phone,
              roles: [_role.code],
            )
          : await controller.create(
              fullName: _fullName.text.trim(),
              email: email.isEmpty ? null : email,
              phone: phone.isEmpty ? null : phone,
              temporaryPassword: _password.text,
              roles: [_role.code],
            );
      if (mounted) Navigator.of(context).pop(saved);
    } on ApiException catch (error) {
      // La saisie n'est JAMAIS perdue sur erreur (§8).
      if (mounted) {
        setState(() {
          _saving = false;
          _error = error.userMessage;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Poignée 44×4 (§7).
              Center(
                child: Container(
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colors.line,
                    borderRadius: BorderRadius.circular(AmpereGeometry.pillRadius),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                _isEdit ? 'Modifier le compte' : 'Nouvel utilisateur',
                style: AmpereType.sectionTitle.copyWith(color: colors.ink),
              ),
              const SizedBox(height: 18),

              const AmpereFieldLabel('Nom complet'),
              TextFormField(
                controller: _fullName,
                enabled: !_saving,
                autofocus: !_isEdit,
                style: AmpereType.input.copyWith(color: colors.ink),
                decoration: const InputDecoration(
                  prefixIcon: Icon(LucideIcons.user, size: 17),
                ),
                validator: (v) => (v == null || v.trim().length < 2)
                    ? 'Au moins 2 caractères'
                    : null,
              ),
              const SizedBox(height: 14),

              const AmpereFieldLabel('Email'),
              TextFormField(
                controller: _email,
                enabled: !_saving,
                keyboardType: TextInputType.emailAddress,
                style: AmpereType.input.copyWith(color: colors.ink),
                decoration: const InputDecoration(
                  prefixIcon: Icon(LucideIcons.mail, size: 17),
                  helperText: 'Email ou téléphone — au moins un des deux',
                ),
                validator: (v) {
                  final value = v?.trim() ?? '';
                  if (value.isEmpty) return null;
                  return value.contains('@') ? null : 'Email invalide';
                },
              ),
              const SizedBox(height: 14),

              const AmpereFieldLabel('Téléphone'),
              TextFormField(
                controller: _phone,
                enabled: !_saving,
                keyboardType: TextInputType.phone,
                style: AmpereType.input.copyWith(color: colors.ink),
                decoration: const InputDecoration(
                  prefixIcon: Icon(LucideIcons.smartphone, size: 17),
                ),
              ),
              const SizedBox(height: 18),

              const AmpereFieldLabel('Rôle'),
              for (final role in AppRole.values)
                _RoleOption(
                  role: role,
                  selected: _role == role,
                  onTap: _saving ? null : () => setState(() => _role = role),
                ),

              if (!_isEdit) ...[
                const SizedBox(height: 18),
                const AmpereFieldLabel('Mot de passe temporaire'),
                TextFormField(
                  controller: _password,
                  enabled: !_saving,
                  style: AmpereType.input.copyWith(color: colors.ink),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(LucideIcons.keyRound, size: 17),
                    helperText:
                        'À communiquer au membre — il devra le changer à '
                        'sa première connexion',
                  ),
                  validator: (v) => (v == null || v.length < 8)
                      ? 'Au moins 8 caractères'
                      : null,
                ),
              ],

              if (_error != null) ...[
                const SizedBox(height: 16),
                AmpereInlineAlert(message: _error!),
              ],

              const SizedBox(height: 22),
              SizedBox(
                height: AmpereGeometry.touchPrimary,
                child: FilledButton(
                  onPressed: _saving ? null : _submit,
                  child: _saving
                      ? SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: colors.onAccent,
                          ),
                        )
                      : Text(_isEdit ? 'Enregistrer' : 'Créer le compte'),
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _saving ? null : () => Navigator.of(context).pop(),
                child: const Text('Annuler'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Choix du rôle : chaque option dit ce qu'elle autorise, pour que l'admin
/// n'ait pas à deviner (les 3 rôles sont figés par CLAUDE.md).
class _RoleOption extends StatelessWidget {
  const _RoleOption({
    required this.role,
    required this.selected,
    required this.onTap,
  });

  final AppRole role;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected ? colors.accentBg : colors.surface2,
        borderRadius: BorderRadius.circular(AmpereGeometry.fieldRadiusMobile),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AmpereGeometry.fieldRadiusMobile),
          child: Container(
            constraints: const BoxConstraints(
              minHeight: AmpereGeometry.touchDefault,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              border: Border.all(
                color: selected ? colors.accent : colors.line,
                width: 1,
              ),
              borderRadius: BorderRadius.circular(AmpereGeometry.fieldRadiusMobile),
            ),
            child: Row(
              children: [
                Icon(
                  selected ? LucideIcons.circleCheck : LucideIcons.circle,
                  size: 19,
                  color: selected ? colors.accent : colors.ink3,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        role.label,
                        style: AmpereType.rowTitle.copyWith(color: colors.ink),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        role.description,
                        style: AmpereType.meta.copyWith(color: colors.ink3),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
