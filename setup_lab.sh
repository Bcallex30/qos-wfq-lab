#!/usr/bin/env bash
# setup_lab.sh — Crea y levanta el lab QoS (FIFO/WFQ) sin iptables/ufw.
# Uso:
#   chmod +x setup_lab.sh
#   ./setup_lab.sh
set -euo pipefail

msg(){ echo -e "\033[1;32m$*\033[0m"; }

# (Opcional) instalar docker si falta
if ! command -v docker >/dev/null 2>&1; then
  msg "Instalando Docker & Compose..."
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl gnupg
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release; echo $VERSION_CODENAME) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo usermod -aG docker "$USER" || true
  echo "-> Si es tu primera instalación, cierra/abre sesión para usar docker sin sudo."
else
  msg "Docker ya presente."
fi

msg "Habilitando IP forwarding en el host..."
echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-ipforward.conf >/dev/null
sudo sysctl --system >/dev/null

msg "Creando estructura..."
mkdir -p router server

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
    command: ["/bin/bash", "-c", "/root/host-entrypoint.sh"]
    networks:
      lan1:
        ipv4_address: 10.10.1.10

  h2:
    image: ubuntu:24.04
    container_name: qos-h2
    cap_add: [ "NET_ADMIN" ]
    command: ["/bin/bash", "-c", "/root/host-entrypoint.sh"]
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

cat > router/Dockerfile <<'DOCKER'
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y iproute2 iputils-ping tcpdump && \
    apt-get clean && rm -rf /var/lib/apt/lists/*
COPY router-entrypoint.sh /usr/local/bin/router-entrypoint.sh
RUN chmod +x /usr/local/bin/router-entrypoint.sh
DOCKER

cat > router/router-entrypoint.sh <<'ROUTER'
#!/bin/bash
# router: solo routing y tc; SIN iptables/ufw/NAT.
set -e
sysctl -w net.ipv4.ip_forward=1
echo "[router] Forwarding listo. Usa qos_mode.sh para FIFO/WFQ."
tail -f /dev/null
ROUTER

cat > server/Dockerfile <<'DOCKER'
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y iproute2 iputils-ping iperf3 && \
    apt-get clean && rm -rf /var/lib/apt/lists/*
COPY server-entrypoint.sh /usr/local/bin/server-entrypoint.sh
RUN chmod +x /usr/local/bin/server-entrypoint.sh
DOCKER

cat > server/server-entrypoint.sh <<'SERVER'
#!/bin/bash
# server: agrega rutas estáticas hacia las LANs vía el router WAN 10.10.255.2
set -e
ip route add 10.10.1.0/24 via 10.10.255.2 dev eth0 || true
ip route add 10.10.2.0/24 via 10.10.255.2 dev eth0 || true
echo "[server] Rutas a LAN1/LAN2 listas. Iniciando iperf3 -s ..."
exec iperf3 -s
SERVER

cat > host-entrypoint.sh <<'HOST'
#!/bin/bash
# hosts: set default GW al router; SIN firewall.
set -e
apt-get update && apt-get install -y iproute2 iputils-ping iperf3 && \
  apt-get clean && rm -rf /var/lib/apt/lists/*
IF="eth0"
ip route del default || true
MYIP=$(ip -4 -o addr show dev $IF | awk '{print $4}')
if echo "$MYIP" | grep -q '^10\.10\.1\.'; then
  ip route add default via 10.10.1.254 dev $IF
elif echo "$MYIP" | grep -q '^10\.10\.2\.'; then
  ip route add default via 10.10.2.254 dev $IF
fi
sleep infinity
HOST

msg "Construyendo e iniciando contenedores..."
docker-compose up -d --build

msg "Inyectando entrypoint de hosts y reiniciando h1/h2..."
docker cp host-entrypoint.sh qos-h1:/root/host-entrypoint.sh
docker cp host-entrypoint.sh qos-h2:/root/host-entrypoint.sh
docker restart qos-h1 qos-h2 >/dev/null

msg "Listo. Pruebas rápidas:"
echo "docker exec -it qos-h1 ping -c 2 10.10.255.10"
echo "docker exec -it qos-h2 ping -c 2 10.10.255.10"
