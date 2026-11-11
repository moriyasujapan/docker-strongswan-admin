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
TS=""; IFS=, read -ra _R <<< "$VPN_ROUTES"; for r in "${_R[@]}"; do r="${r// /}"; [ -n "$r" ] && TS="$TS --remote-ts $r"; done
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
  --ike-proposal aes256-sha256-modp2048 --esp-proposal aes256-sha256$TS "\$@"
SH
chmod 755 "$B/connect.sh"
# Finder でダブルクリックして接続 (ターミナルが開く)
printf '#!/bin/bash\ncd "$(dirname "$0")" && exec ./connect.sh\n' > "$B/VPN-Connect.command"
# Dock に置けるアプリ (~/Applications/VPN-<user>.app) を作る
cat > "$B/Make-Dock-App.command" <<SH
#!/bin/bash
# Dock に置けるアプリを作成します。作成後にこのフォルダを移動・削除すると、アプリは動かなくなります。
cd "\$(dirname "\$0")"; DIR="\$(pwd)"
APP="\$HOME/Applications/VPN-$U.app"; mkdir -p "\$HOME/Applications"; rm -rf "\$APP"
osacompile -o "\$APP" -e 'on run' -e 'tell application "Terminal"' -e 'activate' \\
  -e "do script \\"exec \\" & quoted form of \\"\$DIR/connect.sh\\"" -e 'end tell' -e 'end run' || { echo "作成に失敗しました"; exit 1; }
echo "作成しました: \$APP"; echo "Finder に表示します。Dock にドラッグしてください。"; open -R "\$APP"
SH
chmod 755 "$B/VPN-Connect.command" "$B/Make-Dock-App.command"
cat > "$B/README.txt" <<TXT
Mac 用 VPN 接続一式 ($U)

Mac 標準の VPN 機能は「証明書 + パスワード」の併用に対応していないため、strongSwan 本体を使います。

1. Homebrew で strongSwan を入れる (初回のみ)
     brew install strongswan
2. このフォルダで接続する
     ./connect.sh
   - 最初に Mac の管理者パスワード (sudo) を聞かれます。
   - 続いて "EAP password" を聞かれるので、VPN パスワードを入力します。
   - 切断は Ctrl+C です (またはウィンドウを閉じる)。

ダブルクリック / Dock から接続する
  - VPN-Connect.command をダブルクリックすると、ターミナルが開いて接続を始めます。
    初回に「開発元を確認できない」と出たら、右クリック →「開く」を選びます。
  - Make-Dock-App.command をダブルクリックすると ~/Applications/VPN-$U.app を作ります。
    それを Dock にドラッグすると、クリックで接続を始められます。
    (作成後にこのフォルダを移動・削除すると動かなくなります。その場合は作り直してください)
  - どの方法でも、管理者パスワードと VPN パスワードの入力は毎回必要です。

VPN を通る通信: $VPN_ROUTES 宛てのみ (それ以外の通信は VPN を通りません)

ファイル
  ca.crt      サーバ検証用の CA 証明書
  $U.crt      クライアント証明書
  $U.key      クライアント秘密鍵 (暗号化なし。他人に渡さない。不要になったらフォルダごと削除)
  connect.sh  接続スクリプト
  VPN-Connect.command    ダブルクリック用
  Make-Dock-App.command  Dock 用アプリの作成

接続先: $VPN_ADDR (サーバ識別名: $VPN_FQDN)
注意: iPhone / iPad では使えません。
TXT
tar -C "$T" -czf "$OUT" "vpn-$U"
