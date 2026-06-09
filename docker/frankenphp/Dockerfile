# =====================================================================
# Cenario 2: FrankenPHP em Worker Mode (atras do Traefik)
# =====================================================================
FROM dunglas/frankenphp:1-php8.4

# install-php-extensions ja vem na imagem oficial do FrankenPHP
RUN install-php-extensions pdo_mysql intl opcache zip

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# php.ini (Opcache + JIT) e Caddyfile (define o worker apontando p/ public/index.php)
COPY docker/frankenphp/php.ini   /usr/local/etc/php/conf.d/zz-benchmark.ini
COPY docker/frankenphp/Caddyfile /etc/frankenphp/Caddyfile

WORKDIR /app
COPY app/ /app/

RUN composer install --no-dev --optimize-autoloader --no-interaction --no-progress \
 && APP_ENV=prod APP_DEBUG=0 APP_SECRET=build \
    DATABASE_URL="mysql://b:b@db:3306/b?serverVersion=8.0.32&charset=utf8mb4" \
    php bin/console cache:warmup --no-interaction \
 && chown -R www-data:www-data /app

# O entrypoint padrao da imagem executa: frankenphp run --config /etc/frankenphp/Caddyfile
