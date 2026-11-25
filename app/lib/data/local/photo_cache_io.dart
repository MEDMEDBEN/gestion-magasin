import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Photos des produits en FICHIERS, dans le dossier de l'app (à côté de la
/// base locale) : `photos/<produit>/<nom de la photo>`. Une photo remplacée
/// efface l'ancienne. Au mieux : une erreur de disque ne bloque jamais
/// l'affichage, la photo est alors simplement redemandée au serveur.
class PhotoCache {
  PhotoCache({Future<Directory> Function()? root})
    : _root = root ?? _defaultRoot;

  final Future<Directory> Function() _root;

  static Future<Directory> _defaultRoot() async => Directory(
    p.join((await getApplicationSupportDirectory()).path, 'photos'),
  );

  bool get enabled => true;

  /// Le nom de fichier vient de la clé versionnée du serveur
  /// (`products/<id>/<uuid>.jpg`) : nouvelle photo = nouveau nom.
  Future<File> _file(String productId, String imageKey) async {
    String safe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return File(
      p.join((await _root()).path, safe(productId), safe(p.basename(imageKey))),
    );
  }

  Future<Uint8List?> read(String productId, String imageKey) async {
    try {
      final file = await _file(productId, imageKey);
      return await file.exists() ? await file.readAsBytes() : null;
    } on Object {
      return null;
    }
  }

  Future<void> write(String productId, String imageKey, Uint8List bytes) async {
    try {
      final file = await _file(productId, imageKey);
      final dir = file.parent;
      await dir.create(recursive: true);
      // Écrit à côté puis renommé : jamais une photo à moitié écrite.
      final tmp = File('${file.path}.part');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(file.path);
      // L'ancienne photo de ce produit n'a plus d'usage.
      await for (final other in dir.list()) {
        if (other.path != file.path) await other.delete();
      }
    } on Object {
      // Disque plein, droits… : la photo reste lisible en ligne.
    }
  }

  /// « Vider ce poste » : les photos partent avec le reste.
  Future<void> clear() async {
    try {
      final root = await _root();
      if (await root.exists()) await root.delete(recursive: true);
    } on Object {
      // Rien à effacer ou dossier verrouillé : sans conséquence.
    }
  }
}
