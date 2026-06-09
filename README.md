# Benchmark de Runtimes PHP — Symfony (FPM/JIT vs FrankenPHP Worker vs Swoole)

PoC local com Docker Compose para comparar **3 arquiteturas de execução do PHP**
rodando **o mesmo mini-monólito Symfony**, contra um **MySQL 8** compartilhado.

| # | Cenário | Stack | URL externa |
|---|---------|-------|-------------|
| 1 | Clássico tunado | **Nginx + PHP-FPM** (Opcache + JIT `1255`, Unix socket) | http://localhost:8081 |
| 2 | Moderno worker | **Traefik + FrankenPHP** (Worker Mode) | http://localhost:8182 |
| 3 | Assíncrono | **Traefik + Swoole** | http://localhost:8083 |
| — | Banco | MySQL 8 | localhost:3306 |
| — | Dashboard | Traefik | http://localhost:8180 |

Os 3 cenários compartilham o código em [`app/`](app/) — o que muda é **apenas o runtime**,
tornando a comparação justa.

> A `:8082` original pode estar ocupada no host (foi o meu caso) — por isso o FrankenPHP
> é publicado em **8182** e o dashboard do Traefik em **8180**. Ajuste em `docker-compose.yml`
> se quiser outras portas.

---

## 📊 Resultados

Ambiente: **PHP 8.4, Symfony 7.2, Doctrine ORM 3, MySQL 8, Docker 29.4 (macOS)**.
Carga: **64 conexões concorrentes, 12s por medição, warmup descartado, 4 workers por runtime**
(igualados para um comparativo justo — veja a ressalva abaixo). Números de uma única rodada local.

### Throughput — req/s (maior é melhor)

| Endpoint | FPM + JIT | FrankenPHP | Swoole | Vencedor |
|----------|----------:|-----------:|-------:|----------|
| `cpu-bound` | 19,7 | 19,7 | 14,4 | 🟰 empate FPM / FrankenPHP |
| `io-read`   | 1.144 | 3.262 | **4.066** | 🟦 Swoole |
| `io-write`  | 268 | **513** | 230 | 🟩 FrankenPHP |

### Latência p99 — ms (menor é melhor)

| Endpoint | FPM + JIT | FrankenPHP | Swoole |
|----------|----------:|-----------:|-------:|
| `cpu-bound` | 3.467 | **3.334** | 9.205 |
| `io-read`   | 205 | 210 | **92** |
| `io-write`  | 506 | **364** | 1.182 |

### Speedup vs FPM (throughput)

| | FrankenPHP | Swoole |
|---|---:|---:|
| `cpu-bound` | 1,00× | 0,73× |
| `io-read` | 2,85× | **3,55×** |
| `io-write` | **1,91×** | 0,86× |

### O que esses números dizem

1. **CPU puro → o JIT é o que importa, e empata.** FPM e FrankenPHP têm o mesmo JIT
   e deram exatamente o mesmo resultado. A economia de *boot* do worker não ajuda quando
   o tempo é gasto computando, não inicializando. Swoole ficou atrás (overhead do reactor
   no caminho síncrono).
2. **Leitura → runtimes persistentes voam.** Swoole **3,55×** e FrankenPHP **2,85×** o FPM.
   Domina o reúso do container de DI do Symfony + zero bootstrap por request. Swoole tem o
   melhor p99 (92ms).
3. **Escrita → FrankenPHP lidera (1,9×), Swoole sofre.** O p99 do Swoole na escrita estourou
   (**1.182ms**) — contenção clássica de conexões persistentes com poucos workers, justamente
   o que o `io-write` foi feito pra expor.

> ⚠️ **Ressalva metodológica — iguale os workers.** Na primeira rodada o FPM rodava com 16
> workers e os outros com 4, e o FPM "vencia" CPU e escrita. Isso era **viés de paralelismo**,
> não do runtime. Os números acima são com **4 workers em todos**. Sempre normalize isso.

**Veredito:** não existe "runtime mais rápido", existe runtime certo pra carga. Leitura I/O-bound
→ Swoole/FrankenPHP (ganho real de ~3×). Escrita concorrente → FrankenPHP (atenção ao pooling).
CPU-bound → ligue o JIT e o FPM clássico segura o tranco igual, com operação muito mais simples.

---

## Estrutura

