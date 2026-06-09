<?php

/**
 * Servidor HTTP Swoole para o Symfony.
 *
 * Boota o Kernel UMA vez (fora do loop de requisicoes) e converte cada
 * Swoole\Http\Request em Symfony Request e a Symfony Response de volta em
 * Swoole\Http\Response.
 *
 * Cada worker Swoole mantem seu proprio Kernel + conexao Doctrine persistente.
 * Portanto o numero de conexoes ativas no MySQL tende a:  SWOOLE_WORKERS.
 * Ajuste SWOOLE_WORKERS x max_connections do MySQL para observar o cenario de
 * "Too many connections".
 *
 * Alternativa "oficial": runtime/swoole (php-runtime/swoole) com
 * APP_RUNTIME=Runtime\Swoole\Runtime no public/index.php. Aqui usamos um
 * servidor dedicado para deixar o gerenciamento de estado/conexao explicito.
 */

use App\Kernel;
use Swoole\Http\Request as SwooleRequest;
use Swoole\Http\Response as SwooleResponse;
use Swoole\Http\Server;
use Symfony\Component\Dotenv\Dotenv;
use Symfony\Component\HttpFoundation\Request as SymfonyRequest;

require dirname(__DIR__).'/vendor/autoload.php';

// Carrega .env apenas se existir (em container as variaveis ja vem do ambiente).
if (class_exists(Dotenv::class) && is_file(dirname(__DIR__).'/.env')) {
    (new Dotenv())->bootEnv(dirname(__DIR__).'/.env', 'prod', ['test'], false);
}

$appEnv   = $_SERVER['APP_ENV']   ?? getenv('APP_ENV')   ?: 'prod';
$appDebug = (bool) ($_SERVER['APP_DEBUG'] ?? getenv('APP_DEBUG') ?: false);

$host    = getenv('SWOOLE_HOST')    ?: '0.0.0.0';
$port    = (int) (getenv('SWOOLE_PORT')    ?: 8000);
$workers = (int) (getenv('SWOOLE_WORKERS') ?: 4);

// Kernel iniciado uma unica vez por worker (Swoole faz fork apos o boot do master,
// mas o boot real do container ocorre no primeiro uso dentro de cada worker).
$kernel = new Kernel($appEnv, $appDebug);
$kernel->boot();

$server = new Server($host, $port);
$server->set([
    'worker_num'        => $workers,
    'max_request'       => 0,      // 0 = worker nunca recicla (estado 100% persistente)
    'enable_coroutine'  => false,  // execucao sincrona: 1 request por vez por worker
    'http_compression'  => true,
    'log_level'         => SWOOLE_LOG_WARNING,
]);

$server->on('start', static function (Server $server) use ($host, $port, $workers): void {
    fwrite(STDOUT, sprintf("[swoole] HTTP server em http://%s:%d (workers=%d)\n", $host, $port, $workers));
});

$server->on('request', static function (SwooleRequest $swReq, SwooleResponse $swResp) use ($kernel): void {
    $sfRequest = swooleToSymfonyRequest($swReq);

    try {
        $sfResponse = $kernel->handle($sfRequest);

        $swResp->status($sfResponse->getStatusCode());
        foreach ($sfResponse->headers->allPreserveCaseWithoutCookies() as $name => $values) {
            foreach ((array) $values as $value) {
                $swResp->header($name, $value);
            }
        }
        $swResp->end($sfResponse->getContent());

        $kernel->terminate($sfRequest, $sfResponse);
    } catch (\Throwable $e) {
        $swResp->status(500);
        $swResp->header('Content-Type', 'application/json');
        $swResp->end(json_encode([
            'error' => 'internal_error',
            'message' => $e->getMessage(),
        ], JSON_UNESCAPED_SLASHES));
    }
});

$server->start();

/**
 * Converte uma requisicao Swoole em uma Symfony Request.
 */
function swooleToSymfonyRequest(SwooleRequest $r): SymfonyRequest
{
    $server  = [];
    $headers = $r->header ?? [];

    foreach (($r->server ?? []) as $key => $value) {
        $server[strtoupper($key)] = $value;
    }
    foreach ($headers as $key => $value) {
        $server['HTTP_'.strtoupper(str_replace('-', '_', $key))] = $value;
    }

    // Content-Type / Content-Length sao lidos sem prefixo HTTP_ pelo Symfony.
    if (isset($headers['content-type'])) {
        $server['CONTENT_TYPE'] = $headers['content-type'];
    }
    if (isset($headers['content-length'])) {
        $server['CONTENT_LENGTH'] = $headers['content-length'];
    }

    $request = new SymfonyRequest(
        $r->get    ?? [],
        $r->post   ?? [],
        [],
        $r->cookie ?? [],
        $r->files  ?? [],
        $server,
        $r->rawContent() ?: null
    );

    $request->setMethod($server['REQUEST_METHOD'] ?? 'GET');

    return $request;
}
