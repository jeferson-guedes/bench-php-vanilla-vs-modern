-- Script wrk para estressar /bench/io-write com POST + corpo JSON real.
-- Uso:
--   wrk -t8 -c100 -d30s -s bench/post.lua "http://localhost:8083/bench/io-write"
--
-- (O modo padrao do run-bench.sh usa GET, que ja gera payload aleatorio no
--  controller. Use este script quando quiser medir o caminho POST + json_decode.)

wrk.method = "POST"
wrk.headers["Content-Type"] = "application/json"

local counter = 0
request = function()
  counter = counter + 1
  wrk.body = string.format('{"payload":"carga-wrk-%d"}', counter)
  return wrk.format()
end
