import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/error/api_exception.dart';
import '../../../ui/breakpoints.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/ampere_controls.dart';
import '../../../ui/widgets/screen_state.dart';
import '../application/users_controller.dart';
import '../data/user_models.dart';

/// Ouvre le formulaire de compte — **panneau latéral** sur desktop, **plein
/// écran** sur mobile : une saisie longue ne se fait jamais dans une feuille
/// modale basse (AMPÈRE §7). Renvoie le compte enregistré, ou `null`.
Future<ManagedUser?> openUserForm(
  BuildContext context, {
  ManagedUser? existing,
  String? currentUserId,
}) {
  final form = UserForm(
    existing: existing,
    isSelf: existing != null && existing.id == currentUserId,
  );
  if (isDesktopWidth(MediaQuery.sizeOf(context).width)) {
    return showAmpereSidePanel<ManagedUser>(
      context: context,
      builder: (_) => form,
    );
  }
  return Navigator.of(context).push<ManagedUser>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => Scaffold(body: SafeArea(child: form)),
    ),
  );
}

const _emailPattern = r'^[^@\s]+@[^@\s]+\.[^@\s]+$';

/// Mêmes règles que le serveur (`common/identifiers.ts`) : ponctuation de
/// saisie retirée, puis 6 à 15 chiffres, `+` international accepté.
String normalizePhone(String value) => value.replaceAll(RegExp(r'[\s.\-()]'), '');
final _phonePattern = RegExp(r'^\+?[0-9]{6,15}$');

/// Rôles dans l'ordre d'affichage du système, quel que soit l'ordre de clic.
List<String> _ordered(Set<String> roles) => [
      for (final role in AppRole.values)
        if (roles.contains(role.code)) role.code,
    ];

/// Création ou édition d'un compte (ADMIN uniquement — le serveur le vérifie).
class UserForm extends ConsumerStatefulWidget {
  const UserForm({super.key, this.existing, this.isSelf = false});

  final ManagedUser? existing;

  /// L'admin édite SON propre compte : ses rôles, permissions et activation
  /// relèvent d'un autre administrateur (règle serveur) — champs verrouillés.
  final bool isSelf;

  @override
  ConsumerState<UserForm> createState() => _UserFormState();
}

