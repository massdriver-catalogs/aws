# What a new Fauxroku app answers with until its own image is pushed.
FROM busybox:1.36.1
COPY index.html logo.svg /www/
EXPOSE 8080
CMD ["httpd", "-f", "-p", "8080", "-h", "/www"]
