#!/usr/bin/env bash
# Stops and removes every ccinnredis-it-* container and the test network (nothing else is touched).
set -euo pipefail

names=()
while IFS= read -r name; do
  [[ -n "$name" ]] && names+=("$name")
done < <(docker ps -a --format '{{.Names}}' | grep '^ccinnredis-it-' || true)

if [[ ${#names[@]} -gt 0 ]]; then
  docker rm -f ${names[@]+"${names[@]}"} >/dev/null
  echo "removed: ${names[*]}"
else
  echo "no ccinnredis-it-* containers"
fi
docker network rm ccinnredis-it-net >/dev/null 2>&1 || true
