import 'dart:typed_data';

/// Version web : aucun fichier sur le poste (le navigateur garde les photos
/// 24 h dans son propre cache).
class PhotoCache {
  bool get enabled => false;

  Future<Uint8List?> read(String productId, String imageKey) async => null;

  Future<void> write(
    String productId,
    String imageKey,
    Uint8List bytes,
  ) async {}

  Future<void> clear() async {}
}
