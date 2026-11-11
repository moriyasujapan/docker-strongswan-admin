#!/bin/bash
# 使い方: mkmacbundle.sh <username> <出力ファイル.tar.gz>
# Mac 用の接続一式を作る (Homebrew の strongSwan / charon-cmd で、証明書 → パスワードの2段階認証のまま接続する)
#  Apple 標準のVPN機能は証明書+パスワードの併用ができないため、標準機能は使わない。
#  パスワードは同梱しない (接続のたびに入力)。秘密鍵は同梱する (取り扱い注意)。
set -euo pipefail
. "$(dirname "$0")/common.sh"
U="${1:?username}"; OUT="${2:?出力ファイル}"
[[ "$U" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "不正なユーザ名" >&2; exit 1; }
D="$PKI/clients/$U"
[ -f "$D/$U.crt" ] && [ -f "$D/$U.key" ] || { echo "ユーザが存在しません: $U" >&2; exit 1; }
# IKE の ID: 証明書に SAN(メール形式) があればそれ、無ければ Subject DN
if openssl x509 -in "$D/$U.crt" -noout -ext subjectAltName 2>/dev/null | grep -q "email:$U@$VPN_FQDN"; then ID="$U@$VPN_FQDN"; else ID="CN=$U, O=VPN"; fi
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
B="$T/vpn-$U"; mkdir -p "$B"
cp "$PKI/ca/ca.crt" "$B/ca.crt"; cp "$D/$U.crt" "$B/$U.crt"; cp "$D/$U.key" "$B/$U.key"; chmod 600 "$B/$U.key"
cat > "$B/connect.sh" <<SH
#!/bin/bash
# VPN 接続 ($U): クライアント証明書 → パスワード(EAP-MSCHAPv2) の2段階認証
# 切断は Ctrl+C。パスワードは接続のたびに聞かれます (保存しません)。
cd "\$(dirname "\$0")"
command -v charon-cmd >/dev/null || { echo "strongSwan が必要です:  brew install strongswan" >&2; exit 1; }
SUDO=sudo; [ "\$(id -u)" = 0 ] && SUDO=
exec \$SUDO charon-cmd --host "\${VPN_HOST:-$VPN_ADDR}" --remote-identity "$VPN_FQDN" \\
  --identity "$ID" --cert ca.crt --cert "$U.crt" --rsa "$U.key" \\
  --eap-identity "$U" --profile ikev2-pub-eap \\
  --ike-proposal aes256-sha256-modp2048 --esp-proposal aes256-sha256 "\$@"
SH
chmod 755 "$B/connect.sh"
cat > "$B/README.txt" <<TXT
Mac 用 VPN 接続一式 ($U)

Mac 標準の VPN 機能は「証明書 + パスワード」の併用に対応していないため、strongSwan 本体を使います。

1. Homebrew で strongSwan を入れる (初回のみ)
     brew install strongswan
2. このフォルダで接続する
     ./connect.sh
   - 最初に Mac の管理者パスワード (sudo) を聞かれます。
   - 続いて "EAP password" を聞かれるので、VPN パスワードを入力します。
   - 切断は Ctrl+C です。

ファイル
  ca.crt      サーバ検証用の CA 証明書
  $U.crt      クライアント証明書
  $U.key      クライアント秘密鍵 (暗号化なし。他人に渡さない。不要になったらフォルダごと削除)
  connect.sh  接続スクリプト

接続先: $VPN_ADDR (サーバ識別名: $VPN_FQDN)
注意: iPhone / iPad では使えません。
TXT
tar -C "$T" -czf "$OUT" "vpn-$U"
