#!/usr/bin/env bash
set -euo pipefail

# ── Arguments ─────────────────────────────────────────────────────────────────
if [ $# -lt 2 ]; then
    echo "Usage: $0 <domain> <email>"
    echo "  domain  — FQDN pointed at this server (e.g. proxy.example.com)"
    echo "  email   — contact email for Let's Encrypt certificate notifications"
    exit 1
fi

DOMAIN="$1"
EMAIL="$2"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"

log()  { echo -e "\n\033[1;32m[✓]\033[0m $1"; }
info() { echo -e "\033[1;34m[→]\033[0m $1"; }
err()  { echo -e "\033[1;31m[✗]\033[0m $1"; exit 1; }

check() {
    if [ $? -eq 0 ]; then
        log "$1"
    else
        err "$2"
    fi
}

echo ""
echo "============================================="
echo "  Deploying LiteLLM proxy with SSL"
echo "  Domain: $DOMAIN"
echo "============================================="

# ── Pre-flight checks ──────────────────────────────────────────────────────
info "Running pre-flight checks..."

[ -f "$PROJECT_DIR/docker-compose.yml" ] || err "docker-compose.yml not found in $PROJECT_DIR"
log "docker-compose.yml found"

[ -f "$PROJECT_DIR/.env" ] || err ".env file not found in $PROJECT_DIR"
log ".env file found"

[ -f "$PROJECT_DIR/litellm-config.yaml" ] || err "litellm-config.yaml not found in $PROJECT_DIR"
log "litellm-config.yaml found"

[ -f "$PROJECT_DIR/nginx.conf" ] || err "nginx.conf not found in $PROJECT_DIR"
log "nginx.conf found"

info "Checking DNS resolution for $DOMAIN..."
RESOLVED_IP=$(dig +short "$DOMAIN" A 2>/dev/null || true)
SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || true)
if [ -n "$RESOLVED_IP" ]; then
    log "DNS resolves $DOMAIN -> $RESOLVED_IP"
    if [ "$RESOLVED_IP" = "$SERVER_IP" ]; then
        log "DNS matches this server's IP ($SERVER_IP)"
    else
        info "WARNING: DNS ($RESOLVED_IP) does not match this server's IP ($SERVER_IP). SSL may fail."
    fi
else
    err "DNS does not resolve for $DOMAIN. Set an A record before running this script."
fi

# ── 1. Install Docker ──────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    info "Installing Docker..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq ca-certificates curl gnupg
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
    sudo usermod -aG docker "$USER"
    log "Docker installed (version: $(docker --version))"
else
    log "Docker already installed (version: $(docker --version))"
fi

# Verify docker daemon is running
if sudo systemctl is-active --quiet docker; then
    log "Docker daemon is running"
else
    info "Starting Docker daemon..."
    sudo systemctl start docker
    sudo systemctl is-active --quiet docker || err "Failed to start Docker daemon"
    log "Docker daemon started"
fi

# ── 2. Install Nginx ───────────────────────────────────────────────────────
if ! command -v nginx &>/dev/null; then
    info "Installing Nginx..."
    sudo apt-get install -y -qq nginx
    log "Nginx installed (version: $(nginx -v 2>&1))"
else
    log "Nginx already installed (version: $(nginx -v 2>&1))"
fi

if sudo systemctl is-active --quiet nginx; then
    log "Nginx is running"
else
    info "Starting Nginx..."
    sudo systemctl start nginx
    sudo systemctl is-active --quiet nginx || err "Failed to start Nginx"
    log "Nginx started"
fi

# ── 3. Install Certbot ─────────────────────────────────────────────────────
if ! command -v certbot &>/dev/null; then
    info "Installing Certbot..."
    sudo apt-get install -y -qq certbot python3-certbot-nginx
    log "Certbot installed (version: $(certbot --version 2>&1))"
else
    log "Certbot already installed (version: $(certbot --version 2>&1))"
fi

