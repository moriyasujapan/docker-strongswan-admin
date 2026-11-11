#!/bin/bash
# clone 直後にこれを実行すれば VPN + Web管理画面が起動する (何度実行しても安全。既存の鍵・設定は上書きしない)
#   使い方: ./setup.sh [--fqdn vpn.example.com] [--pool 192.168.90.128/25]
#   FQDN は環境変数 VPN_FQDN でも指定可。未指定かつ対話端末なら入力を求める。
set -euo pipefail
cd "$(dirname "$0")"

FQDN="${VPN_FQDN:-}"; POOL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --fqdn) FQDN="${2:?--fqdn に値が必要}"; shift 2;;
    --pool) POOL="${2:?--pool に値が必要}"; shift 2;;
    -h|--help) sed -n '2,5p' "$0"; exit 0;;
    *) echo "不明な引数: $1" >&2; exit 1;;
  esac
done

die(){ echo "エラー: $*" >&2; exit 1; }
for c in openssl docker; do command -v "$c" >/dev/null || die "$c が見つかりません"; done
DOCKER="docker"; docker info >/dev/null 2>&1 || { DOCKER="sudo docker"; $DOCKER info >/dev/null 2>&1 || die "docker デーモンに接続できません"; }
$DOCKER compose version >/dev/null 2>&1 || die "docker compose (v2) が必要です"

# --- vpn.env ---
if [ ! -f vpn.env ]; then
  if [ -z "$FQDN" ] && [ -t 0 ]; then read -rp "VPNサーバのFQDN (例: vpn.example.com): " FQDN; fi
  [ -n "$FQDN" ] || die "FQDN が未指定です: ./setup.sh --fqdn vpn.example.com"
  [[ "$FQDN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || die "FQDN の形式が不正です: $FQDN"
  cp vpn.env.example vpn.env
  sed -i "s|^VPN_FQDN=.*|VPN_FQDN=$FQDN|" vpn.env
  [ -z "$POOL" ] || sed -i "s|^VPN_POOL=.*|VPN_POOL=$POOL|" vpn.env
  echo "作成: vpn.env (VPN_FQDN=$FQDN)"
elif [ -n "$FQDN" ] && ! grep -qx "VPN_FQDN=$FQDN" vpn.env; then
  echo "注意: 既存の vpn.env を維持します (指定された FQDN は無視)。変更するには pki/ swanctl/ vpn.env を削除して再実行" >&2
fi

# --- .env (管理画面のログイン) ---
NEWPW=""
if [ ! -f .env ]; then
  NEWPW="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)"
  sed "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=$NEWPW|" .env.example > .env
  chmod 600 .env
  echo "作成: .env (管理画面のパスワードを自動生成)"
fi

# --- PKI (初回のみ) ---
if [ ! -f pki/ca/ca.key ]; then
  [ ! -e swanctl/swanctl.conf ] || die "swanctl/ が既にありますが pki/ がありません。削除してから再実行してください"
  ./scripts/init-pki.sh
else
  echo "既存のPKIを使用 (pki/)"
fi

# --- 起動 ---
$DOCKER compose up -d --build

# --- 起動待ち ---
echo -n "管理画面の起動を待機"
PW="$(grep '^ADMIN_PASSWORD=' .env | cut -d= -f2)"
ok=""
for _ in $(seq 1 60); do
  if curl -sk -m 3 -o /dev/null -w '%{http_code}' -u "admin:$PW" https://localhost:8443/api/users 2>/dev/null | grep -q 200; then ok=1; break; fi
  echo -n "."; sleep 2
done
echo
[ -n "$ok" ] || die "管理画面が起動しませんでした: $DOCKER compose logs admin"

echo
echo "=== 起動しました ==="
echo "管理画面 : https://<このホスト>:8443   (ユーザ: admin)"
[ -z "$NEWPW" ] || echo "パスワード: $NEWPW   (.env に保存済み。この表示は初回のみ)"
echo "VPN      : UDP 500 / 4500   FQDN=$(grep '^VPN_FQDN=' vpn.env | cut -d= -f2)"
echo
echo "次の作業:"
echo "  1. ファイアウォール: UDP 500,4500 を開放し、TCP 8443 は管理者IPのみに制限 (README 参照)"
echo "  2. 管理画面からユーザを追加し、.p12 / ca.crt を配布"
