#!/usr/bin/env bash
# Starts the CcinnRedis integration matrix in Docker and seeds demo data.
#
#   scripts/redis-up.sh                 # everything
#   scripts/redis-up.sh standalone      # one or more groups: standalone auth tls stack cluster sentinel proxy large
#
# Containers are named ccinnredis-it-* and bound to 127.0.0.1 ports 17000–17999 only.
# Run the integration tests afterwards with:  CCINNREDIS_IT=1 swift test --filter IntegrationTests
#
# Ports
#   17028 Redis 2.8      17032 Redis 3.2      17040 Redis 4.0      17050 Redis 5.0 (requirepass)
#   17062 Redis 6.2 (ACL user ccinn)          17072 Redis 7.2 (200k keys)          17074 Redis 7.4
#   17082 Redis 8.2      17088 Valkey 8       17095 redis-stack 7.4 (modules)      17076 Redis 7.2 TLS
#   17101-17106 Cluster (3 masters + 3 replicas)        17301 master, 17302 replica, 17311-17313 sentinels
#   17201 twemproxy      17202 Envoy redis proxy
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NET="ccinnredis-it-net"
SEED="$ROOT/scripts/seed-demo.sh"
GROUPS_REQUESTED=("$@")
if [[ ${#GROUPS_REQUESTED[@]} -eq 0 ]]; then
  GROUPS_REQUESTED=(standalone auth tls stack cluster sentinel proxy large)
fi

wants() {
  local group
  for group in ${GROUPS_REQUESTED[@]+"${GROUPS_REQUESTED[@]}"}; do
    [[ "$group" == "$1" || "$group" == "all" ]] && return 0
  done
  return 1
}

log() { echo "[redis-up] $*" >&2; }

is_running() { docker ps --format '{{.Names}}' | grep -qx "$1"; }

ensure_network() {
  docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null
}

# run_redis <name> <image> <host-port> [redis-server args...]
run_redis() {
  local name="$1" image="$2" port="$3"
  shift 3
  if is_running "$name"; then return 0; fi
  docker rm -f "$name" >/dev/null 2>&1 || true
  local protected=(--protected-mode no)
  [[ "$image" == *":2.8" ]] && protected=() # protected-mode arrived in 3.2
  docker run -d --name "$name" --network "$NET" -p "127.0.0.1:${port}:6379" "$image" \
    redis-server --port 6379 --bind 0.0.0.0 ${protected[@]+"${protected[@]}"} --save "" --appendonly no "$@" >/dev/null
  log "started $name ($image) on 127.0.0.1:$port"
}

wait_ping() {
  local name="$1" port="$2"
  shift 2
  local attempt
  for attempt in $(seq 1 60); do
    if docker exec "$name" redis-cli -p "$port" "$@" PING 2>/dev/null | grep -q PONG; then return 0; fi
    sleep 1
  done
  log "timed out waiting for $name:$port"
  return 1
}

ensure_network

if wants standalone; then
  if ! docker image inspect ccinnredis-it/redis:2.8 >/dev/null 2>&1; then
    log "building Redis 2.8 from source (the upstream image can no longer be unpacked)…"
    docker build -q -t ccinnredis-it/redis:2.8 "$ROOT/scripts/docker/redis-2.8" >/dev/null
  fi
  run_redis ccinnredis-it-28 ccinnredis-it/redis:2.8 17028
  run_redis ccinnredis-it-32 redis:3.2 17032
  run_redis ccinnredis-it-40 redis:4.0 17040
  run_redis ccinnredis-it-74 redis:7.4-alpine 17074
  run_redis ccinnredis-it-82 redis:8.2.9-alpine 17082
  run_redis ccinnredis-it-valkey8 valkey/valkey:8-alpine 17088
  for spec in "ccinnredis-it-28" "ccinnredis-it-32" "ccinnredis-it-40" "ccinnredis-it-74" "ccinnredis-it-82" "ccinnredis-it-valkey8"; do
    wait_ping "$spec" 6379
    "$SEED" demo "$spec" 6379
  done
fi

if wants auth; then
  run_redis ccinnredis-it-50 redis:5.0 17050 --requirepass ccinn-pass
  run_redis ccinnredis-it-62 redis:6.2-alpine 17062
  wait_ping ccinnredis-it-50 6379 -a ccinn-pass
  wait_ping ccinnredis-it-62 6379
  docker exec ccinnredis-it-62 redis-cli ACL SETUSER ccinn on '>ccinn-acl-pass' '~*' '&*' '+@all' >/dev/null
  docker exec ccinnredis-it-62 redis-cli ACL SETUSER reader on '>reader-pass' '~*' '+@read' '+@connection' '+info' '+scan' '+type' '+ttl' '+pttl' '+dbsize' >/dev/null
  "$SEED" demo ccinnredis-it-50 6379 -a ccinn-pass
  "$SEED" demo ccinnredis-it-62 6379
fi

if wants tls; then
  TLS_DIR="$ROOT/.build/it-tls"
  if [[ ! -f "$TLS_DIR/server.crt" ]]; then
    mkdir -p "$TLS_DIR"
    openssl req -x509 -newkey rsa:2048 -days 3650 -nodes -keyout "$TLS_DIR/ca.key" -out "$TLS_DIR/ca.crt" -subj "/CN=ccinnredis-it-ca" >/dev/null 2>&1
    openssl req -newkey rsa:2048 -nodes -keyout "$TLS_DIR/server.key" -out "$TLS_DIR/server.csr" -subj "/CN=localhost" >/dev/null 2>&1
    printf "subjectAltName=DNS:localhost,IP:127.0.0.1\n" > "$TLS_DIR/san.ext"
    openssl x509 -req -in "$TLS_DIR/server.csr" -CA "$TLS_DIR/ca.crt" -CAkey "$TLS_DIR/ca.key" -CAcreateserial \
      -out "$TLS_DIR/server.crt" -days 3650 -extfile "$TLS_DIR/san.ext" >/dev/null 2>&1
    chmod 644 "$TLS_DIR"/*.key
  fi
  if ! is_running ccinnredis-it-tls; then
    docker rm -f ccinnredis-it-tls >/dev/null 2>&1 || true
    docker create --name ccinnredis-it-tls --network "$NET" -p "127.0.0.1:17076:6379" redis:7.2-alpine \
      redis-server --port 0 --tls-port 6379 --bind 0.0.0.0 --protected-mode no --save "" \
      --tls-cert-file /tls/server.crt --tls-key-file /tls/server.key --tls-ca-cert-file /tls/ca.crt --tls-auth-clients no >/dev/null
    docker cp "$TLS_DIR" ccinnredis-it-tls:/tls >/dev/null
    docker start ccinnredis-it-tls >/dev/null
    log "started ccinnredis-it-tls on 127.0.0.1:17076 (CA: $TLS_DIR/ca.crt)"
  fi
  for attempt in $(seq 1 30); do
    if docker exec ccinnredis-it-tls redis-cli --tls --cacert /tls/ca.crt -p 6379 PING 2>/dev/null | grep -q PONG; then break; fi
    sleep 1
  done
  docker exec ccinnredis-it-tls redis-cli --tls --cacert /tls/ca.crt -p 6379 SET tls:hello "secure" >/dev/null
fi

if wants stack; then
  if ! is_running ccinnredis-it-stack; then
    docker rm -f ccinnredis-it-stack >/dev/null 2>&1 || true
    docker run -d --name ccinnredis-it-stack --network "$NET" -p "127.0.0.1:17095:6379" redis/redis-stack-server:7.4.0-v1 >/dev/null
    log "started ccinnredis-it-stack on 127.0.0.1:17095"
  fi
  wait_ping ccinnredis-it-stack 6379
  "$SEED" demo ccinnredis-it-stack 6379
  "$SEED" json ccinnredis-it-stack 6379
fi

if wants cluster; then
  if ! is_running ccinnredis-it-cluster; then
    docker rm -f ccinnredis-it-cluster >/dev/null 2>&1 || true
    # All six nodes share one network namespace and listen on the published port numbers, so the
    # addresses they announce (127.0.0.1:1710x) are exactly the ones reachable from the host.
    docker run -d --name ccinnredis-it-cluster -p "127.0.0.1:17101-17106:17101-17106" redis:7.2-alpine sh -c '
      for port in 17101 17102 17103 17104 17105 17106; do
        mkdir -p /data/$port
        redis-server --port $port --bind 0.0.0.0 --protected-mode no --cluster-enabled yes \
          --cluster-config-file /data/$port/nodes.conf --cluster-announce-ip 127.0.0.1 --dir /data/$port \
          --save "" --appendonly no --daemonize yes
      done
      sleep 1
      redis-cli --cluster create 127.0.0.1:17101 127.0.0.1:17102 127.0.0.1:17103 127.0.0.1:17104 127.0.0.1:17105 127.0.0.1:17106 \
        --cluster-replicas 1 --cluster-yes
      exec tail -f /dev/null' >/dev/null
    log "started ccinnredis-it-cluster on 127.0.0.1:17101-17106"
  fi
  for attempt in $(seq 1 60); do
    if docker exec ccinnredis-it-cluster redis-cli -p 17101 CLUSTER INFO 2>/dev/null | grep -q "cluster_state:ok"; then break; fi
    sleep 1
  done
  "$SEED" cluster ccinnredis-it-cluster 17101
fi

if wants sentinel; then
  if ! is_running ccinnredis-it-sentinel; then
    docker rm -f ccinnredis-it-sentinel >/dev/null 2>&1 || true
    docker run -d --name ccinnredis-it-sentinel -p "127.0.0.1:17301-17302:17301-17302" -p "127.0.0.1:17311-17313:17311-17313" \
      redis:7.2-alpine sh -c '
      mkdir -p /data
      redis-server --port 17301 --bind 0.0.0.0 --protected-mode no --save "" --daemonize yes
      redis-server --port 17302 --bind 0.0.0.0 --protected-mode no --save "" --replicaof 127.0.0.1 17301 --daemonize yes
      for port in 17311 17312 17313; do
        printf "port $port\nbind 0.0.0.0\nprotected-mode no\ndir /data\nsentinel monitor mymaster 127.0.0.1 17301 2\nsentinel down-after-milliseconds mymaster 3000\nsentinel failover-timeout mymaster 10000\nsentinel parallel-syncs mymaster 1\n" > /data/sentinel-$port.conf
        redis-sentinel /data/sentinel-$port.conf --daemonize yes
      done
      exec tail -f /dev/null' >/dev/null
    log "started ccinnredis-it-sentinel (master 17301, replica 17302, sentinels 17311-17313)"
  fi
  wait_ping ccinnredis-it-sentinel 17301
  for attempt in $(seq 1 60); do
    if docker exec ccinnredis-it-sentinel redis-cli -p 17311 SENTINEL replicas mymaster 2>/dev/null | grep -q 17302; then break; fi
    sleep 1
  done
  master_port="$(docker exec ccinnredis-it-sentinel redis-cli -p 17311 SENTINEL get-master-addr-by-name mymaster | tail -1)"
  "$SEED" demo ccinnredis-it-sentinel "${master_port:-17301}"
fi

if wants proxy; then
  for backend in ccinnredis-it-proxy-b1 ccinnredis-it-proxy-b2; do
    if ! is_running "$backend"; then
      docker rm -f "$backend" >/dev/null 2>&1 || true
      docker run -d --name "$backend" --network "$NET" redis:7.2-alpine \
        redis-server --port 6379 --bind 0.0.0.0 --protected-mode no --save "" >/dev/null
      log "started $backend (internal only)"
    fi
  done
  if ! is_running ccinnredis-it-twemproxy; then
    docker rm -f ccinnredis-it-twemproxy >/dev/null 2>&1 || true
    docker run -d --name ccinnredis-it-twemproxy --network "$NET" -p "127.0.0.1:17201:6380" \
      -e LISTEN_PORT=6380 -e REDIS_SERVERS="ccinnredis-it-proxy-b1:6379:1,ccinnredis-it-proxy-b2:6379:1" \
      -e PRECONNECT=false -e SERVER_CONNECTIONS=4 malexer/twemproxy >/dev/null
    log "started ccinnredis-it-twemproxy on 127.0.0.1:17201"
  fi
  if ! is_running ccinnredis-it-envoy; then
    docker rm -f ccinnredis-it-envoy >/dev/null 2>&1 || true
    docker create --name ccinnredis-it-envoy --network "$NET" -p "127.0.0.1:17202:6379" envoyproxy/envoy:v1.36.7 \
      envoy -c /etc/envoy/redis.yaml --log-level warn >/dev/null
    docker cp "$ROOT/scripts/docker/envoy-redis.yaml" ccinnredis-it-envoy:/etc/envoy/redis.yaml >/dev/null
    docker start ccinnredis-it-envoy >/dev/null
    log "started ccinnredis-it-envoy on 127.0.0.1:17202"
  fi
  wait_ping ccinnredis-it-proxy-b1 6379
  wait_ping ccinnredis-it-proxy-b2 6379
  sleep 2
  "$SEED" proxy ccinnredis-it-proxy-b1 6379
fi

if wants large; then
  run_redis ccinnredis-it-72 redis:7.2-alpine 17072
  wait_ping ccinnredis-it-72 6379
  "$SEED" demo ccinnredis-it-72 6379
  "$SEED" large ccinnredis-it-72 6379
fi

log "ready. Run: CCINNREDIS_IT=1 swift test --filter IntegrationTests"
echo "export CCINNREDIS_IT=1"