```
benchs/
├── docker-compose.yml          # orquestra os 5 serviços + 2 do app
├── app/                        # mini-monólito Symfony (compartilhado)
│   ├── public/index.php        # entrypoint FPM + FrankenPHP (runtime via APP_RUNTIME)
│   ├── bin/swoole-server.php    # servidor HTTP dedicado do Swoole
│   ├── src/Controller/BenchController.php
│   ├── src/Entity/LogBenchmark.php
│   └── config/...
├── docker/
│   ├── fpm/        Dockerfile · php.ini (JIT) · www.conf (socket) · nginx.conf
│   ├── frankenphp/ Dockerfile · php.ini (JIT) · Caddyfile (worker)
│   └── swoole/     Dockerfile · php.ini (JIT)
└── mysql/init.sql              # cria logs_benchmark + seed de 30 linhas
```

---

## Subir o ambiente

```bash
# Build das 3 imagens + sobe tudo
docker compose up -d --build

# Acompanhar logs (ex.: ver o boot do worker do Swoole)
docker compose logs -f swoole frankenphp

# Conferir que os 3 sobem
curl -s http://localhost:8081/bench/io-read | jq    # FPM
curl -s http://localhost:8082/bench/io-read | jq    # FrankenPHP
curl -s http://localhost:8083/bench/io-read | jq    # Swoole
```

A tabela `logs_benchmark` e o seed são criados automaticamente pelo MySQL no
primeiro boot (via `mysql/init.sql`).

---

## Endpoints (iguais nos 3 cenários)

| Rota | Método | O que faz |
|------|--------|-----------|
| `/bench/cpu-bound` | GET | Conta primos + hashes Bcrypt (CPU puro, sensível ao JIT). Params: `?n=`, `?cost=`, `?hashes=` |
| `/bench/io-read`   | GET | `SELECT` dos 20 registros mais recentes → `JsonResponse` |
| `/bench/io-write`  | GET/POST | `INSERT` + `flush()`, retorna o `id`. POST aceita `{"payload":"..."}`; GET gera payload aleatório |

Cada resposta inclui `elapsed_ms` e `pid` (útil para ver o reúso de workers).

```bash
# Exemplos
curl -s "http://localhost:8081/bench/cpu-bound?n=80000&hashes=5&cost=11" | jq
curl -s    "http://localhost:8082/bench/io-write" | jq
curl -s -X POST "http://localhost:8083/bench/io-write" \
     -H 'Content-Type: application/json' -d '{"payload":"manual"}' | jq
```

---

## Testes de carga

Instale uma das ferramentas:

```bash
# macOS
brew install wrk bombardier
# Debian/Ubuntu
sudo apt-get install -y wrk        # bombardier: baixe o binário em github.com/codesenberg/bombardier
```

> Dica: rode **um cenário/endpoint por vez** para não competir por CPU.
> Entre rodadas, dê tempo ao JIT/worker "esquentar" (descarte a 1ª rodada).

### Matriz de portas

| Cenário | Porta |
|---------|-------|
| FPM     | 8081  |
| FrankenPHP | 8082 |
| Swoole  | 8083  |

### A) `wrk` — 30s, 8 threads, 100 conexões

```bash
# ---- CPU-bound ----
wrk -t8 -c100 -d30s "http://localhost:8081/bench/cpu-bound?n=50000"   # FPM
wrk -t8 -c100 -d30s "http://localhost:8082/bench/cpu-bound?n=50000"   # FrankenPHP
wrk -t8 -c100 -d30s "http://localhost:8083/bench/cpu-bound?n=50000"   # Swoole

# ---- IO-read ----
wrk -t8 -c100 -d30s "http://localhost:8081/bench/io-read"
wrk -t8 -c100 -d30s "http://localhost:8082/bench/io-read"
wrk -t8 -c100 -d30s "http://localhost:8083/bench/io-read"

# ---- IO-write (GET gera payload aleatório → facilita o estresse) ----
wrk -t8 -c100 -d30s "http://localhost:8081/bench/io-write"
wrk -t8 -c100 -d30s "http://localhost:8082/bench/io-write"
wrk -t8 -c100 -d30s "http://localhost:8083/bench/io-write"
```

POST com corpo JSON via `wrk` (script Lua):