class _UserFormState extends ConsumerState<UserForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _fullName;
  late final TextEditingController _email;
  late final TextEditingController _phone;
  final _password = TextEditingController();

  late Set<String> _roles;
  bool _saving = false;
  String? _error;
  String? _rolesError;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _fullName = TextEditingController(text: existing?.fullName ?? '');
    _email = TextEditingController(text: existing?.email ?? '');
    _phone = TextEditingController(text: existing?.phone ?? '');
    // TOUS les rôles du compte — un membre peut en cumuler plusieurs.
    _roles = {...?existing?.roles};
    if (existing == null) _roles.add(AppRole.vendeur.code);
  }

  @override
  void dispose() {
    _fullName.dispose();
    _email.dispose();
    _phone.dispose();
    _password.dispose();
    super.dispose();
  }

  void _toggleRole(String code, bool selected) {
    setState(() {
      selected ? _roles.add(code) : _roles.remove(code);
      _rolesError = null;
    });
  }

  Future<void> _submit() async {
    final fieldsValid = _formKey.currentState!.validate();
    if (_roles.isEmpty) {
      setState(() => _rolesError = 'Au moins un rôle est obligatoire');
      return;
    }
    if (!fieldsValid) return;

    final fullName = _fullName.text.trim();
    final email = _email.text.trim().toLowerCase();
    final phone = normalizePhone(_phone.text);
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
      final ManagedUser saved;
      final existing = widget.existing;
      if (existing == null) {
        saved = await controller.create(
          fullName: fullName,
          email: email.isEmpty ? null : email,
          phone: phone.isEmpty ? null : phone,
          temporaryPassword: _password.text,
          roles: _ordered(_roles),
        );
      } else {
        final rolesChanged = !setEquals(_roles, existing.roles.toSet());
        final changes = UserChanges(
          fullName: fullName != existing.fullName ? fullName : null,
          email: email.isNotEmpty && email != existing.email ? email : null,
          phone: phone.isNotEmpty && phone != existing.phone ? phone : null,
          // Jamais renvoyés s'ils n'ont pas bougé : sur un compte à rôles
          // cumulés, ce serait un changement de rôle que personne n'a voulu.
          roles: !widget.isSelf && rolesChanged ? _ordered(_roles) : null,
        );
        saved = changes.isEmpty
            ? existing
            : await controller.updateUser(existing.id, changes);
      }
      if (mounted) Navigator.of(context).pop(saved);
    } on ApiException catch (error) {
      // La saisie n'est JAMAIS perdue sur erreur (§8).
      _fail(error.userMessage);
    } catch (_) {
      _fail('Enregistrement impossible. Vos saisies sont conservées.');
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _saving = false;
      _error = message;
    });
  }

  String? _validateIdentifier(String? value, String? previous, bool isEmail) {
    final raw = value?.trim() ?? '';
    if (raw.isEmpty) {
      // Un identifiant de connexion existant ne se retire pas (le serveur
      // refuse `null`) : on le dit AVANT l'envoi.
      return previous != null ? 'Un identifiant de connexion ne peut pas être retiré' : null;
    }
    if (isEmail) {
      return RegExp(_emailPattern).hasMatch(raw) ? null : 'Email invalide';
    }
    return _phonePattern.hasMatch(normalizePhone(raw))
        ? null
        : '6 à 15 chiffres, « + » international accepté';
  }

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final locked = widget.isSelf || _saving;

    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 8, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _isEdit ? 'Modifier le compte' : 'Nouvel utilisateur',
                    style: AmpereType.sectionTitle.copyWith(color: colors.ink),
                  ),
                ),
                IconButton(
                  tooltip: 'Fermer',
                  onPressed: _saving ? null : () => Navigator.of(context).pop(),
                  icon: const Icon(LucideIcons.x, size: 19),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: colors.line),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 24),
              children: [
                const AmpereFieldLabel('Nom complet'),
                TextFormField(
                  controller: _fullName,
                  enabled: !_saving,
                  autofocus: !_isEdit,
                  maxLength: 100,
                  style: AmpereType.input.copyWith(color: colors.ink),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(LucideIcons.user, size: 17),
                    counterText: '',
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
                  autocorrect: false,
                  style: AmpereType.input.copyWith(color: colors.ink),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(LucideIcons.mail, size: 17),
                    helperText: 'Email ou téléphone — au moins un des deux',
                  ),
                  validator: (v) =>
                      _validateIdentifier(v, widget.existing?.email, true),
                ),
                const SizedBox(height: 14),

                const AmpereFieldLabel('Téléphone'),
                TextFormField(
                  controller: _phone,
                  enabled: !_saving,
                  keyboardType: TextInputType.phone,
                  autocorrect: false,
                  style: AmpereType.input.copyWith(color: colors.ink),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(LucideIcons.smartphone, size: 17),
                  ),
                  validator: (v) =>
                      _validateIdentifier(v, widget.existing?.phone, false),
                ),
                const SizedBox(height: 20),

                const AmpereFieldLabel('Rôles'),
                if (widget.isSelf)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 10),
                    child: AmpereInlineAlert(
                      tone: StatusTone.info,
                      icon: LucideIcons.shield,
                      message: 'Vos rôles et permissions sont modifiés par un '
                          'autre administrateur.',
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Un membre peut cumuler plusieurs rôles.',
                      style: AmpereType.meta.copyWith(color: colors.ink3),
                    ),
                  ),
                for (final role in AppRole.values)
                  _CheckOption(
                    title: role.label,
                    subtitle: role.description,
                    selected: _roles.contains(role.code),
                    onChanged: locked
                        ? null
                        : (selected) => _toggleRole(role.code, selected),
                  ),
                if (_rolesError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2, bottom: 6),
                    child: Text(
                      _rolesError!,
                      style: AmpereType.metaDesktop.copyWith(color: colors.error),
                    ),
                  ),

                if (!_isEdit) ...[
                  const SizedBox(height: 20),
                  const AmpereFieldLabel('Mot de passe temporaire'),
                  TextFormField(
                    controller: _password,
                    enabled: !_saving,
                    autocorrect: false,
                    enableSuggestions: false,
                    maxLength: 128,
                    style: AmpereType.input.copyWith(color: colors.ink),
                    decoration: const InputDecoration(
                      prefixIcon: Icon(LucideIcons.keyRound, size: 17),
                      counterText: '',
                      helperText: 'À communiquer au membre — il devra le '
                          'changer à sa première connexion',
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
              ],
            ),
          ),
          Divider(height: 1, color: colors.line),
          // Action principale pleine largeur, « Annuler » dessous : tient sur
          // un téléphone comme dans le panneau de 440 px, même au zoom texte.
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton(
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
                const SizedBox(height: 4),
                TextButton(
                  onPressed: _saving ? null : () => Navigator.of(context).pop(),
                  child: const Text('Annuler'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Option à cocher (rôle) : libellé + précision, cible ≥ 48 (§7),
/// focus clavier visible (§12.10).
class _CheckOption extends StatelessWidget {
  const _CheckOption({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool selected;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final enabled = onChanged != null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        checked: selected,
        enabled: enabled,
        // Pas d'opacité sur du texte porteur d'information (§1.5) : un compte
        // verrouillé l'est expliqué par un bandeau, pas par un texte pâli.
        child: AmpereTappable(
            onTap: enabled ? () => onChanged!(!selected) : null,
            borderRadius: AmpereGeometry.fieldRadiusMobile,
            color: selected ? colors.accentBg : colors.surface2,
            child: Container(
              constraints: const BoxConstraints(
                minHeight: AmpereGeometry.touchDefault,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                border: Border.all(
                  color: selected ? colors.accent : colors.line,
                  width: AmpereGeometry.borderWidth,
                ),
                borderRadius:
                    BorderRadius.circular(AmpereGeometry.fieldRadiusMobile),
              ),
              child: Row(
                children: [
                  Icon(
                    selected ? LucideIcons.squareCheck : LucideIcons.square,
                    size: 19,
                    color: selected ? colors.accent : colors.ink3,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: AmpereType.rowTitle.copyWith(color: colors.ink),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
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
