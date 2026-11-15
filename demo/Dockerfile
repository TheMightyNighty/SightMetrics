FROM php:8.5-cli

RUN apt-get update && apt-get install -y --no-install-recommends \
      git unzip libicu-dev libzip-dev libpng-dev libonig-dev default-mysql-client \
 && docker-php-ext-configure gd \
 && docker-php-ext-install -j"$(nproc)" pdo_mysql mysqli gd intl zip \
 && rm -rf /var/lib/apt/lists/*

 COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

ENV COMPOSER_ALLOW_SUPERUSER=1

WORKDIR /var/www/html

COPY entrypoint.sh /entrypoint.sh

# Bewusst root: Der Dev-Container schreibt composer/TYPO3-Dateien in den
# Bind-Mount ./app. Unter rootless Docker ist root im Container der Host-User;
# ein anderer UID würde dort fremde Dateien anlegen. Nicht für Produktion.
# trivy:ignore:DS-0002
USER root

ENTRYPOINT ["bash"]
CMD ["/entrypoint.sh"]
