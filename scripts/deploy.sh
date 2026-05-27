#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
LOCK=/tmp/linear-deploy.lock
exec 200>"$LOCK"
flock -n 200 || { echo "Deploy in progress"; exit 0; }

# Auto-detect compose command
if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
else
    DC="docker-compose"
fi

set -a; source .env.prod; set +a
git pull
$DC -f docker-compose.prod.yml pull backend frontend
$DC -f docker-compose.prod.yml up -d --no-deps backend
for i in {1..30}; do
    curl -sf http://localhost:8080/healthz >/dev/null && break
    sleep 2
done
$DC -f docker-compose.prod.yml up -d --no-deps frontend
docker image prune -f --filter "until=168h"
echo "✅ Deploy complete"
