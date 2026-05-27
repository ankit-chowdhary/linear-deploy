#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env.prod; set +a
if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
else
    DC="docker-compose"
fi
TS=$(date -u +%Y%m%d-%H%M%S)
mkdir -p backups
$DC -f docker-compose.prod.yml exec -T postgres \
    pg_dump -U "$PG_USER" -Fc "$PG_DB" | gzip -9 > "backups/linear-${TS}.dump.gz"
find backups -name "linear-*.dump.gz" -mtime +14 -delete
echo "✅ Backup: linear-${TS}.dump.gz"
