/// Les tests d'intégration enchaînent volontairement de nombreuses connexions :
/// on desserre les limites anti-brute-force pour ne pas tester le throttler ici.
process.env.AUTH_LOGIN_LIMIT = '10000';
process.env.AUTH_REFRESH_LIMIT = '10000';
