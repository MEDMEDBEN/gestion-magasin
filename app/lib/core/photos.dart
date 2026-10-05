import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

/// Choix d'une photo par l'utilisateur (galerie, ou fichier sur desktop),
/// compressée avant envoi. Remplaçable en test. Rend `null` si l'utilisateur
/// annule ; une image illisible LÈVE `FormatException` (message à afficher) —
/// avant, elle était ignorée sans un mot (bug terrain du 2026-10-05).
///
/// Vit dans `core/` et non dans une feature : la photo de produit et celle d'un
/// signalement passent par le même chemin — même limite serveur (2 Mo), même
/// compression.
final pickPhotoProvider = Provider<Future<Uint8List?> Function()>(
  (ref) => () async {
    // Taille et qualité demandées : sur téléphone, le système RÉENCODE la
    // photo en JPEG — une photo HEIC/HEIF (Samsung, iPhone) devient lisible.
    final file = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1024,
      maxHeight: 1024,
      imageQuality: 85,
    );
    if (file == null) return null;
    final jpeg = await compute(compressPhoto, await file.readAsBytes());
    if (jpeg == null) throw const FormatException('Image illisible');
    return jpeg;
  },
);

/// Photo d'un DOCUMENT (facture à lire, P2 n°24) : l'appareil photo sur
/// mobile, un fichier sur desktop ; niveaux de gris, ≤ 2 200 px — assez grand
/// pour que le texte reste lisible, sous les 5 Mo acceptés par le serveur.
final pickDocumentPhotoProvider = Provider<Future<Uint8List?> Function()>(
  (ref) => () async {
    final mobile =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    final file = await ImagePicker().pickImage(
      source: mobile ? ImageSource.camera : ImageSource.gallery,
    );
    if (file == null) return null;
    final jpeg = await compute(compressDocument, await file.readAsBytes());
    // Annuler rend `null` ; une image illisible est une ERREUR (message).
    if (jpeg == null) throw const FormatException('Image illisible');
    return jpeg;
  },
);

/// Niveaux de gris, ≤ 2 200 px de côté, JPEG qualité 85. `null` si illisible.
Uint8List? compressDocument(Uint8List bytes) {
  final img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } catch (_) {
    return null;
  }
  if (decoded == null) return null;
  const max = 2200;
  final resized = decoded.width >= decoded.height
      ? (decoded.width > max ? img.copyResize(decoded, width: max) : decoded)
      : (decoded.height > max ? img.copyResize(decoded, height: max) : decoded);
  return img.encodeJpg(img.grayscale(resized), quality: 85);
}

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
