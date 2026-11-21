# Site __DOMAIN__ : fichiers dans /srv/sites/__DOMAIN__ (dossier sites/ du socle).
server {
    listen 80;
    server_name __DOMAIN__;
    root /srv/sites/__DOMAIN__;

    include /etc/nginx/snippets/security-headers.conf;
    include /etc/nginx/snippets/spa.conf;
}
