#!/usr/bin/env bash
# run_live_traffic.sh — Lanza tráfico iperf3 paralelo con verificación del servidor
# Uso: ./run_live_traffic.sh [duracion_segundos]
set -euo pipefail

DURATION="${1:-60}"
SERVER="qos-server"
H1="qos-h1"
H2="qos-h2"

msg(){ echo -e "\033[1;32m$*\033[0m"; }
warn(){ echo -e "\033[1;33m$*\033[0m"; }
err(){ echo -e "\033[1;31m$*\033[0m" >&2; }

# ---------------------------------------------------------------------------
# 1) Verificar existencia del contenedor servidor
# ---------------------------------------------------------------------------
if ! docker ps -a --format '{{.Names}}' | grep -qx "$SERVER"; then
  err "❌ No se encontró el contenedor '$SERVER'. Ejecuta ./setup_lab.sh primero."
  exit 1
fi

# Si está detenido, arrancarlo
if ! docker ps --format '{{.Names}}' | grep -qx "$SERVER"; then
  warn "⚠️  El contenedor $SERVER está detenido. Iniciando..."
  docker start "$SERVER" >/dev/null
  sleep 2
fi

# ---------------------------------------------------------------------------
# 2) Verificar si iperf3 está corriendo en los puertos esperados
# ---------------------------------------------------------------------------
msg "🧱 Verificando estado de iperf3 en $SERVER..."

PORTS_STATUS=$(docker exec "$SERVER" bash -lc "ss -lntp | egrep ':5201|:5202' || true")
if [[ "$PORTS_STATUS" == "" ]]; then
  warn "⚠️  No hay servidores iperf3 activos. Iniciando en 5201 y 5202..."
  docker exec -d "$SERVER" bash -lc "iperf3 -s -p 5201"
  docker exec -d "$SERVER" bash -lc "iperf3 -s -p 5202"
elif ! echo "$PORTS_STATUS" | grep -q ":5201"; then
  warn "⚠️  Iniciando servidor iperf3 en puerto 5201..."
  docker exec -d "$SERVER" bash -lc "iperf3 -s -p 5201"
elif ! echo "$PORTS_STATUS" | grep -q ":5202"; then
  warn "⚠️  Iniciando servidor iperf3 en puerto 5202..."
  docker exec -d "$SERVER" bash -lc "iperf3 -s -p 5202"
else
  msg "✅ Servidores iperf3 ya activos."
fi

sleep 1
docker exec "$SERVER" bash -lc "ss -lntp | egrep ':5201|:5202' || true"

# ---------------------------------------------------------------------------
# 3) Verificar hosts
# ---------------------------------------------------------------------------
for h in "$H1" "$H2"; do
  if ! docker ps -a --format '{{.Names}}' | grep -qx "$h"; then
    err "❌ Falta el contenedor $h. Ejecuta ./setup_lab.sh antes."
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# 4) Iniciar tráfico en paralelo
# ---------------------------------------------------------------------------
msg "\n🚀 Iniciando tráfico paralelo durante ${DURATION}s...\n"

docker exec -i "$H1" bash -lc "stdbuf -oL iperf3 -c 10.10.255.10 -p 5201 -t ${DURATION}" \
  | sed -u 's/^/[h1] /' &
PID1=$!

docker exec -i "$H2" bash -lc "stdbuf -oL iperf3 -c 10.10.255.10 -p 5202 -t ${DURATION}" \
  | sed -u 's/^/[h2] /' &
PID2=$!

wait "$PID1" "$PID2" || true

# ---------------------------------------------------------------------------
# 5) Mostrar resumen y recomendaciones
# ---------------------------------------------------------------------------
msg "\n✅ Prueba completada."
echo
echo "📊 Puedes monitorear el resultado con:"
echo "  docker exec -it qos-router bash -lc 'watch -n 1 tc -s class show dev eth2'"
echo "  docker exec -it qos-server bash -lc 'apt update -qq && apt install -y iftop -qq && iftop -i eth0'"
echo
echo "📁 Logs de iperf3 se muestran arriba. Para repetir:"
echo "  ./run_live_traffic.sh ${DURATION}"
