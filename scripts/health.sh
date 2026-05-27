#!/bin/bash
cd "$(dirname "$0")/.."
echo "=== Containers ==="
docker compose -f docker-compose.prod.yml ps
echo ""
echo "=== Disk ==="
df -h /
echo ""
echo "=== Memory ==="
free -h
echo ""
echo "=== Backend health ==="
curl -s http://localhost:8080/healthz
