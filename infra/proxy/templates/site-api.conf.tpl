# Site __DOMAIN__ : fichiers dans /srv/sites/__DOMAIN__, et __PREFIX__ vers le
# backend __BACKEND__ (conteneur sur le réseau « proxy »).
server {
    listen 80;
    server_name __DOMAIN__;
    root /srv/sites/__DOMAIN__;

    include /etc/nginx/snippets/security-headers.conf;

    location __PREFIX__ {
        # Variable = adresse relue à chaque appel (backend arrêté : 502, pas
        # de Nginx bloqué). Sans chemin après l'hôte : l'URI passe telle quelle.
        set $backend http://__BACKEND__;
        proxy_pass $backend;
        include /etc/nginx/snippets/proxy.conf;
    }

    include /etc/nginx/snippets/spa.conf;
}
