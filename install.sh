#!/bin/bash
# Run as the deploy user after bootstrap.sh
set -euo pipefail

[ "$(whoami)" != "root" ] || { echo "Run as deploy user, not root"; exit 1; }

APP_DIR="$HOME/linear-clone"
DEPLOY_REPO="${DEPLOY_REPO:-ankit-chowdhary/linear-deploy}"

read -rp "GitHub username: " GHCR_USER
read -rp "Image namespace (your GitHub username): " IMAGE_NAMESPACE
read -rsp "GitHub PAT (read:packages scope): " GHCR_TOKEN; echo
read -rp "Domain (e.g. linear.example.com): " DOMAIN
read -rp "Let's Encrypt email: " LE_EMAIL

cd "$HOME"
if [ ! -d "$APP_DIR/.git" ]; then
    echo "==> Cloning deploy repo..."
    git clone "https://github.com/${DEPLOY_REPO}.git" "$APP_DIR"
fi

cd "$APP_DIR"
git pull

echo "==> Generating secrets..."
mkdir -p secrets
[ -f secrets/pg_password.txt ]    || openssl rand -base64 24 | tr -d '\n' > secrets/pg_password.txt
[ -f secrets/jwt_secret.txt ]     || openssl rand -base64 48 | tr -d '\n' > secrets/jwt_secret.txt
[ -f secrets/report_api_key.txt ] || openssl rand -base64 32 | tr -d '\n' > secrets/report_api_key.txt
chmod 600 secrets/*.txt

echo "==> Writing .env.prod..."
cat > .env.prod <<ENV
DOMAIN=${DOMAIN}
LE_EMAIL=${LE_EMAIL}
IMAGE_NAMESPACE=${IMAGE_NAMESPACE}
PG_USER=linear
PG_DB=linear
PG_PASSWORD=$(cat secrets/pg_password.txt)
JWT_SECRET=$(cat secrets/jwt_secret.txt)
REPORT_API_KEY=$(cat secrets/report_api_key.txt)
ENVIRONMENT=production
BACKEND_IMAGE=ghcr.io/${IMAGE_NAMESPACE}/linear-clone-backend:latest
FRONTEND_IMAGE=ghcr.io/${IMAGE_NAMESPACE}/linear-clone-frontend:latest
ENV
chmod 600 .env.prod

echo "==> Logging in to GHCR..."
echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin

echo "==> Pulling images..."
set -a; source .env.prod; set +a
docker compose -f docker-compose.prod.yml pull

echo "==> Installing systemd units..."
sudo cp systemd/*.service systemd/*.timer /etc/systemd/system/
sudo sed -i "s|/home/deploy/linear-clone|$APP_DIR|g" /etc/systemd/system/linear-*.service
sudo sed -i "s|User=deploy|User=$(whoami)|g" /etc/systemd/system/linear-*.service
sudo systemctl daemon-reload
sudo systemctl enable --now linear-clone.service

echo "==> Waiting for health check..."
for i in {1..60}; do
    if curl -sf http://localhost:8080/healthz >/dev/null 2>&1; then
        echo "✅ Backend healthy!"
        break
    fi
    sleep 2
done

echo ""
echo "✅ Installation complete!"
echo "Visit: https://${DOMAIN}"
