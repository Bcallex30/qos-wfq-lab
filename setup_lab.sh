#!/usr/bin/env bash
# setup_lab.sh — Configura el laboratorio QoS FIFO/WFQ (con detección e instalación automática de Docker)
# Compatible con Ubuntu 22.04 / 24.04 y entornos sin iptables/ufw

set -euo pipefail

msg(){ echo -e "\033[1;32m$*\033[0m"; }
warn(){ echo -e "\033[1;33m$*\033[0m"; }
err(){ echo -e "\033[1;31m$*\033[0m" >&2; }

# ---------------------------------------------------------------------------
# 1) Verificar Docker, intentar instalación con repos básicos primero
# ---------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  msg "→ Docker no detectado. Intentando instalación desde repositorios base..."
  apt-get update -qq
  if apt-get install -y docker.io docker-compose 2>/dev/null; then
    msg "✅ Docker y docker-compose instalados desde repositorios de Ubuntu."
  else
    warn "⚠️  No se pudo instalar desde repositorios base. Instalando desde el repositorio oficial de Docker..."
    apt-get install -y ca-certificates curl gnupg lsb-release
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    msg "✅ Docker instalado desde el repositorio oficial."
  fi
  systemctl enable docker --now
else
  msg "✅ Docker ya instalado."
fi

# ---------------------------------------------------------------------------
# 2) Verificar Docker Compose (plugin o binario)
# ---------------------------------------------------------------------------
if command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD="docker-compose"
elif docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
else
  warn "→ Instalando docker-compose (standalone)..."
  curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
    -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
  COMPOSE_CMD="docker-compose"
  msg "✅ docker-compose instalado manualmente."
fi
msg "→ Usando: $COMPOSE_CMD"

# ---------------------------------------------------------------------------
# 3) Crear estructura del laboratorio
# ---------------------------------------------------------------------------
mkdir -p router server

# docker-compose.yml
cat > docker-compose.yml <<'YML'
services:
  router:
    build:
      context: ./router
    container_name: qos-router
    cap_add: [ "NET_ADMIN" ]
    privileged: true
    networks:
      wan:
        ipv4_address: 10.10.255.2
      lan1:
        ipv4_address: 10.10.1.254
      lan2:
        ipv4_address: 10.10.2.254
    command: ["/bin/bash", "/usr/local/bin/router-entrypoint.sh"]

  server:
    build:
      context: ./server
    container_name: qos-server
    cap_add: [ "NET_ADMIN" ]
    networks:
      wan:
        ipv4_address: 10.10.255.10
    command: ["/bin/bash", "/usr/local/bin/server-entrypoint.sh"]

  h1:
    image: ubuntu:24.04
    container_name: qos-h1
    cap_add: [ "NET_ADMIN" ]
    command: ["bash", "/root/host-entrypoint.sh"]
    volumes:
      - ./host-entrypoint.sh:/root/host-entrypoint.sh:ro
    networks:
      lan1:
        ipv4_address: 10.10.1.10

  h2:
    image: ubuntu:24.04
    container_name: qos-h2
    cap_add: [ "NET_ADMIN" ]
    command: ["bash", "/root/host-entrypoint.sh"]
    volumes:
      - ./host-entrypoint.sh:/root/host-entrypoint.sh:ro
    networks:
      lan2:
        ipv4_address: 10.10.2.10

networks:
  wan:
    driver: bridge
    ipam:
      config: [ { subnet: 10.10.255.0/24 } ]
  lan1:
    driver: bridge
    ipam:
      config: [ { subnet: 10.10.1.0/24 } ]
  lan2:
    driver: bridge
    ipam:
      config: [ { subnet: 10.10.2.0/24 } ]
YML

# router Dockerfile + entrypoint
cat > router/Dockerfile <<'DOCKER'
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y iproute2 iputils-ping tcpdump && \
    apt-get clean && rm -rf /var/lib/apt/lists/*
COPY router-entrypoint.sh /usr/local/bin/router-entrypoint.sh
RUN chmod +x /usr/local/bin/router-entrypoint.sh
DOCKER

cat > router/router-entrypoint.sh <<'ROUTER'
#!/bin/bash
set -e
sysctl -w net.ipv4.ip_forward=1
echo "[router] Forwarding habilitado (sin iptables/ufw). Usa ./qos_mode.sh para FIFO/WFQ."
tail -f /dev/null
ROUTER

# server Dockerfile + entrypoint
cat > server/Dockerfile <<'DOCKER'
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y iproute2 iputils-ping iperf3 && \
    apt-get clean && rm -rf /var/lib/apt/lists/*
COPY server-entrypoint.sh /usr/local/bin/server-entrypoint.sh
RUN chmod +x /usr/local/bin/server-entrypoint.sh
DOCKER

cat > server/server-entrypoint.sh <<'SERVER'
#!/bin/bash
set -e
ip route add 10.10.1.0/24 via 10.10.255.2 dev eth0 || true
ip route add 10.10.2.0/24 via 10.10.255.2 dev eth0 || true
echo "[server] Rutas a LAN1/LAN2 agregadas. Iniciando iperf3 -s (5201)."
exec iperf3 -s
SERVER

# host entrypoint
cat > host-entrypoint.sh <<'HOST'
#!/bin/bash
set -e
apt-get update -qq && apt-get install -y iproute2 iputils-ping iperf3 >/dev/null
IF="eth0"
ip route del default || true
MYIP=$(ip -4 -o addr show dev $IF | awk '{print $4}')
if echo "$MYIP" | grep -q '^10\.10\.1\.'; then
  ip route add default via 10.10.1.254 dev $IF
elif echo "$MYIP" | grep -q '^10\.10\.2\.'; then
  ip route add default via 10.10.2.254 dev $IF
fi
echo "[host] Gateway configurado."
sleep infinity
HOST

chmod +x host-entrypoint.sh router/router-entrypoint.sh server/server-entrypoint.sh

# ---------------------------------------------------------------------------
# 4) Construir e iniciar contenedores
# ---------------------------------------------------------------------------
msg "==> Construyendo e iniciando contenedores..."
$COMPOSE_CMD up -d --build

msg "✅ Laboratorio levantado correctamente."
echo
echo "Comandos útiles:"
echo "  ./qos_mode.sh fifo      # sin QoS"
echo "  ./qos_mode.sh wfq       # HTB+SFQ en WAN (eth2)"
echo "  ./run_live_traffic.sh 30  # tráfico paralelo visible 30s"
echo "Pruebas rápidas:"
echo "docker exec -it qos-h1 ping -c 2 10.10.255.10"
echo "docker exec -it qos-h2 ping -c 2 10.10.255.10"
