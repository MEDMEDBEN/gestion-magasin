# Site __DOMAIN__ : HTTPS par Traefik, puis Nginx (fichier conf.d/__DOMAIN__.conf).
http:
  routers:
    __ROUTER__:
      rule: "Host(`__DOMAIN__`)"
      entryPoints: [websecure]
      service: nginx
      middlewares: [hsts]
      tls:
        certResolver: le
