#!/bin/bash
cd "$(dirname "$0")/.."
if docker compose version >/dev/null 2>&1; then
    docker compose -f docker-compose.prod.yml logs -f --tail=100 "$@"
else
    docker-compose -f docker-compose.prod.yml logs -f --tail=100 "$@"
fi
