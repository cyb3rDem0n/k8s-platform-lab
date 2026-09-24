# syntax=docker/dockerfile:1.7
# nginx "unprivileged": gira come utente 101 e ascolta su 8080 (niente root, niente porte <1024).
FROM nginxinc/nginx-unprivileged:1.29-alpine
COPY nginx/default.conf /etc/nginx/conf.d/default.conf
COPY html/ /usr/share/nginx/html/
EXPOSE 8080
