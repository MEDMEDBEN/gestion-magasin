// Photos des produits gardées SUR LE POSTE (demande MEDMEDBEN du 2026-11-25 :
// hors ligne, l'app installée montre ses photos). Version web : rien n'est
// gardé ici, le cache du navigateur s'en charge.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'photo_cache_io.dart'
    if (dart.library.js_interop) 'photo_cache_web.dart';

export 'photo_cache_io.dart'
    if (dart.library.js_interop) 'photo_cache_web.dart';

final photoCacheProvider = Provider<PhotoCache>((ref) => PhotoCache());
