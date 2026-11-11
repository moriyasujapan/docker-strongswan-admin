ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$ROOT/vpn.env" ] && . "$ROOT/vpn.env"
VPN_FQDN="${VPN_FQDN:?vpn.env に VPN_FQDN を設定してください}"
PKI="$ROOT/pki"
SW="$ROOT/swanctl"
CONTAINER="${CONTAINER:-strongswan}"
DOCKER="docker"; docker info >/dev/null 2>&1 || DOCKER="sudo docker"
reload() {
  local out
  if [ -S /run/vici/charon.vici ] && command -v swanctl >/dev/null; then   # Web管理コンテナ: viciソケット経由
    swanctl --flush-certs --type x509_crl >/dev/null 2>&1   # 古いCRLのキャッシュが失効判定に使われるのを防ぐ
    out=$(swanctl --load-all 2>&1)
  elif [ "$($DOCKER inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" = "true" ]; then
    $DOCKER exec "$CONTAINER" swanctl --flush-certs --type x509_crl >/dev/null 2>&1
    out=$($DOCKER exec "$CONTAINER" swanctl --load-all 2>&1)
  else
    echo "(コンテナ '$CONTAINER' は未起動: 起動時に設定が読み込まれます)"; return 0
  fi
  echo "$out" | grep -E "loaded eap secret|successfully loaded|invalid|failed to load (secret|connection)" || true
  echo "swanctl --load-all を実行しました"
}
