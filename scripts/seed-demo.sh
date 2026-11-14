#!/usr/bin/env bash
# Seeds demo data into a ccinnredis-it-* container (used by scripts/redis-up.sh).
#
#   scripts/seed-demo.sh demo    <container> <port> [redis-cli auth args]   # every data type, version-aware
#   scripts/seed-demo.sh json    <container> <port>                          # RedisJSON documents
#   scripts/seed-demo.sh large   <container> <port>                          # 200,000 keys across prefixes
#   scripts/seed-demo.sh cluster <container> <port>                          # data spread over cluster slots
#   scripts/seed-demo.sh proxy   <container> <port>                          # data written through twemproxy
set -euo pipefail

MODE="${1:?mode}"
CONTAINER="${2:?container}"
PORT="${3:?port}"
shift 3
AUTH=("$@")

cli() { docker exec -i "$CONTAINER" redis-cli -p "$PORT" ${AUTH[@]+"${AUTH[@]}"} "$@"; }
pipe() { docker exec -i "$CONTAINER" redis-cli -p "$PORT" ${AUTH[@]+"${AUTH[@]}"} --pipe >/dev/null; }

# awk helper: out("CMD|arg|arg") prints the command as RESP (arguments may contain spaces, not '|').
AWK_RESP='function out(line,   n, parts, i, s) { n = split(line, parts, "|"); s = "*" n "\r\n"; for (i = 1; i <= n; i++) s = s "$" length(parts[i]) "\r\n" parts[i] "\r\n"; printf "%s", s }'

version_at_least() { # major minor
  local version major minor
  version="$(cli INFO server 2>/dev/null | tr -d '\r' | awk -F: '/^redis_version:/{print $2}')"
  major="${version%%.*}"
  minor="${version#*.}"; minor="${minor%%.*}"
  [[ -n "$major" ]] || return 1
  (( major > $1 || (major == $1 && minor >= $2) ))
}

seed_demo() {
  local streams=0 geo=0 hll=0
  if version_at_least 5 0; then streams=1; fi
  if version_at_least 3 2; then geo=1; fi
  if version_at_least 2 8; then hll=1; fi
  awk -v streams="$streams" -v geo="$geo" -v hll="$hll" "$AWK_RESP"'
  BEGIN {
    # Idempotent: aggregates are rebuilt from scratch on every run.
    out("DEL|demo:hash:big|demo:list:queue|demo:list:big|demo:set:members|demo:zset:leaderboard|demo:stream:events|demo:hll:visitors|demo:geo:cities")
    out("SET|demo:string:hello|Hello, CcinnRedis!")
    out("SET|demo:string:json|{\"id\":42,\"name\":\"Ada\",\"tags\":[\"redis\",\"swift\"],\"active\":true,\"score\":98.5}")
    out("SET|demo:string:counter|42")
    out("SET|demo:string:session|token-7f3a9c")
    out("EXPIRE|demo:string:session|86400")
    out("SET|demo:string:long|" sprintf("%3000s", "") "end")
    out("HMSET|demo:hash:user:1|name|Ada Lovelace|email|ada@example.com|city|London|age|36|plan|pro")
    out("HMSET|demo:hash:user:2|name|Alan Turing|email|alan@example.com|city|Wilmslow|age|41|plan|free")
    for (i = 0; i < 2000; i++) out("HSET|demo:hash:big|field:" i "|value-" i)
    for (i = 0; i < 50; i++) out("RPUSH|demo:list:queue|job-" i)
    for (i = 0; i < 10000; i++) out("RPUSH|demo:list:big|item-" i)
    out("SADD|demo:set:tags|redis|swift|macos|cluster|sentinel|proxy|resp3|valkey|streams|json")
    for (i = 0; i < 300; i++) out("SADD|demo:set:members|member-" i)
    for (i = 0; i < 100; i++) out("ZADD|demo:zset:leaderboard|" (i * 37 % 1000) "|player-" i)
    out("ZADD|demo:zset:weights|1.5|alpha|2.25|beta|-3|gamma|1e6|delta")
    out("SETBIT|demo:bitmap:active|7|1")
    out("SETBIT|demo:bitmap:active|42|1")
    if (hll) out("PFADD|demo:hll:visitors|ada|alan|grace|linus|ken")
    if (geo) out("GEOADD|demo:geo:cities|101.6869|3.1390|Kuala Lumpur|103.8198|1.3521|Singapore|100.5018|13.7563|Bangkok")
    if (streams) {
      for (i = 0; i < 500; i++) out("XADD|demo:stream:events|*|type|" (i % 3 == 0 ? "click" : (i % 3 == 1 ? "view" : "buy")) "|user|user-" (i % 25) "|amount|" i)
      out("XGROUP|CREATE|demo:stream:events|analytics|0")
      out("XGROUP|CREATE|demo:stream:events|billing|$")
      out("XREADGROUP|GROUP|analytics|worker-1|COUNT|20|STREAMS|demo:stream:events|>")
      out("XREADGROUP|GROUP|analytics|worker-2|COUNT|7|STREAMS|demo:stream:events|>")
    }
  }' | pipe
  cli SET "demo:string:unicode" "吉隆坡 Kuala Lumpur 🇲🇾 — ünïcødé" >/dev/null
  printf '\x00\x01\x02\xff\xfeCcinn\x7f' | cli -x SET demo:string:binary >/dev/null
  cli -n 1 SET db1:greeting hello-from-db1 >/dev/null 2>&1 || true
  cli -n 1 HSET db1:hash field value >/dev/null 2>&1 || true
}

