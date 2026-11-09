import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/providers.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';

/// Photo d'un compte (2026-11-09), par la route authentifiée — `null` sans
/// photo (404) ou hors ligne. `id` null : le compte CONNECTÉ (`/auth/me/photo`,
/// lisible par tous) ; sinon `/users/:id/photo` (ADMIN).
final userPhotoProvider = FutureProvider.autoDispose
    .family<Uint8List?, String?>((ref, id) async {
      final dio = ref.watch(dioClientProvider).dio;
      try {
        final response = await guardApi(
          () => dio.get<List<int>>(
            id == null ? '/auth/me/photo' : '/users/$id/photo',
            options: Options(responseType: ResponseType.bytes),
          ),
        );
        return Uint8List.fromList(response.data!);
      } on ApiException {
        return null;
      }
    });

/// Rond avec la photo du compte, ou ses initiales.
class UserAvatar extends ConsumerWidget {
  const UserAvatar({
    super.key,
    required this.name,
    this.userId,
    this.size = 40,
  });

  final String name;

  /// `null` : le compte connecté.
  final String? userId;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);
    final bytes = ref.watch(userPhotoProvider(userId)).value;
    final initials = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .take(2)
        .map((w) => w[0].toUpperCase())
        .join();
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: colors.accent.withValues(alpha: 0.14),
        border: Border.all(color: colors.accent.withValues(alpha: 0.45)),
      ),
      alignment: Alignment.center,
      child: bytes != null
          ? Image.memory(
              bytes,
              width: size,
              height: size,
              fit: BoxFit.cover,
              gaplessPlayback: true,
            )
          : Text(
              initials.isEmpty ? '?' : initials,
              style: AmpereType.bodyStrong.copyWith(
                color: colors.accent,
                fontSize: size * 0.36,
              ),
            ),
    );
  }
}