# ── 4. Configure Nginx (HTTP only first, for cert issuance) ────────────────
info "Configuring Nginx for HTTP challenge..."
sudo mkdir -p /var/www/certbot
cat <<HTTPCONF | sudo tee "/etc/nginx/sites-available/$DOMAIN" > /dev/null
server {
    listen 80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
HTTPCONF

sudo ln -sf "/etc/nginx/sites-available/$DOMAIN" /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default

info "Testing Nginx config..."
sudo nginx -t || err "Nginx config test failed"
sudo systemctl reload nginx
log "Nginx HTTP config active"

# ── 5. Obtain SSL certificate ──────────────────────────────────────────────
if [ ! -d "/etc/letsencrypt/live/$DOMAIN" ]; then
    info "Obtaining SSL certificate for $DOMAIN..."
    sudo certbot certonly --webroot -w /var/www/certbot \
        -d "$DOMAIN" \
        --non-interactive --agree-tos \
        --email "$EMAIL"
    sudo test -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" || err "SSL certificate files not found after certbot"
    log "SSL certificate obtained successfully"
else
    log "SSL certificate already exists for $DOMAIN"
    info "Certificate details:"
    sudo certbot certificates 2>/dev/null | grep -A3 "$DOMAIN" || true
fi

# ── 6. Deploy full Nginx config with SSL ───────────────────────────────────
info "Installing full Nginx config with SSL..."
sed "s/__DOMAIN__/$DOMAIN/g" "$PROJECT_DIR/nginx.conf" | sudo tee "/etc/nginx/sites-available/$DOMAIN" > /dev/null

info "Testing Nginx SSL config..."
sudo nginx -t || err "Nginx SSL config test failed"
sudo systemctl reload nginx
log "Nginx SSL config active"

# ── 7. Enable certbot auto-renewal timer ───────────────────────────────────
sudo systemctl enable --now certbot.timer 2>/dev/null || true
log "Certbot auto-renewal enabled"

# ── 8. Start the application ───────────────────────────────────────────────
info "Starting LiteLLM + Postgres with Docker Compose..."
cd "$PROJECT_DIR"

# Use 'docker compose' (v2 plugin) or fall back to 'docker-compose'
if docker compose version &>/dev/null; then
    COMPOSE="docker compose"
else
    COMPOSE="docker-compose"
fi

info "Pulling latest images..."
sudo $COMPOSE pull
log "Images pulled"

info "Starting containers..."
sudo $COMPOSE up -d
log "Containers started"

# ── 9. Post-deploy verification ────────────────────────────────────────────
info "Waiting 10s for services to initialize..."
sleep 10

info "Checking container status..."
sudo $COMPOSE ps

DB_STATUS=$(sudo $COMPOSE ps --format json 2>/dev/null | grep -o '"db"' || echo "")
LITELLM_STATUS=$(sudo $COMPOSE ps --format json 2>/dev/null | grep -o '"litellm"' || echo "")

if sudo $COMPOSE ps | grep -q "Up"; then
    log "Containers are running"
else
    err "Some containers failed to start. Check: sudo $COMPOSE logs"
fi

info "Testing HTTPS endpoint..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "https://$DOMAIN/health" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    log "HTTPS health check passed (HTTP $HTTP_CODE)"
elif [ "$HTTP_CODE" = "000" ]; then
    info "WARNING: Could not reach https://$DOMAIN/health — LiteLLM may still be starting up"
    info "Check logs with: sudo $COMPOSE logs -f litellm"
else
    info "HTTPS returned HTTP $HTTP_CODE — LiteLLM may still be initializing"
    info "Check logs with: sudo $COMPOSE logs -f litellm"
fi

echo ""
echo "============================================="
log "Deployment complete!"
echo "============================================="
echo ""
echo "  HTTP:  http://$DOMAIN  (redirects to HTTPS)"
echo "  HTTPS: https://$DOMAIN"
echo ""
echo "Useful commands:"
echo "  sudo $COMPOSE logs -f             # follow logs"
echo "  sudo $COMPOSE ps                  # container status"
echo "  sudo $COMPOSE restart             # restart services"
echo "  sudo certbot renew --dry-run      # test cert renewal"
echo "  sudo nginx -t && sudo systemctl reload nginx  # reload nginx"
