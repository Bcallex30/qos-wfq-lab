#!/usr/bin/env bash
# ------------------------------------------------------------
# Script: run_live_traffic.sh (v2, sin TTY)
# Lanza dos flujos iperf3 simultáneos hacia qos-server y
# muestra la salida en vivo sin usar -t (TTY).
# Uso: ./run_live_traffic.sh [duracion_segundos]
# ------------------------------------------------------------
set -euo pipefail

DURATION="${1:-60}"

echo -e "\n🧱 Preparando servidores iperf3 en qos-server..."
# Levanta servidores en 5201 y 5202 (idempotente)
docker exec qos-server bash -lc "pgrep -x iperf3 >/dev/null || iperf3 -s -p 5201 &"
docker exec qos-server bash -lc "ss -lnt | grep -q ':5202 ' || iperf3 -s -p 5202 &"
sleep 1

echo "✅ Servidores activos:"
docker exec qos-server bash -lc "ss -lntp | egrep ':5201|:5202' || true"

echo -e "\n🚀 Iniciando tráfico paralelo durante ${DURATION}s...\n"

# Lanzar clientes SIN -t (TTY). 'stdbuf -oL' fuerza línea a línea.
# Prefijamos cada línea para distinguirlos.
docker exec -i qos-h1 bash -lc "stdbuf -oL iperf3 -c 10.10.255.10 -p 5201 -t ${DURATION}" \
  | sed -u 's/^/[h1] /' &
PID1=$!

docker exec -i qos-h2 bash -lc "stdbuf -oL iperf3 -c 10.10.255.10 -p 5202 -t ${DURATION}" \
  | sed -u 's/^/[h2] /' &
PID2=$!

# Esperar a ambos
wait "$PID1" "$PID2" || true

echo -e "\n📊 Prueba finalizada."
echo "💡 En otra terminal puedes monitorear en vivo:"
echo "  docker exec -it qos-server bash -lc 'apt update -qq && apt install -y iftop -qq && iftop -i eth0'"
echo "  docker exec -it qos-router bash -lc 'watch -n 1 tc -s class show dev eth0'"
