# =====================================================================
# Cenario 3: PHP + Swoole (servidor HTTP assincrono, atras do Traefik)
# =====================================================================
FROM php:8.4-cli-bookworm

COPY --from=mlocati/php-extension-installer /usr/bin/install-php-extensions /usr/local/bin/

# install-php-extensions cuida das libs de build/runtime do Swoole automaticamente
RUN install-php-extensions pdo_mysql intl opcache swoole zip

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

COPY docker/swoole/php.ini /usr/local/etc/php/conf.d/zz-benchmark.ini

WORKDIR /app
COPY app/ /app/

RUN composer install --no-dev --optimize-autoloader --no-interaction --no-progress \
 && APP_ENV=prod APP_DEBUG=0 APP_SECRET=build \
    DATABASE_URL="mysql://b:b@db:3306/b?serverVersion=8.0.32&charset=utf8mb4" \
    php bin/console cache:warmup --no-interaction \
 && chown -R www-data:www-data /app

EXPOSE 8000

# Servidor Swoole dedicado (boota o Kernel uma vez por worker)
CMD ["php", "/app/bin/swoole-server.php"]
