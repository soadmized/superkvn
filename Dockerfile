FROM nginx:alpine

RUN apk add --no-cache gettext

COPY site/ /usr/share/nginx/html/
