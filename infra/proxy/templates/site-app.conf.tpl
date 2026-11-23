# Site __DOMAIN__ : TOUT est servi par le conteneur __BACKEND__ (réseau « proxy »)
# — Next.js, WordPress, Odoo, appli Node/Python qui rend ses propres pages…
server {
    listen 80;
    server_name __DOMAIN__;

    include /etc/nginx/snippets/security-headers.conf;

    location / {
        set $backend http://__BACKEND__;
        proxy_pass $backend;
        include /etc/nginx/snippets/proxy.conf;
    }
}
