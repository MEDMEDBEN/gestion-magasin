/// Bornes des fichiers envoyés — partagées par TOUTES les routes d'upload.
///
/// Le corps JSON est borné par Express (128 ko), mais un envoi `multipart` y
/// échappe : sans `limits`, un fichier de plusieurs centaines de Mo est chargé
/// ENTIÈREMENT en mémoire avant le moindre contrôle, et met le serveur à terre
/// (audit sécurité P1 n°18). Toute nouvelle route d'upload reprend ceci.
export const IMAGE_MAX_BYTES = 2 * 1024 * 1024;

export const IMAGE_UPLOAD_LIMITS = {
  fileSize: IMAGE_MAX_BYTES,
  files: 1,
  fields: 0,
} as const;

/// Photo d'une facture à lire (P2 n°24) : plus grande qu'une photo produit —
/// le texte doit rester lisible (l'app l'envoie en niveaux de gris, ~2 200 px).
export const DOCUMENT_MAX_BYTES = 5 * 1024 * 1024;

export const DOCUMENT_UPLOAD_LIMITS = {
  fileSize: DOCUMENT_MAX_BYTES,
  files: 1,
  fields: 0,
} as const;

/// Fichier d'import Excel/CSV : 1 000 lignes tiennent largement en 2 Mo.
export const IMPORT_MAX_BYTES = 2 * 1024 * 1024;

export const IMPORT_UPLOAD_LIMITS = {
  fileSize: IMPORT_MAX_BYTES,
  files: 1,
  fields: 0,
} as const;
