import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../breakpoints.dart';
import '../theme/ampere_colors.dart';
import '../theme/ampere_typography.dart';
import 'ampere_controls.dart';
import 'screen_state.dart';

/// Ouvre un formulaire — **panneau latéral** sur desktop, **plein écran** sur
/// mobile : une saisie longue ne se fait jamais dans une feuille modale basse
/// (AMPÈRE §7). Renvoie ce que le formulaire a enregistré, ou `null`.
Future<T?> openFormPanel<T>(BuildContext context, Widget form) {
  if (isDesktopWidth(MediaQuery.sizeOf(context).width)) {
    return showAmpereSidePanel<T>(context: context, builder: (_) => form);
  }
  return Navigator.of(context).push<T>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => Scaffold(body: SafeArea(child: form)),
    ),
  );
}

/// Cadre commun d'un formulaire : titre + fermer, contenu défilant, erreur en
/// bas du contenu, action principale pleine largeur et « Annuler » dessous.
/// `onSubmit == null` → consultation seule : pas d'action principale.
class FormPanelFrame extends StatelessWidget {
  const FormPanelFrame({
    super.key,
    required this.formKey,
    required this.title,
    required this.children,
    this.submitLabel = 'Enregistrer',
    this.onSubmit,
    this.saving = false,
    this.error,
  });

  final GlobalKey<FormState> formKey;
  final String title;
  final List<Widget> children;
  final String submitLabel;
  final VoidCallback? onSubmit;
  final bool saving;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final close = saving ? null : () => Navigator.of(context).pop();

    return Form(
      key: formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 8, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: AmpereType.sectionTitle.copyWith(color: colors.ink),
                  ),
                ),
                IconButton(
                  tooltip: 'Fermer',
                  onPressed: close,
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
                ...children,
                if (error != null) ...[
                  const SizedBox(height: 16),
                  AmpereInlineAlert(message: error!),
                ],
              ],
            ),
          ),
          if (onSubmit != null) ...[
            Divider(height: 1, color: colors.line),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton(
                    onPressed: saving ? null : onSubmit,
                    child: saving
                        ? SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: colors.onAccent,
                            ),
                          )
                        : Text(submitLabel),
                  ),
                  const SizedBox(height: 4),
                  TextButton(onPressed: close, child: const Text('Annuler')),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Espacement vertical standard entre deux champs.
const formFieldGap = SizedBox(height: 14);
