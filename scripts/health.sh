#!/bin/bash
cd "$(dirname "$0")/.."
if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
else
    DC="docker-compose"
fi
echo "=== Containers ==="
$DC -f docker-compose.prod.yml ps
echo ""
echo "=== Disk ==="
df -h /
echo ""
echo "=== Memory ==="
free -h
echo ""
echo "=== Backend health ==="
curl -s http://localhost:8080/healthz
