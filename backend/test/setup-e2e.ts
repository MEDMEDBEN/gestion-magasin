/// Les tests d'intégration enchaînent volontairement de nombreuses connexions :
/// on desserre les limites anti-brute-force pour ne pas tester le throttler ici.
/// (`test/http-hardening.e2e-spec.ts` les resserre pour tester le throttler lui-même.)
process.env.AUTH_LOGIN_LIMIT = '10000';
process.env.AUTH_REFRESH_LIMIT = '10000';
process.env.AUTH_CHANGE_PASSWORD_LIMIT = '10000';
process.env.API_RATE_LIMIT = '100000';

/// Contrat d'idempotence (src/common/idempotency.ts) : les mutations d'argent
/// EXIGENT un `clientMutationId`. Pour les tests qui ne portent pas sur
/// l'idempotence, une clé NEUVE est ajoutée à chaque envoi — exactement ce que
/// fait un client pour une nouvelle opération. Les tests de rejeu fixent leur
/// clé eux-mêmes (jamais écrasée) ; un corps envoyé en CHAÎNE JSON n'est pas
/// touché (sert à prouver qu'une requête sans clé est refusée).
// eslint-disable-next-line @typescript-eslint/no-require-imports
const Test = require('supertest/lib/test') as {
  prototype: { send: (body: unknown) => unknown; url: string };
};
// eslint-disable-next-line @typescript-eslint/no-require-imports
const { randomUUID } = require('crypto') as { randomUUID: () => string };
const MONEY_ROUTE =
  /\/api\/(sales|payments\/(customer|supplier)|cash-sessions(\/[^/]+\/close)?)$/;
const originalSend = Test.prototype.send;
Test.prototype.send = function (this: { url: string }, body: unknown) {
  if (
    MONEY_ROUTE.test(new URL(this.url).pathname) &&
    body !== null &&
    typeof body === 'object' &&
    !('clientMutationId' in body)
  ) {
    body = { ...body, clientMutationId: randomUUID() };
  }
  return originalSend.call(this, body);
};
