<?php

use App\Kernel;

require_once dirname(__DIR__).'/vendor/autoload_runtime.php';

// O runtime efetivo e escolhido pela variavel de ambiente APP_RUNTIME:
//  - PHP-FPM (Nginx)  -> APP_RUNTIME nao definido  -> Symfony\Component\Runtime\SymfonyRuntime (SAPI classico)
//  - FrankenPHP        -> APP_RUNTIME=Runtime\FrankenPhpSymfony\Runtime (Worker Mode)
// O cenario Swoole NAO usa este arquivo; ele tem seu proprio servidor em bin/swoole-server.php
return function (array $context) {
    return new Kernel($context['APP_ENV'], (bool) $context['APP_DEBUG']);
};
