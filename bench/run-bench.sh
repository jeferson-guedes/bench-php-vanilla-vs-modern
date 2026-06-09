#!/usr/bin/env bash
#
# run-bench.sh - Orquestrador de teste de estresse para os 3 cenarios PHP.
#
# Roda a matriz (cenario x endpoint) de forma SEQUENCIAL (um por vez, para nao
# competir por CPU), com warmup descartado (JIT/worker esquentam antes de medir),
# faz o parsing automatico e gera:
#   - tabela comparativa no terminal (vencedor por endpoint)
#   - CSV em bench/results/bench_<timestamp>.csv
#
# Suporta bombardier (preferido) ou wrk. Detecta automaticamente.
#
# Uso:
#   ./bench/run-bench.sh                          # tudo, defaults
#   DURATION=20 CONN=150 ./bench/run-bench.sh     # via env
#   ./bench/run-bench.sh -d 20 -c 150 -w 5        # via flags
#   ./bench/run-bench.sh -e io-read,io-write      # so alguns endpoints
#   ./bench/run-bench.sh -s fpm,swoole            # so alguns cenarios
#
set -euo pipefail

# ----------------------------- Config padrao --------------------------------
DURATION="${DURATION:-30}"      # segundos por medicao
CONN="${CONN:-100}"             # conexoes concorrentes
THREADS="${THREADS:-8}"         # threads (so wrk)
WARMUP="${WARMUP:-5}"           # segundos de warmup descartado por alvo
HOST="${HOST:-localhost}"
TOOL="${TOOL:-auto}"            # auto | bombardier | wrk

# Cenario -> porta externa (ver docker-compose.yml)
declare -A PORTS=(
  [fpm]=8081
  [frankenphp]=8182
  [swoole]=8083
)
SCENARIOS_DEFAULT="fpm,frankenphp,swoole"
ENDPOINTS_DEFAULT="cpu-bound,io-read,io-write"

# Query string por endpoint (cpu-bound parametrizado p/ carga consistente)
declare -A QUERY=(
  [cpu-bound]="?n=50000&hashes=3&cost=10"
  [io-read]=""
  [io-write]=""   # GET gera payload aleatorio -> ideal p/ estresse sem corpo
)

SCENARIOS="$SCENARIOS_DEFAULT"
ENDPOINTS="$ENDPOINTS_DEFAULT"

# ----------------------------- Flags ----------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--duration) DURATION="$2"; shift 2;;
    -c|--conn)     CONN="$2"; shift 2;;
    -t|--threads)  THREADS="$2"; shift 2;;
    -w|--warmup)   WARMUP="$2"; shift 2;;
    -s|--scenarios) SCENARIOS="$2"; shift 2;;
    -e|--endpoints) ENDPOINTS="$2"; shift 2;;
    --tool)        TOOL="$2"; shift 2;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "Flag desconhecida: $1" >&2; exit 1;;
  esac
done

# ----------------------------- Cores -----------------------------------------
if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  CYAN=$'\033[36m'; RED=$'\033[31m'; RESET=$'\033[0m'
else
  BOLD=; DIM=; GREEN=; YELLOW=; CYAN=; RED=; RESET=
fi

# ----------------------------- Detecta ferramenta ----------------------------
if [[ "$TOOL" == "auto" ]]; then
  if command -v bombardier >/dev/null 2>&1; then TOOL="bombardier"
  elif command -v wrk >/dev/null 2>&1; then TOOL="wrk"
  else
    echo "${RED}Nenhuma ferramenta de carga encontrada.${RESET}" >&2
    echo "Instale uma: brew install bombardier  (ou)  brew install wrk" >&2
    exit 1
  fi
fi
command -v "$TOOL" >/dev/null 2>&1 || { echo "${RED}'$TOOL' nao instalado${RESET}" >&2; exit 1; }

