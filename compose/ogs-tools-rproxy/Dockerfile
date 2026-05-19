FROM docker.io/nginx:1.29

COPY nginx.conf /etc/nginx/nginx.conf

# Copy the landing page to the default nginx html directory
COPY index.html /etc/nginx/html/index.html

# Make cache/temp/run dirs writable for any UID
RUN mkdir -p /var/cache/nginx/client_temp /run \
    && chmod -R 777 /var/cache/nginx /run

EXPOSE 8080

CMD ["nginx", "-g", "daemon off;"]
