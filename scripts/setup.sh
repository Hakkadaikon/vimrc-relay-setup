#!/usr/bin/env bash
set -euo pipefail

# VPS 初期セットアップスクリプト
# Usage: ./scripts/setup.sh
#
# 新規 VPS に Chorus + Pfortner + cloudflared 環境を構築します。
# セットアップ後は ./scripts/deploy.sh で設定ファイルとバイナリをデプロイしてください。
#
# 前提条件:
#   - VPS に SSH 接続可能であること
#   - cloudflared のトンネルが作成済みであること
#     (VPS 上で cloudflared tunnel login && cloudflared tunnel create <NAME> を実行)
#   - トンネル認証情報 (<TUNNEL_ID>.json) が /etc/cloudflared/ に配置済みであること
#
# 環境変数 (すべて必須):
#   VPS_HOST    VPS のホスト名
#   VPS_USER    SSH ユーザー名
#   SSH_KEY     SSH 秘密鍵パス

: "${VPS_HOST:?VPS_HOST is required}"
: "${VPS_USER:?VPS_USER is required}"
: "${SSH_KEY:?SSH_KEY is required}"

SSH_CMD="ssh -i $SSH_KEY ${VPS_USER}@${VPS_HOST}"

echo "==> Setting up VPS ${VPS_USER}@${VPS_HOST}"

$SSH_CMD bash <<'REMOTE'
set -euo pipefail

# --- Swap (1GB) ---
if [ ! -f /swapfile ]; then
    echo "==> Creating swap..."
    sudo fallocate -l 1G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    echo '/swapfile swap swap defaults 0 0' | sudo tee -a /etc/fstab
else
    echo "    swap already exists, skipping"
fi

# --- System packages ---
echo "==> Installing packages..."
sudo dnf install -y unzip git 2>&1 | tail -1

# --- chorus user ---
if ! id chorus &>/dev/null; then
    echo "==> Creating chorus user..."
    sudo useradd -r -s /sbin/nologin chorus
else
    echo "    chorus user already exists, skipping"
fi

# --- Chorus directories ---
echo "==> Setting up Chorus directories..."
sudo mkdir -p /opt/chorus/{bin,etc,var/chorus}
sudo chown -R chorus:chorus /opt/chorus/var

# --- Deno ---
if ! command -v deno &>/dev/null; then
    echo "==> Installing Deno..."
    curl -fsSL https://deno.land/install.sh | sh
    sudo cp ~/.deno/bin/deno /usr/bin/deno
    deno --version
else
    echo "    Deno already installed: $(deno --version | head -1)"
fi

# --- Pfortner ---
PFORTNER_REPO_URL="${PFORTNER_REPO_URL:-https://github.com/Hakkadaikon/Pfortner}"
PFORTNER_REPO_REF="${PFORTNER_REPO_REF:-main}"

if [ ! -d /opt/pfortner/repo/.git ]; then
    echo "==> Cloning Pfortner from ${PFORTNER_REPO_URL} (${PFORTNER_REPO_REF})..."
    sudo mkdir -p /opt/pfortner/{repo,etc,cache}
    sudo git clone --branch "${PFORTNER_REPO_REF}" "${PFORTNER_REPO_URL}" /opt/pfortner/repo
    echo "==> Caching Pfortner dependencies..."
    sudo DENO_DIR=/opt/pfortner/cache deno cache /opt/pfortner/repo/scripts/serve.ts 2>&1 | tail -3
    sudo chown -R chorus:chorus /opt/pfortner
else
    echo "    Pfortner already cloned, skipping (use deploy.sh to update)"
fi

# --- cloudflared ---
if ! command -v cloudflared &>/dev/null; then
    echo "==> Installing cloudflared..."
    sudo dnf install -y cloudflared 2>&1 | tail -1
else
    echo "    cloudflared already installed"
fi

# --- Enable services ---
echo "==> Enabling services..."
sudo systemctl daemon-reload
sudo systemctl enable chorus pfortner cloudflared 2>/dev/null || true

echo ""
echo "=== Setup complete ==="
echo "Next steps:"
echo "  1. If not done: create Cloudflare tunnel on VPS"
echo "     cloudflared tunnel login"
echo "     cloudflared tunnel create <NAME>"
echo "     cloudflared tunnel route dns <NAME> <DOMAIN>"
echo "  2. Run ./scripts/deploy.sh to deploy config and binary"
REMOTE

echo "==> VPS setup complete!"
