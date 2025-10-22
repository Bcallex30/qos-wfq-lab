#!/usr/bin/env bash
# qos_mode.sh — FIFO o WFQ sin iptables/ufw (usa 'tc' + u32 por IP).
# Uso:
#   chmod +x qos_mode.sh
#   ./qos_mode.sh fifo
#   ./qos_mode.sh wfq
#   TOTAL=30 H1=18 H2=12 ./qos_mode.sh wfq
#   ./qos_mode.sh status
set -euo pipefail
ROUTER="qos-router"
WAN="eth0"

need_router() {
  docker ps --format '{{.Names}}' | grep -qx "$ROUTER" || {
    echo "ERROR: no está '$ROUTER'. Ejecuta ./setup_lab.sh primero." >&2; exit 1; }
}

fifo_mode() {
  need_router
  echo "→ FIFO: quitando qdisc root..."
  docker exec -it "$ROUTER" bash -lc "tc qdisc del dev ${WAN} root 2>/dev/null || true"
  status
}

wfq_mode() {
  need_router
  TOTAL_MB="${TOTAL:-20}"
  H1_MB="${H1:-12}"
  H2_MB="${H2:-8}"
  echo "→ WFQ (HTB+SFQ): TOTAL=${TOTAL_MB} Mb/s; h1=${H1_MB}; h2=${H2_MB}"

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

    # Clasificar por IP origen (sin iptables): LAN1 -> 1:10, LAN2 -> 1:20
    tc filter add dev \$wan parent 1: protocol ip prio 1 u32 match ip src 10.10.1.0/24 flowid 1:10
    tc filter add dev \$wan parent 1: protocol ip prio 1 u32 match ip src 10.10.2.0/24 flowid 1:20
  "
  status
}

status() {
  need_router
  echo "== QDISC =="
  docker exec -it "$ROUTER" bash -lc "tc -s qdisc show dev ${WAN}"
  echo; echo "== CLASES =="
  docker exec -it "$ROUTER" bash -lc "tc -s class show dev ${WAN} || true"
  echo; echo "== RUTAS SERVIDOR =="
  docker exec -it qos-server ip r
}

case "${1:-}" in
  fifo) fifo_mode ;;
  wfq)  wfq_mode ;;
  status) status ;;
  *) echo "Uso: $0 {fifo|wfq|status}  (TOTAL/H1/H2 opcionales para 'wfq')" ; exit 1 ;;
esac
