#!/bin/bash
cd "$(dirname "$0")/.."
docker compose -f docker-compose.prod.yml logs -f --tail=100 "$@"
