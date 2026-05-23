#!/usr/bin/env bash
set -euo pipefail

# Chorus + Pfortner deploy script
# Usage: ./scripts/deploy.sh [--config-only]
#
# Options:
#   --config-only   設定ファイルのみ転送 (バイナリと Pfortner ソース更新はスキップ)
#
# 環境変数 (すべて必須):
#   VPS_HOST       VPS のホスト名
#   VPS_USER       SSH ユーザー名
#   SSH_KEY        SSH 秘密鍵パス
#   RELAY_DOMAIN   リレーのドメイン名
#   TUNNEL_ID      Cloudflare Tunnel ID
#   ADMIN_DOMAIN   管理画面のドメイン名
#   ADMIN_TOKEN    Pfortner 管理画面の認証トークン
#
# 環境変数 (オプション):
#   PFORTNER_REPO_URL  Pfortner の git origin URL を差し替える
#                      (default: https://github.com/Hakkadaikon/Pfortner)
#   PFORTNER_REPO_REF  チェックアウトする ref / branch
#                      (default: main)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

: "${VPS_HOST:?VPS_HOST is required}"
: "${VPS_USER:?VPS_USER is required}"
: "${SSH_KEY:?SSH_KEY is required}"
: "${RELAY_DOMAIN:?RELAY_DOMAIN is required}"
: "${TUNNEL_ID:?TUNNEL_ID is required}"
: "${ADMIN_DOMAIN:?ADMIN_DOMAIN is required}"
: "${ADMIN_TOKEN:?ADMIN_TOKEN is required}"

PFORTNER_REPO_URL="${PFORTNER_REPO_URL:-https://github.com/Hakkadaikon/Pfortner}"
PFORTNER_REPO_REF="${PFORTNER_REPO_REF:-main}"

SSH_CMD="ssh -i $SSH_KEY ${VPS_USER}@${VPS_HOST}"
SCP_CMD="scp -i $SSH_KEY"

CONFIG_ONLY=false
if [[ "${1:-}" == "--config-only" ]]; then
    CONFIG_ONLY=true
fi

# --- Generate config from templates ---
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

for f in "$REPO_DIR"/config/*; do
    sed \
        -e "s/\${RELAY_DOMAIN}/${RELAY_DOMAIN}/g" \
        -e "s/\${TUNNEL_ID}/${TUNNEL_ID}/g" \
        -e "s/\${ADMIN_DOMAIN}/${ADMIN_DOMAIN}/g" \
        -e "s/\${ADMIN_TOKEN}/${ADMIN_TOKEN}/g" \
        "$f" > "$TMPDIR/$(basename "$f")"
done

echo "==> Deploying to ${VPS_USER}@${VPS_HOST} (domain: ${RELAY_DOMAIN})"

# --- Chorus binary ---
if [[ "$CONFIG_ONLY" == false ]]; then
    CHORUS_BIN="$REPO_DIR/chorus-bin/chorus"
    if [[ -f "$CHORUS_BIN" ]]; then
        echo "==> Transferring chorus binary..."
        $SCP_CMD "$CHORUS_BIN" "${VPS_USER}@${VPS_HOST}:/tmp/chorus"
        $SSH_CMD "sudo cp /tmp/chorus /opt/chorus/bin/chorus && sudo chmod 755 /opt/chorus/bin/chorus && sudo chown chorus:chorus /opt/chorus/bin/chorus && rm /tmp/chorus"
    else
        echo "    (skipped: $CHORUS_BIN not found. Run 'gh run download' first)"
    fi
fi

# --- Pfortner source update ---
if [[ "$CONFIG_ONLY" == false ]]; then
    echo "==> Updating Pfortner source on VPS to ${PFORTNER_REPO_URL} (${PFORTNER_REPO_REF})..."
    $SSH_CMD "PFORTNER_REPO_URL='${PFORTNER_REPO_URL}' PFORTNER_REPO_REF='${PFORTNER_REPO_REF}' bash -s" <<'REMOTE'
set -euo pipefail
REPO_DIR=/opt/pfortner/repo

if [ ! -d "$REPO_DIR/.git" ]; then
    echo "    pfortner repo not found at $REPO_DIR; run setup.sh first" >&2
    exit 1
fi

# Switch remote URL if it does not already match (fork migration).
CURRENT_URL=$(sudo -u chorus git -C "$REPO_DIR" remote get-url origin)
if [ "$CURRENT_URL" != "$PFORTNER_REPO_URL" ]; then
    echo "    updating origin: $CURRENT_URL -> $PFORTNER_REPO_URL"
    sudo -u chorus git -C "$REPO_DIR" remote set-url origin "$PFORTNER_REPO_URL"
fi

sudo -u chorus git -C "$REPO_DIR" fetch --prune --tags origin
sudo -u chorus git -C "$REPO_DIR" checkout "$PFORTNER_REPO_REF"
# Fast-forward to the remote tip (works for branches; harmless for tags)
sudo -u chorus git -C "$REPO_DIR" reset --hard "origin/${PFORTNER_REPO_REF}" 2>/dev/null \
    || sudo -u chorus git -C "$REPO_DIR" reset --hard "$PFORTNER_REPO_REF"

echo "    HEAD: $(sudo -u chorus git -C "$REPO_DIR" rev-parse --short HEAD) $(sudo -u chorus git -C "$REPO_DIR" log -1 --format='%s')"

# Re-cache deps in case lock/import map changed
sudo DENO_DIR=/opt/pfortner/cache deno cache "$REPO_DIR/scripts/serve.ts" 2>&1 | tail -3
REMOTE
fi

# --- Config files ---
echo "==> Transferring config files..."
$SCP_CMD \
    "$TMPDIR/chorus.toml" \
    "$TMPDIR/pfortner.yaml" \
    "$TMPDIR/cloudflared.yml" \
    "$TMPDIR/chorus.service" \
    "$TMPDIR/pfortner.service" \
    "$TMPDIR/cloudflared.service" \
    "${VPS_USER}@${VPS_HOST}:/tmp/"

echo "==> Installing config files on VPS..."
$SSH_CMD bash <<'REMOTE'
set -euo pipefail

# chorus
sudo cp /tmp/chorus.toml /opt/chorus/etc/chorus.toml
sudo chown chorus:chorus /opt/chorus/etc/chorus.toml

# pfortner
sudo cp /tmp/pfortner.yaml /opt/pfortner/etc/pfortner.yaml
sudo chown chorus:chorus /opt/pfortner/etc/pfortner.yaml

# cloudflared
sudo cp /tmp/cloudflared.yml /etc/cloudflared/config.yml

# systemd units
sudo cp /tmp/chorus.service /etc/systemd/system/chorus.service
sudo cp /tmp/pfortner.service /etc/systemd/system/pfortner.service
sudo cp /tmp/cloudflared.service /etc/systemd/system/cloudflared.service
sudo systemctl daemon-reload

# cleanup
rm -f /tmp/chorus.toml /tmp/pfortner.yaml /tmp/cloudflared.yml \
      /tmp/chorus.service /tmp/pfortner.service /tmp/cloudflared.service

# restart services
sudo systemctl restart chorus
sudo systemctl restart pfortner
sudo systemctl restart cloudflared

echo ""
echo "=== Service status ==="
sudo systemctl is-active chorus pfortner cloudflared
REMOTE

echo "==> Deploy complete!"