# ----------------------------- Saida CSV -------------------------------------
RESULTS_DIR="$(cd "$(dirname "$0")" && pwd)/results"
mkdir -p "$RESULTS_DIR"
STAMP="$(date +%Y%m%d_%H%M%S)"
CSV="$RESULTS_DIR/bench_${STAMP}.csv"
echo "scenario,endpoint,tool,connections,duration_s,reqs_per_sec,latency_avg,latency_p99,non2xx,total_reqs" > "$CSV"

# ----------------------------- Helpers ---------------------------------------
url_for() { # $1=scenario $2=endpoint
  echo "http://${HOST}:${PORTS[$1]}/bench/$2${QUERY[$2]}"
}

# Executa a ferramenta e ecoa a saida bruta no stdout.
run_tool() { # $1=url $2=duration
  local url="$1" dur="$2"
  if [[ "$TOOL" == "bombardier" ]]; then
    bombardier -c "$CONN" -d "${dur}s" -l -p result "$url" 2>&1
  else
    wrk -t"$THREADS" -c"$CONN" -d"${dur}s" --latency "$url" 2>&1
  fi
}

# Parsers: recebem a saida bruta via stdin, ecoam "rps|lat_avg|lat_p99|non2xx|total"
parse_bombardier() {
  awk '
    /Reqs\/sec/      { rps=$2 }
    /Latency/ && lat==""  { lat=$2 }
    /^[[:space:]]*99%/ { p99=$2 }
    /2xx -/ {
      for (i=1;i<=NF;i++){
        if ($i ~ /^[0-9]+xx$/){ code=$i; getval=1; continue }
        if (getval && $i ~ /^[0-9]+,?$/){ v=$i; gsub(/,/,"",v); codes[code]=v; getval=0 }
      }
    }
    /others -/ {
      for (i=1;i<=NF;i++) if ($i=="others"){ o=$(i+2); gsub(/,/,"",o); others=o }
    }
    END {
      n2=(codes["1xx"]+0)+(codes["3xx"]+0)+(codes["4xx"]+0)+(codes["5xx"]+0)+(others+0)
      tot=n2+(codes["2xx"]+0)
      printf "%s|%s|%s|%d|%d", (rps==""?"0":rps), (lat==""?"0":lat), (p99==""?"0":p99), n2, tot
    }'
}

parse_wrk() {
  awk '
    /Requests\/sec:/   { rps=$2 }
    /^[[:space:]]*Latency/ && lat=="" { lat=$2 }            # Thread Stats avg
    /^[[:space:]]*99%/ { p99=$2 }
    / requests in /    { tot=$1 }
    /Non-2xx or 3xx/   { for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/) n2=$i }
    END {
      printf "%s|%s|%s|%d|%s", (rps==""?"0":rps), (lat==""?"0":lat), (p99==""?"0":p99), (n2==""?0:n2), (tot==""?"0":tot)
    }'
}

# ----------------------------- Preflight -------------------------------------
echo "${BOLD}== Benchmark de runtimes PHP ==${RESET}"
echo "Ferramenta: ${CYAN}${TOOL}${RESET} | duracao: ${DURATION}s | conexoes: ${CONN} | warmup: ${WARMUP}s"
echo "Cenarios: ${SCENARIOS} | Endpoints: ${ENDPOINTS}"
echo "CSV: ${DIM}${CSV}${RESET}"
echo

IFS=',' read -ra SC_ARR <<< "$SCENARIOS"
IFS=',' read -ra EP_ARR <<< "$ENDPOINTS"

echo "${BOLD}Health-check...${RESET}"
ACTIVE=()
for sc in "${SC_ARR[@]}"; do
  u="http://${HOST}:${PORTS[$sc]:-0}/bench/io-read"
  if [[ -z "${PORTS[$sc]:-}" ]]; then
    echo "  ${RED}skip${RESET} $sc (cenario desconhecido)"; continue
  fi
  if curl -fsS -o /dev/null --max-time 5 "$u"; then
    echo "  ${GREEN}ok${RESET}   $sc -> :${PORTS[$sc]}"
    ACTIVE+=("$sc")
  else
    echo "  ${RED}down${RESET} $sc -> :${PORTS[$sc]} (pulando)"
  fi
