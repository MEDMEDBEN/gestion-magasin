/// Les tests d'intégration enchaînent volontairement de nombreuses connexions :
/// on desserre les limites anti-brute-force pour ne pas tester le throttler ici.
/// (`test/http-hardening.e2e-spec.ts` les resserre pour tester le throttler lui-même.)
process.env.AUTH_LOGIN_LIMIT = '10000';
process.env.AUTH_REFRESH_LIMIT = '10000';
process.env.AUTH_CHANGE_PASSWORD_LIMIT = '10000';
process.env.API_RATE_LIMIT = '100000';
