import { applyDecorators, HttpStatus } from '@nestjs/common';
import { ApiProperty } from '@nestjs/swagger';
import { Prisma } from '../generated/prisma/client';
import { BusinessException } from './business.exception';
import { ErrorCode } from './error-codes';
import { IsCanonicalUuid } from './validation';

/// Contrat d'idempotence des mutations d'ARGENT (CLAUDE.md règle 8,
/// docs/context.md §3) — ventes, règlements clients, paiements fournisseurs,
/// ouverture et clôture de caisse, contre-passations.
///
/// Le client génère UNE clé par intention (« encaisser 300 DA de ce client ») et
/// la réutilise pour TOUS les renvois de cette intention (délai dépassé, double
/// clic, réseau coupé). Le serveur applique l'effet au plus une fois :
/// - clé inconnue            → effet appliqué ;
/// - même clé, même contenu  → l'effet DÉJÀ appliqué est rendu (pas de second effet) ;
/// - même clé, autre contenu ou autre compte → 409, jamais un second effet.
export const ClientMutationId = () =>
  applyDecorators(
    ApiProperty({
      format: 'uuid',
      description:
        'Clé d’idempotence générée par le client, STABLE pour tous les renvois de la ' +
        'même opération. Renvoi identique → même résultat, sans second effet.',
    }),
    IsCanonicalUuid(),
  );

/// Vérifie qu'un enregistrement retrouvé par sa clé est bien un RENVOI de la
/// même opération, par le même compte. Sinon 409 : la clé désigne déjà autre chose.
export function assertSameMutation(
  existing: { userId: string },
  userId: string,
  sameContent: boolean,
  conflict: { code: ErrorCode; message: string },
): void {
  if (existing.userId !== userId) {
    throw new BusinessException(
      ErrorCode.CONFLICT,
      'Cette clé d’opération appartient à un autre compte',
      HttpStatus.CONFLICT,
    );
  }
  if (!sameContent) {
    throw new BusinessException(
      conflict.code,
      conflict.message,
      HttpStatus.CONFLICT,
    );
  }
}

/// Exécute une mutation d'argent au plus une fois.
///
/// `replay` retrouve l'effet déjà appliqué pour la clé (et lève 409 si la clé
/// désigne une autre opération) ; `apply` l'applique. Deux envois SIMULTANÉS de
/// la même clé : le second heurte la contrainte UNIQUE en base, on relit alors
/// l'effet du premier au lieu de répondre une erreur.
export async function runOnce<T>(
  replay: () => Promise<T | null>,
  apply: () => Promise<T>,
): Promise<T> {
  const already = await replay();
  if (already) return already;
  try {
    return await apply();
  } catch (error) {
    if (
      error instanceof Prisma.PrismaClientKnownRequestError &&
      error.code === 'P2002'
    ) {
      const concurrent = await replay();
      if (concurrent) return concurrent;
    }
    throw error;
  }
}
