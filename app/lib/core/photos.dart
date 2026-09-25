import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

/// Choix d'une photo par l'utilisateur (galerie, ou fichier sur desktop),
/// compressée avant envoi. Remplaçable en test.
///
/// Vit dans `core/` et non dans une feature : la photo de produit et celle d'un
/// signalement passent par le même chemin — même limite serveur (2 Mo), même
/// compression.
final pickPhotoProvider = Provider<Future<Uint8List?> Function()>(
  (ref) => () async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (file == null) return null;
    return compute(compressPhoto, await file.readAsBytes());
  },
);

/// JPEG ≤ 1024 px de côté, qualité 80 : quelques centaines de ko, loin des 2 Mo
/// acceptés par le serveur. `null` si le fichier n'est pas une image lisible.
Uint8List? compressPhoto(Uint8List bytes) {
  final img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } catch (_) {
    // Un fichier tronqué ou d'un autre format peut faire lever le décodeur.
    return null;
  }
  if (decoded == null) return null;
  final resized = decoded.width >= decoded.height
      ? (decoded.width > 1024 ? img.copyResize(decoded, width: 1024) : decoded)
      : (decoded.height > 1024
            ? img.copyResize(decoded, height: 1024)
            : decoded);
  return img.encodeJpg(resized, quality: 80);
}
