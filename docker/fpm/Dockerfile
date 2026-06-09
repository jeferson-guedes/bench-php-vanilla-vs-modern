# =====================================================================
# Cenario 1: PHP-FPM (com Opcache + JIT) atras do Nginx (Unix socket)
# =====================================================================
FROM php:8.4-fpm-bookworm

# Helper robusto para instalar extensoes (resolve libs do sistema sozinho)
COPY --from=mlocati/php-extension-installer /usr/bin/install-php-extensions /usr/local/bin/

RUN install-php-extensions pdo_mysql intl opcache zip

# Composer
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# Configuracoes de PHP (Opcache + JIT CRITICAL) e do pool FPM (Unix socket)
COPY docker/fpm/php.ini  /usr/local/etc/php/conf.d/zz-benchmark.ini
COPY docker/fpm/www.conf /usr/local/etc/php-fpm.d/zz-www.conf

WORKDIR /app

# Codigo da aplicacao (mesmo codigo dos 3 cenarios)
COPY app/ /app/

# Diretorio do socket compartilhado com o Nginx (via volume)
RUN mkdir -p /var/run/php

# Instala dependencias e aquece o cache de producao.
# DATABASE_URL "dummy" so para o warmup: graças ao server_version o Symfony
# nao abre conexao real ao MySQL durante o cache:warmup.
RUN composer install --no-dev --optimize-autoloader --no-interaction --no-progress \
 && APP_ENV=prod APP_DEBUG=0 APP_SECRET=build \
    DATABASE_URL="mysql://b:b@db:3306/b?serverVersion=8.0.32&charset=utf8mb4" \
    php bin/console cache:warmup --no-interaction \
 && chown -R www-data:www-data /app /var/run/php

CMD ["php-fpm"]
