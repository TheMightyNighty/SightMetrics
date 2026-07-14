FROM php:8.2-cli

RUN apt-get update && apt-get install -y --no-install-recommends \
      git unzip libicu-dev libzip-dev libpng-dev libonig-dev default-mysql-client \
 && docker-php-ext-configure gd \
 && docker-php-ext-install -j"$(nproc)" pdo_mysql mysqli gd intl zip \
 && rm -rf /var/lib/apt/lists/*

 COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

ENV COMPOSER_ALLOW_SUPERUSER=1

WORKDIR /var/www/html

COPY entrypoint.sh /entrypoint.sh

ENTRYPOINT ["bash"]
CMD ["/entrypoint.sh"]
