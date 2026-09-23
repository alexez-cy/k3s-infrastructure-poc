#!/usr/bin/env bash
set -euo pipefail

NODE="k3d-app-agent-0"
NETSHOOT="network-test"

cleanup() {
    docker exec "$NETSHOOT" tc qdisc del dev eth0 root 2>/dev/null || true
    docker rm -f "$NETSHOOT" >/dev/null 2>&1 || true
}

trap cleanup EXIT INT TERM

docker run -d \
    --name "$NETSHOOT" \
    --privileged \
    --network "container:$NODE" \
    nicolaka/netshoot \
    sleep infinity

docker exec "$NETSHOOT" \
    tc qdisc replace dev eth0 root netem \
    delay 200ms 50ms \
    loss 10%

echo "Network impairment applied to $NODE"
echo "Press Ctrl+C to stop the test."

while true; do
    sleep 1
done