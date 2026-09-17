import { Injectable, ParseUUIDPipe, PipeTransform } from '@nestjs/common';

/// Valide un UUID de route ET le renvoie sous sa forme CANONIQUE (minuscules).
///
/// PostgreSQL retrouve la même ligne quelle que soit la casse, mais une
/// comparaison de chaînes côté service non : `PATCH /users/<SON-ID-EN-MAJUSCULES>`
/// contournait l'interdiction de modifier son propre compte (contre-audit N2).
@Injectable()
export class CanonicalUuidPipe implements PipeTransform<
  string,
  Promise<string>
> {
  private readonly uuid = new ParseUUIDPipe();

  async transform(value: string): Promise<string> {
    const valid = await this.uuid.transform(value, { type: 'param' });
    return valid.toLowerCase();
  }
}
