# vimrc-relay-setup

[Chorus](https://github.com/mikedilger/chorus) Nostr Relay のビルド・デプロイ環境です。

GitHub Actions で `x86_64-unknown-linux-musl` 静的バイナリをビルドし、
[Pförtner (Hakkadaikon fork)](https://github.com/Hakkadaikon/Pfortner) による
kind フィルタリングを経由して、Linux VPS + Cloudflare Tunnel でホストします。
fork では本家 `ikuradon/Pfortner` の接続スロットリーク
([詳細](https://github.com/Hakkadaikon/Pfortner/commit/2dd4738)) を修正済み。

`PFORTNER_REPO_URL` / `PFORTNER_REPO_REF` 環境変数で deploy 時の参照先を上書きできます。

## 構成

```
cloudflared → Pfortner (:3000, kind フィルタ) → Chorus (:8080)
```

## ファイル構成

```
config/
  chorus.toml           # Chorus 設定 (テンプレート: ${RELAY_DOMAIN})
  chorus.service        # Chorus systemd ユニット
  pfortner.yaml         # Pfortner 設定 (kind フィルタリングルール)
  pfortner.service      # Pfortner systemd ユニット
  cloudflared.yml       # Cloudflare Tunnel 設定 (テンプレート: ${RELAY_DOMAIN}, ${TUNNEL_ID})
  cloudflared.service   # cloudflared systemd ユニット
scripts/
  setup.sh              # VPS 初期セットアップ
  deploy.sh             # 設定ファイル・バイナリのデプロイ
.github/workflows/
  build.yml             # Chorus 静的バイナリのビルド
```

## ビルド

```bash
gh workflow run build.yml
gh run download <RUN_ID> --name chorus-linux-x86_64-musl --dir ./chorus-bin
```

## 初期セットアップ

```bash
VPS_HOST=... VPS_USER=... SSH_KEY=... ./scripts/setup.sh
```

## デプロイ

```bash
VPS_HOST=... VPS_USER=... SSH_KEY=... RELAY_DOMAIN=... TUNNEL_ID=... \
  ./scripts/deploy.sh             # バイナリ + 設定ファイルをデプロイ

./scripts/deploy.sh --config-only  # 設定ファイルのみデプロイ
```

詳細な手順は [docs/deploy.md](docs/deploy.md) を参照してください。
