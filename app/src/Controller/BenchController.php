<?php

namespace App\Controller;

use App\Entity\LogBenchmark;
use Doctrine\ORM\EntityManagerInterface;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\Routing\Attribute\Route;

class BenchController
{
    /**
     * /bench/cpu-bound -> Teste de processamento puro (sensivel ao JIT).
     *
     * Faz contagem de primos por divisao (loop quente, ideal para o JIT) +
     * um numero controlado de hashes Bcrypt (custo dominado por libcrypt, nao pelo JIT).
     *
     * Parametros opcionais:
     *   ?n=50000     -> limite superior para a contagem de primos (1000..500000)
     *   ?cost=10     -> custo do bcrypt (4..13)
     *   ?hashes=3    -> quantidade de hashes bcrypt
     */
    #[Route('/bench/cpu-bound', name: 'bench_cpu', methods: ['GET'])]
    public function cpuBound(Request $request): JsonResponse
    {
        $limit  = max(1000, min(500000, (int) $request->query->get('n', 50000)));
        $cost   = max(4, min(13, (int) $request->query->get('cost', 10)));
        $hashes = max(0, min(50, (int) $request->query->get('hashes', 3)));

        $start = hrtime(true);

        // ---- CPU bound 1: contagem de primos (divisao por tentativa) ----
        $primeCount = 0;
        for ($i = 2; $i <= $limit; $i++) {
            $isPrime = true;
            for ($j = 2; $j * $j <= $i; $j++) {
                if ($i % $j === 0) {
                    $isPrime = false;
                    break;
                }
            }
            if ($isPrime) {
                $primeCount++;
            }
        }

        // ---- CPU bound 2: hashes bcrypt de custo controlado ----
        $lastHash = null;
        for ($h = 0; $h < $hashes; $h++) {
            $lastHash = password_hash('benchmark-payload-'.$h, PASSWORD_BCRYPT, ['cost' => $cost]);
        }

        $elapsedMs = (hrtime(true) - $start) / 1_000_000;

        return new JsonResponse([
            'endpoint'      => 'cpu-bound',
            'primes_up_to'  => $limit,
            'prime_count'   => $primeCount,
            'bcrypt_cost'   => $cost,
            'bcrypt_hashes' => $hashes,
            'sample_hash'   => $lastHash,
            'elapsed_ms'    => round($elapsedMs, 3),
            'pid'           => getmypid(),
        ]);
    }

    /**
     * /bench/io-read -> Leitura simples: SELECT dos 20 registros mais recentes.
     *
     * Objetivo: medir reaproveitamento do container de DI + ORM em requisicoes
     * concorrentes de leitura.
     */
    #[Route('/bench/io-read', name: 'bench_io_read', methods: ['GET'])]
    public function ioRead(EntityManagerInterface $em): JsonResponse
    {
        $start = hrtime(true);

        /** @var LogBenchmark[] $rows */
        $rows = $em->getRepository(LogBenchmark::class)
            ->findBy([], ['id' => 'DESC'], 20);

        $items = array_map(static fn (LogBenchmark $log): array => [
            'id'        => $log->getId(),
            'payload'   => $log->getPayload(),
            'criado_em' => $log->getCriadoEm()->format(\DATE_ATOM),
        ], $rows);

        // Em runtimes persistentes, limpar a identity map evita crescimento de memoria.
        $em->clear();

        $elapsedMs = (hrtime(true) - $start) / 1_000_000;

        return new JsonResponse([
            'endpoint'   => 'io-read',
            'count'      => count($items),
            'items'      => $items,
            'elapsed_ms' => round($elapsedMs, 3),
            'pid'        => getmypid(),
        ]);
    }

    /**
     * /bench/io-write -> Escrita: INSERT + flush, retorna o ID gerado.
     *
     * Aceita POST com JSON {"payload": "..."} ou GET (gera payload aleatorio),
     * para facilitar o estresse com ferramentas que so disparam GET.
     *
     * Objetivo: observar concorrencia de conexoes com o MySQL.
     *   - PHP-FPM: conexao abre/fecha por request.
     *   - Swoole/FrankenPHP: conexao persiste por worker (pooling/estado) -> cuidado com
     *     "Too many connections" ao escalar workers x max_connections do MySQL.
     */
    #[Route('/bench/io-write', name: 'bench_io_write', methods: ['GET', 'POST'])]
    public function ioWrite(Request $request, EntityManagerInterface $em): JsonResponse
    {
        $start = hrtime(true);

        $payload = null;
        if ($request->isMethod('POST')) {
            $body = json_decode($request->getContent() ?: '[]', true);
            if (is_array($body) && isset($body['payload'])) {
                $payload = (string) $body['payload'];
            }
        }
        if ($payload === null || $payload === '') {
            $payload = 'auto-'.bin2hex(random_bytes(16));
        }

        $log = new LogBenchmark();
        $log->setPayload($payload);
        $log->setCriadoEm(new \DateTimeImmutable());

        $em->persist($log);
        $em->flush();

        $id = $log->getId();

        // Mantem a identity map enxuta entre requests em runtimes persistentes.
        $em->clear();

        $elapsedMs = (hrtime(true) - $start) / 1_000_000;

        return new JsonResponse([
            'endpoint'   => 'io-write',
            'id'         => $id,
            'payload'    => $payload,
            'elapsed_ms' => round($elapsedMs, 3),
            'pid'        => getmypid(),
        ], Response::HTTP_CREATED);
    }
}