```bash
cat > post.lua <<'LUA'
wrk.method = "POST"
wrk.headers["Content-Type"] = "application/json"
wrk.body   = '{"payload":"carga-wrk"}'
LUA

wrk -t8 -c100 -d30s -s post.lua "http://localhost:8083/bench/io-write"
```

### B) `bombardier` — 200k requests, 200 conexões

```bash
# CPU-bound
bombardier -c 200 -n 200000 "http://localhost:8081/bench/cpu-bound?n=50000"
bombardier -c 200 -n 200000 "http://localhost:8082/bench/cpu-bound?n=50000"
bombardier -c 200 -n 200000 "http://localhost:8083/bench/cpu-bound?n=50000"

# IO-read
bombardier -c 200 -n 200000 "http://localhost:8081/bench/io-read"
bombardier -c 200 -n 200000 "http://localhost:8082/bench/io-read"
bombardier -c 200 -n 200000 "http://localhost:8083/bench/io-read"

# IO-write (POST com corpo)
bombardier -c 200 -n 200000 -m POST \
  -H "Content-Type: application/json" -b '{"payload":"carga-bombardier"}' \
  "http://localhost:8083/bench/io-write"
```

O que olhar: **Requests/sec**, **latência p50/p99**, e erros (non-2xx).

---

## Experimento: "Too many connections"

O ponto central do `/bench/io-write` é o comportamento das conexões com o MySQL:

- **PHP-FPM**: abre/fecha conexão por request → muitas conexões transitórias, mas curtas.
- **FrankenPHP / Swoole**: cada **worker** mantém um Kernel + conexão **persistente**.
  Nº de conexões ≈ nº de workers (`FRANKENPHP_NUM_WORKERS` / `SWOOLE_WORKERS`).

Para forçar o erro e comparar:

```bash
# 1) Reduza o limite do MySQL
#    edite docker-compose.yml -> mysql.command: --max-connections=25
docker compose up -d mysql

# 2) Aumente os workers do FPM (mais conexões simultâneas)
#    docker/fpm/www.conf -> pm.max_children = 64 ; docker compose up -d --build fpm

# 3) Estresse o io-write e observe
wrk -t8 -c200 -d30s "http://localhost:8081/bench/io-write"   # FPM tende a estourar antes
wrk -t8 -c200 -d30s "http://localhost:8083/bench/io-write"   # Swoole limitado a SWOOLE_WORKERS

# Monitore as conexões abertas:
watch -n1 'docker compose exec -T mysql mysql -uroot -proot \
  -e "SHOW STATUS LIKE \"Threads_connected\";"'
```

Conclusão esperada: FPM (sem pooling) sofre primeiro sob alta concorrência;
Swoole/FrankenPHP limitam naturalmente as conexões ao nº de workers — desde que
você dimensione `workers ≤ max_connections`.

---

## Notas técnicas e ajustes

- **PHP 8.4** nos três cenários. **JIT `opcache.jit=1255` + `jit_buffer_size=128M`** e
  `opcache.validate_timestamps=0` em todos os `php.ini`.
- **FPM ↔ Nginx via Unix socket**: o socket vive no volume `phpsocket`, montado nos
  dois containers (`/var/run/php/php-fpm.sock`).
- **FrankenPHP Worker Mode** é ativado por `APP_RUNTIME=Runtime\FrankenPhpSymfony\Runtime`
  (env) + bloco `worker` no `Caddyfile`. O pacote `runtime/frankenphp-symfony` está no
  `composer.json`.
- **Swoole** usa um servidor dedicado (`app/bin/swoole-server.php`) que boota o Kernel
  uma vez por worker. Alternativa "oficial": `runtime/swoole` com
  `APP_RUNTIME=Runtime\Swoole\Runtime` no `public/index.php`.
- **Doctrine**: `server_version` fixo evita conexão no boot/warmup; `$em->clear()` após
  cada request mantém a identity map enxuta nos runtimes persistentes.
- **Versões dos pacotes** (`runtime/frankenphp-symfony`, Symfony 7.2, Doctrine ORM 3) podem
  precisar de ajuste fino conforme disponibilidade no Packagist no momento do build —
  o `composer install` roda dentro de cada imagem.

## Derrubar tudo

```bash
docker compose down            # mantém o volume do MySQL
docker compose down -v         # remove também os dados do MySQL
```