done
echo
[[ ${#ACTIVE[@]} -eq 0 ]] && { echo "${RED}Nenhum cenario respondendo. Rode: docker compose up -d --build${RESET}"; exit 1; }

# ----------------------------- Loop principal --------------------------------
# Guarda resultados em memoria para a tabela final: RES["endpoint|scenario"]="rps|lat|p99|n2|tot"
declare -A RES

for ep in "${EP_ARR[@]}"; do
  for sc in "${ACTIVE[@]}"; do
    url="$(url_for "$sc" "$ep")"
    printf "%s>> %-10s | %-10s%s  %s\n" "$BOLD" "$ep" "$sc" "$RESET" "${DIM}${url}${RESET}"

    # Warmup descartado
    if [[ "$WARMUP" -gt 0 ]]; then
      printf "   warmup %ss... " "$WARMUP"
      run_tool "$url" "$WARMUP" >/dev/null 2>&1 || true
      echo "ok"
    fi

    # Medicao
    raw="$(run_tool "$url" "$DURATION")"
    if [[ "$TOOL" == "bombardier" ]]; then
      parsed="$(printf '%s\n' "$raw" | parse_bombardier)"
    else
      parsed="$(printf '%s\n' "$raw" | parse_wrk)"
    fi

    IFS='|' read -r rps lat p99 n2 tot <<< "$parsed"
    RES["$ep|$sc"]="$parsed"

    printf "   ${GREEN}%s req/s${RESET}  | lat avg %s | p99 %s | non2xx %s | total %s\n\n" \
      "$rps" "$lat" "$p99" "$n2" "$tot"

    echo "$sc,$ep,$TOOL,$CONN,$DURATION,$rps,$lat,$p99,$n2,$tot" >> "$CSV"

    sleep 1  # respiro entre alvos
  done
done

# ----------------------------- Relatorio final -------------------------------
echo "${BOLD}========================= RESULTADO COMPARATIVO =========================${RESET}"
for ep in "${EP_ARR[@]}"; do
  echo
  echo "${BOLD}${CYAN}Endpoint: /bench/${ep}${RESET}"
  printf "  %-12s %14s %12s %12s %8s\n" "cenario" "req/s" "lat_avg" "lat_p99" "non2xx"
  printf "  %-12s %14s %12s %12s %8s\n" "------------" "--------------" "------------" "------------" "--------"

  best_sc=""; best_rps=-1
  for sc in "${ACTIVE[@]}"; do
    val="${RES["$ep|$sc"]:-}"; [[ -z "$val" ]] && continue
    IFS='|' read -r rps lat p99 n2 tot <<< "$val"
    # rps pode ter sufixo (ex.: "1.23k" no wrk) -> normaliza p/ comparar
    num="$(awk -v v="$rps" 'BEGIN{ if(v ~ /k$/){sub(/k$/,"",v); v=v*1000} else if(v ~ /M$/){sub(/M$/,"",v); v=v*1000000}; printf "%.2f", v+0 }')"
    awk -v n="$num" -v b="$best_rps" 'BEGIN{exit !(n>b)}' && { best_rps="$num"; best_sc="$sc"; }
    printf "  %-12s %14s %12s %12s %8s\n" "$sc" "$rps" "$lat" "$p99" "$n2"
  done
  [[ -n "$best_sc" ]] && echo "  ${GREEN}-> mais rapido (req/s): ${BOLD}${best_sc}${RESET}"
done

echo
echo "${BOLD}CSV salvo em:${RESET} $CSV"
echo "${DIM}Dica: rode 2-3 vezes e descarte a 1a; veja o experimento de 'Too many connections' no README.${RESET}"
