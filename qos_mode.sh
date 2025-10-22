#!/usr/bin/env bash
# qos_mode.sh — Cambia entre FIFO y WFQ con 'tc' en la WAN real.
# Detecta la interfaz WAN por la IP 10.10.255.2; si no, usa eth2.
# Uso:
#   ./qos_mode.sh fifo
#   ./qos_mode.sh wfq              # TOTAL=20 H1=12 H2=8 (por defecto)
#   TOTAL=30 H1=18 H2=12 ./qos_mode.sh wfq
#   ./qos_mode.sh status

set -euo pipefail
ROUTER="qos-router"

detect_wan() {
  # Detecta interfaz que tenga 10.10.255.2/24
  local ifc
  ifc=$(docker exec -i "$ROUTER" bash -lc "ip -o -4 addr show | awk '\$4 ~ /10\\.10\\.255\\.2\\/24/ {print \$2; exit}'" || true)
  if [[ -z "$ifc" ]]; then
    ifc="eth2"  # fallback conocido de la topología
  fi
  echo "$ifc"
}

need_router() {
  docker ps --format '{{.Names}}' | grep -qx "$ROUTER" || {
    echo "ERROR: no encuentro $ROUTER. Ejecuta ./setup_lab.sh primero." >&2; exit 1; }
}

fifo_mode() {
  need_router
  WAN=$(detect_wan)
  echo "→ FIFO en $WAN (sin colas personalizadas)…"
  docker exec -it "$ROUTER" bash -lc "tc qdisc del dev ${WAN} root 2>/dev/null || true"
  status
}

wfq_mode() {
  need_router
  WAN=$(detect_wan)
  TOTAL_MB="${TOTAL:-20}"
  H1_MB="${H1:-12}"
  H2_MB="${H2:-8}"
  echo "→ WFQ en ${WAN}: TOTAL=${TOTAL_MB} Mb/s; h1=${H1_MB}; h2=${H2_MB}"

  docker exec -it "$ROUTER" bash -lc "
    set -e
    wan='${WAN}'
    tc qdisc del dev \$wan root 2>/dev/null || true
    tc qdisc add dev \$wan root handle 1: htb default 30

    tc class add dev \$wan parent 1: classid 1:1  htb rate ${TOTAL_MB}mbit ceil ${TOTAL_MB}mbit
    tc class add dev \$wan parent 1:1 classid 1:10 htb rate ${H1_MB}mbit  ceil ${TOTAL_MB}mbit prio 1
    tc qdisc add dev \$wan parent 1:10 handle 110: sfq perturb 10
    tc class add dev \$wan parent 1:1 classid 1:20 htb rate ${H2_MB}mbit  ceil ${TOTAL_MB}mbit prio 1
    tc qdisc add dev \$wan parent 1:20 handle 120: sfq perturb 10
    tc class add dev \$wan parent 1:1 classid 1:30 htb rate 1mbit ceil ${TOTAL_MB}mbit prio 3
    tc qdisc add dev \$wan parent 1:30 handle 130: sfq perturb 10

    # Clasificación por IP ORIGEN de las LANs (salida hacia WAN)
    tc filter add dev \$wan parent 1: protocol ip prio 1 u32 match ip src 10.10.1.0/24 flowid 1:10
    tc filter add dev \$wan parent 1: protocol ip prio 1 u32 match ip src 10.10.2.0/24 flowid 1:20
  "
  status
}

status() {
  need_router
  WAN=$(detect_wan)
  echo "== WAN: ${WAN} =="
  docker exec -it "$ROUTER" bash -lc "tc -s qdisc show dev ${WAN}"
  echo
  docker exec -it "$ROUTER" bash -lc "tc -s class show dev ${WAN} || true"
  echo
  echo "Consejo: para ver en vivo -> docker exec -it $ROUTER bash -lc 'watch -n 1 tc -s class show dev ${WAN}'"
}

case "${1:-}" in
  fifo)   fifo_mode ;;
  wfq)    wfq_mode ;;
  status) status ;;
  *) echo "Uso: $0 {fifo|wfq|status} (TOTAL/H1/H2 opcionales en wfq)" ; exit 1 ;;
esac

