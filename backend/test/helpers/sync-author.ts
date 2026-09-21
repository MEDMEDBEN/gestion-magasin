/// Compte porteur d'un access token (claim `sub`). Un lot de sync déclare son
/// auteur, qui doit être ce porteur (prérequis N6b) : les tests le lisent dans
/// le jeton plutôt que de faire circuler l'identifiant partout.
export function authorOf(accessToken: string): string {
  const payload = accessToken.split('.')[1];
  return (
    JSON.parse(Buffer.from(payload, 'base64url').toString()) as {
      sub: string;
    }
  ).sub;
}
