---
layout: post
title: "PHP-FPM/JIT vs FrankenPHP Worker vs Swoole: um benchmark honesto com Symfony"
date: 2026-06-09 12:40:00 -0300
author: Jeferson Guedes
categories: [php, performance, devops]
tags: [php, symfony, docker, php-fpm, frankenphp, swoole, jit, opcache, traefik, benchmark]
excerpt: >-
  Montei um ambiente Docker com o MESMO mini-monólito Symfony rodando em três
  runtimes diferentes — Nginx+PHP-FPM (Opcache+JIT), FrankenPHP em Worker Mode e
  Swoole — e medi CPU, leitura e escrita. Spoiler: o vencedor depende totalmente
  do tipo de carga, e a contagem de workers engana mais que o runtime.
image: /assets/img/benchmark-php-runtimes.png
---

> **TL;DR** — Para CPU puro, o que importa é o JIT, e FPM empata com FrankenPHP.
> Para leitura, os runtimes persistentes voam (até **3,5×** o FPM). Para escrita,
> FrankenPHP lidera, mas o Swoole expõe contenção de conexão. E o erro mais comum
> em benchmark de runtime é comparar configurações com **número de workers diferente**.

## Por que fiz isso

Toda discussão sobre "PHP moderno é rápido" esbarra na mesma confusão: as pessoas
comparam **runtimes** (FPM, FrankenPHP, Swoole) mas mudam dezenas de variáveis ao
mesmo tempo — versão do PHP, JIT ligado/desligado, número de processos, framework,
banco. O resultado é inconclusivo.

A proposta aqui foi isolar a variável **runtime**: o **mesmo** código Symfony, o
**mesmo** PHP 8.4 com Opcache + JIT, o **mesmo** MySQL 8, mudando só *como o PHP é
executado*.

## Os três cenários

| # | Arquitetura | Stack | Porta |
|---|-------------|-------|-------|
| 1 | Clássico tunado | **Nginx + PHP-FPM** (Opcache + JIT `1255`, Unix socket) | 8081 |
| 2 | Moderno worker | **Traefik + FrankenPHP** (Worker Mode) | 8182* |
| 3 | Assíncrono | **Traefik + Swoole** | 8083 |

<small>* A `:8082` original estava ocupada por um processo local na minha máquina, então o FrankenPHP foi publicado na 8182.</small>

Todos compartilham o mesmo `app/` Symfony — o que muda é só a imagem Docker e o
modo de execução. Endpoints de teste:

- `GET /bench/cpu-bound` — contagem de primos + hashes bcrypt (CPU puro, sensível ao JIT)
- `GET /bench/io-read` — `SELECT` dos 20 registros mais recentes → `JsonResponse`
- `GET /bench/io-write` — `INSERT` + `flush()`, devolve o ID gerado

## A pegadinha que quase invalidou tudo

Na **primeira** rodada, os workers estavam desbalanceados: FPM com `pm.max_children=16`
e FrankenPHP/Swoole com 4 workers cada. Resultado "de fábrica":

| Endpoint | FPM (16w) | FrankenPHP (4w) | Swoole (4w) |
|----------|----------:|----------------:|------------:|
| io-read   | 1.654 | 4.085 | 4.099 |
| io-write  | **919** | 680 | 644 |
| cpu-bound | **27** | 21 | 11 |

Parece que o FPM "ganha" em escrita e CPU — mas isso é **viés de paralelismo**: com
64 conexões batendo numa tarefa de CPU, o FPM processa 16 em paralelo e os outros só
4. Não é o runtime, é a contagem de processos.

> **Lição:** num benchmark de runtime, iguale o número de workers. Senão você está
> medindo `pm.max_children`, não a arquitetura.

## O comparativo justo (4 workers em todos)

Baixei o FPM para `pm.max_children=4` e repeti — 64 conexões concorrentes, 12s por
medição, com warmup descartado:

### Throughput (req/s — maior é melhor)

| Endpoint | FPM+JIT | FrankenPHP | Swoole | Vencedor |
|----------|--------:|-----------:|-------:|----------|
| **cpu-bound** | 19,7 | 19,7 | 14,4 | 🟰 empate FPM/FrankenPHP |
| **io-read**   | 1.144 | 3.262 | **4.066** | 🟦 Swoole |
| **io-write**  | 268 | **513** | 230 | 🟩 FrankenPHP |

### Latência p99 (ms — menor é melhor)

