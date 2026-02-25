#!/bin/bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/../.." && pwd)"
runtime_dir="$root_dir/.local-data/runtime"
mkdir -p "$runtime_dir"

mongo_bin="/Users/urwlee/Desktop/openclaw/.local/mongodb/bin/mongod"
redis_bin="/Users/urwlee/Desktop/openclaw/.local/redis/src/redis-server"
cloudflared_bin="/Users/urwlee/Desktop/openclaw/.local/cloudflared"
python_bin="$root_dir/.venv/bin/python"

mongo_port=27017
redis_port=6379
backend_port=8000
frontend_port=3000

is_listening() {
  local port="$1"
  lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
}

start_mongo() {
  if is_listening "$mongo_port"; then
    return
  fi
  "$mongo_bin" \
    --dbpath "$root_dir/.local-data/mongodb" \
    --logpath "$root_dir/.local-data/mongodb/mongod.log" \
    --bind_ip 127.0.0.1 \
    --port "$mongo_port" \
    >/dev/null 2>&1 &
  echo $! > "$runtime_dir/mongod.pid"
}

start_redis() {
  if is_listening "$redis_port"; then
    return
  fi
  "$redis_bin" \
    --dir "$root_dir/.local-data/redis" \
    --bind 127.0.0.1 \
    --port "$redis_port" \
    --requirepass tradingagents123 \
    >/dev/null 2>&1 &
  echo $! > "$runtime_dir/redis.pid"
}

start_backend() {
  if is_listening "$backend_port"; then
    return
  fi
  (cd "$root_dir" && "$python_bin" -m uvicorn app.main:app --reload --host 0.0.0.0 --port "$backend_port") \
    >"$runtime_dir/backend.log" 2>&1 &
  echo $! > "$runtime_dir/backend.pid"
}

start_frontend() {
  if is_listening "$frontend_port"; then
    return
  fi
  (cd "$root_dir/frontend" && npm run dev) >"$runtime_dir/frontend.log" 2>&1 &
  echo $! > "$runtime_dir/frontend.pid"
}

start_tunnel() {
  local target_url="$1"
  local log_file="$2"
  if [ ! -x "$cloudflared_bin" ]; then
    return
  fi
  "$cloudflared_bin" tunnel --url "$target_url" >"$log_file" 2>&1 &
  echo $! > "${log_file%.log}.pid"
}

extract_public_url() {
  local log_file="$1"
  if [ ! -f "$log_file" ]; then
    return
  fi
  grep -oE "https://[a-zA-Z0-9.-]+trycloudflare.com" "$log_file" | tail -n 1 || true
}

start_mongo
start_redis
start_backend
start_frontend

frontend_tunnel_log="$runtime_dir/cloudflared_frontend.log"
backend_tunnel_log="$runtime_dir/cloudflared_backend.log"
start_tunnel "http://localhost:$frontend_port" "$frontend_tunnel_log"
start_tunnel "http://localhost:$backend_port" "$backend_tunnel_log"

wait_public_url() {
  local log_file="$1"
  local url=""
  for _ in {1..10}; do
    url="$(extract_public_url "$log_file")"
    if [ -n "$url" ]; then
      echo "$url"
      return
    fi
    sleep 1
  done
  echo ""
}

frontend_public_url="$(wait_public_url "$frontend_tunnel_log")"
backend_public_url="$(wait_public_url "$backend_tunnel_log")"

echo "Local URLs:"
echo "  Frontend: http://localhost:$frontend_port"
echo "  Backend:  http://localhost:$backend_port"
echo ""
echo "Public URLs:"
if [ -n "${frontend_public_url:-}" ]; then
  echo "  Frontend: $frontend_public_url"
else
  echo "  Frontend: (未获取到地址，稍后查看 $frontend_tunnel_log)"
fi
if [ -n "${backend_public_url:-}" ]; then
  echo "  Backend:  $backend_public_url"
else
  echo "  Backend:  (未获取到地址，稍后查看 $backend_tunnel_log)"
fi