seed_json() {
  cli JSON.SET demo:json:product:1 . '{"sku":"CR-001","name":"CcinnRedis T-shirt","price":19.9,"sizes":["S","M","L"],"stock":{"kl":12,"sg":4}}' >/dev/null
  cli JSON.SET demo:json:config . '{"feature_flags":{"resp3":true,"cluster":true},"limits":{"scan":1000}}' >/dev/null
}

seed_large() {
  awk "$AWK_RESP"'
  BEGIN {
    srand(7)
    split("home product search cart account", sections, " ")
    split("my sg id th vn", regions, " ")
    for (i = 0; i < 40000; i++) out("HMSET|user:" i ":profile|name|user-" i "|country|" regions[i % 5 + 1] "|visits|" (i % 97))
    for (i = 0; i < 40000; i++) { out("SET|session:" sprintf("%08x", i * 2654435761 % 4294967296) "|uid-" i); if (i % 4 == 0) out("EXPIRE|session:" sprintf("%08x", i * 2654435761 % 4294967296) "|" (3600 + i)) }
    for (i = 0; i < 60000; i++) out("SET|cache:page:" sections[i % 5 + 1] ":" i "|<html>page " i "</html>")
    for (i = 0; i < 40000; i++) out("SET|order:" regions[i % 5 + 1] ":" (2020 + i % 6) ":" i "|{\"id\":" i ",\"total\":" (i % 500) "}")
    for (i = 0; i < 14000; i++) out("SET|metrics:2026-11-" sprintf("%02d", i % 14 + 1) ":" i "|" (i * 13 % 1000))
    for (i = 0; i < 3000; i++) out("SADD|tags:" i "|a|b|c|tag-" (i % 40))
    for (i = 0; i < 2500; i++) out("RPUSH|queue:jobs:" i "|j1|j2|j3")
    for (i = 0; i < 500; i++) out("ZADD|leaderboard:game:" i "|1|ada|2|alan|3|grace")
  }' | pipe
}

seed_cluster() {
  {
    for i in $(seq 0 1999); do echo "SET cluster:key:$i value-$i"; done
    for i in $(seq 0 199); do echo "HSET cluster:user:$i name user-$i city kl"; done
    for i in $(seq 0 49); do echo "RPUSH cluster:queue:$i a b c"; done
    for i in $(seq 0 49); do echo "SADD cluster:set:$i x y z"; done
    for i in $(seq 0 49); do echo "ZADD cluster:zset:$i 1 a 2 b"; done
    for i in $(seq 0 99); do echo "XADD cluster:stream:events * n $i"; done
    echo "SET {user:1000}:profile ada"
    echo "SET {user:1000}:settings dark"
  } | docker exec -i "$CONTAINER" redis-cli -c -p "$PORT" >/dev/null
}

seed_proxy() {
  {
    for i in $(seq 0 499); do echo "SET proxy:key:$i value-$i"; done
    for i in $(seq 0 49); do echo "HSET proxy:hash:$i field value-$i"; done
    for i in $(seq 0 19); do echo "RPUSH proxy:list:$i a b c"; done
    echo "SET demo:string:hello Hello-through-twemproxy"
    echo "ZADD proxy:zset 1 a 2 b 3 c"
    echo "SADD proxy:set a b c"
  } | docker exec -i "$CONTAINER" redis-cli -h ccinnredis-it-twemproxy -p 6380 >/dev/null
}

case "$MODE" in
  demo) seed_demo ;;
  json) seed_json ;;
  large) seed_large ;;
  cluster) seed_cluster ;;
  proxy) seed_proxy ;;
  *) echo "unknown mode $MODE" >&2; exit 1 ;;
esac