| Endpoint | FPM+JIT | FrankenPHP | Swoole |
|----------|--------:|-----------:|-------:|
| cpu-bound | 3.467 | **3.334** | 9.205 |
| io-read   | 205 | 210 | **92** |
| io-write  | 506 | **364** | 1.182 |

### Speedup vs FPM

| | FrankenPHP | Swoole |
|---|---:|---:|
| cpu-bound | 1,00× | 0,73× |
| io-read | 2,85× | **3,55×** |
| io-write | **1,91×** | 0,86× |

## O que os números dizem

**1. CPU puro → é o JIT, e ele empata.**
FPM e FrankenPHP têm o mesmo JIT (`opcache.jit=1255`, buffer 128M) e deram
**exatamente** o mesmo número (19,7 req/s). Faz sentido: a economia de *boot* do
worker não ajuda quando o tempo é gasto **computando**, não inicializando. O Swoole
ficou atrás por overhead do seu reactor no caminho síncrono.

**2. Leitura → runtimes persistentes voam.**
Swoole **3,55×** e FrankenPHP **2,85×** o FPM. Aqui o que domina é o reúso do
container de injeção de dependência do Symfony e o *zero bootstrap* por request — o
FPM paga esse pedágio em toda requisição. Swoole ainda leva o melhor p99 (92ms).

**3. Escrita → FrankenPHP brilha, Swoole sofre.**
FrankenPHP fez **1,9×** o FPM e teve o melhor p99. Já o Swoole **degradou**
(p99 de **1.182ms**) — é o sintoma clássico de **contenção nas conexões persistentes**
com poucos workers no caminho de escrita. Foi exatamente o que o teste de `io-write`
foi desenhado pra expor: no FPM a conexão abre/fecha por request; no
Swoole/FrankenPHP ela persiste por worker e precisa ser gerenciada.

## Tropeços de setup que valem registrar

Montar isso em PHP 8.4 + Docker novo (2026) rendeu alguns perrengues que podem te
poupar tempo:

- **Composer bloqueando por advisory.** O Composer atual recusa versões com
  *security advisory* na resolução. Vários advisories recentes do Symfony cobrem
  toda a linha 7.x — desliguei com `config.policy.advisories.block=false` (PoC local).
- **Extensão `zip` faltando.** Sem `zip`/`unzip`, o `composer install` falha ao
  extrair os pacotes. Adicionei `zip` via `install-php-extensions` nas três imagens.
- **`symfony/var-exporter` 8.x vs Doctrine ORM 3.** O ORM precisa do `LazyGhost` da
  `var-exporter` 6.4/7; a 8.x removeu o trait. Fixei em `7.2.*`.
- **Controller sem `controller.service_arguments`.** Controller "plano" (sem
  `AbstractController`) não recebe injeção em argumentos de action — precisei taggear
  no `services.yaml`.
- **Traefik + Docker socket.** O daemon novo exige API ≥ 1.40 e o provider Docker do
  Traefik v3.2 negocia 1.24 → quebra. Troquei para o **file provider** (config
  estática), roteando por nome de container. Mais robusto e sem depender do socket.

## Como reproduzir

```bash
# subir o ambiente
docker compose up -d --build

# rodar a matriz (Python + aiohttp) e salvar CSV/JSON
./.venv/bin/python bench/loadtest.py -d 12 -c 64 -w 4

# gráficos comparativos no notebook
./.venv/bin/jupyter lab bench/benchmark.ipynb
```

## Veredito

Não existe "runtime mais rápido". Existe **runtime certo para a carga**:

- **App I/O-bound de leitura** (APIs, dashboards): Swoole ou FrankenPHP — ganho real de 3×.
- **Escrita concorrente**: FrankenPHP, com atenção ao *pooling*; Swoole exige tunar workers × conexões.
- **CPU-bound**: ligue o JIT e durma tranquilo — FPM clássico segura o tranco igual.

O ganho dos runtimes modernos é **arquitetural** (estado persistente, sem bootstrap),
não mágico. Onde não há bootstrap a economizar, o bom e velho FPM com JIT continua
competitivo — e muito mais simples de operar.

---

*Ambiente: PHP 8.4, Symfony 7.2, Doctrine ORM 3, MySQL 8, Docker 29.4 no macOS.
Carga: 64 conexões, 12s/medição, 4 workers por runtime. Números são de uma única
rodada local — para conclusões de produção, rode várias vezes e descarte a primeira.*
