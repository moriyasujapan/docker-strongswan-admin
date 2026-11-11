ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$ROOT/vpn.env" ] && . "$ROOT/vpn.env"
VPN_FQDN="${VPN_FQDN:?vpn.env に VPN_FQDN を設定してください}"
VPN_ADDR="${VPN_ADDR:-$VPN_FQDN}"   # クライアントが接続する宛先 (FQDNが未登録/変動する場合にIPを指定)
VPN_ROUTES="${VPN_ROUTES:-192.168.90.0/24}"   # VPNに通す宛先 (スプリットトンネル)。カンマ区切りで複数可
PKI="$ROOT/pki"
SW="$ROOT/swanctl"
CONTAINER="${CONTAINER:-strongswan}"
DOCKER="docker"; docker info >/dev/null 2>&1 || DOCKER="sudo docker"
# サーバの swanctl を実行する (管理コンテナ内は vici ソケット経由、ホストでは docker exec)
swan() {
  if [ -S /run/vici/charon.vici ] && command -v swanctl >/dev/null; then swanctl "$@"
  elif [ "$($DOCKER inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" = "true" ]; then $DOCKER exec "$CONTAINER" swanctl "$@"
  else return 3; fi
}
# 指定ユーザの接続中セッションをすべて切断する。切断した数を表示
# 一致の対象: EAP の ID / IKE の ID がユーザ名そのもの / <user>@FQDN (証明書SAN) / 証明書の DN
kill_sessions() {
  local u="$1" n=0 i
  for i in $(swan --list-sas 2>/dev/null | awk -v u="$u" -v f="$VPN_FQDN" '
      /^[^ ].*: #[0-9]+,/ { id=$2; gsub(/[#,]/,"",id) }
      /^  remote / { if (index($0,"EAP: \047" u "\047") || index($0,"remote \047" u "\047 @") || index($0,"remote \047" u "@" f "\047") || index($0,"remote \047CN=" u ", O=VPN\047")) print id }' | sort -u); do
    swan --terminate --ike-id "$i" --force >/dev/null 2>&1 && n=$((n+1))
  done
  echo "切断したセッション: $n"
}
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
  if echo "$out" | grep -qE "invalid config file|syntax error"; then echo "設定ファイルの読み込みに失敗: $(echo "$out" | grep -E "syntax error" | head -1)" >&2; return 1; fi
  echo "swanctl --load-all を実行しました"
}
