ARG PHP_VERSION=8.3
FROM php:${PHP_VERSION}-fpm

ADD https://github.com/mlocati/docker-php-extension-installer/releases/latest/download/install-php-extensions /usr/local/bin/
RUN chmod +x /usr/local/bin/install-php-extensions \
    && install-php-extensions gd mysqli opcache zip intl bcmath exif soap \
    && apt-get update && apt-get install -y --no-install-recommends msmtp-mta \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /var/www/html
