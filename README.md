# qos-wfq-lab
Descripción: Laboratorio de QoS WFQ (HTB + SFQ) en Docker

# 1) En la VM de cada grupo:
git clone https://github.com/Bcallex30/qos-wfq-lab.git
cd qos-wfq-lab
chmod +x setup_lab.sh qos_mode.sh run_live_traffic.sh
./setup_lab.sh

# 2) FIFO en vivo
./qos_mode.sh fifo
./run_live_traffic.sh 30

# 3) WFQ en vivo
./qos_mode.sh wfq
./run_live_traffic.sh 30

# 4) Monitoreo en router (clases en WAN detectada):
docker exec -it qos-router bash -lc 'watch -n 1 tc -s class show dev $(ip -o -4 a | awk "/10.10.255.2\\/24/{print $2; exit}")'
