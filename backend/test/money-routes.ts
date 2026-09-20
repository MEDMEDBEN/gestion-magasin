/// Routes de MUTATION D'ARGENT — liste UNIQUE, partagée par :
/// - `setup-e2e.ts`, qui leur ajoute une clé d'idempotence quand un test n'en
///   fournit pas (cas d'une opération neuve) ;
/// - `money-contract.e2e-spec.ts`, qui vérifie que CHACUNE refuse une requête
///   sans clé (400).
/// Ajouter une route d'argent ici force donc l'assertion du contrat : une
/// nouvelle route ne peut pas échapper au test en silence.
export const MONEY_ROUTES = [
  '/api/sales',
  '/api/cash-sessions',
  '/api/cash-sessions/:id/close',
  '/api/payments/customer',
  '/api/payments/customer/:id/reverse',
  '/api/payments/supplier',
  '/api/payments/supplier/:id/reverse',
  // La réception fait entrer la marchandise ET augmente la dette fournisseur.
  '/api/receptions',
] as const;

/// `/api/payments/customer/:id/reverse` → motif de chemin réel.
export function isMoneyRoute(pathname: string): boolean {
  return MONEY_ROUTES.some((route) =>
    new RegExp(
      `^${route.replace(/:[^/]+/g, '[^/]+').replace(/\//g, '\/')}$`,
    ).test(pathname),
  );
}
