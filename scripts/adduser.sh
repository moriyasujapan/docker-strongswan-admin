#!/bin/bash
# 使い方: adduser.sh <username> [password]  -> pki/clients/<user>.p12 を生成
set -euo pipefail
. "$(dirname "$0")/common.sh"
U="${1:?username}"; [[ "$U" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "不正なユーザ名"; exit 1; }
"$(dirname "$0")/listusers.sh" | grep -qx -- "$U" && { echo "既に存在" >&2; exit 1; }
PASS="${2:-$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-16)}"
P12PASS="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-12)"
D="$PKI/clients/$U"; mkdir -p "$D"; cd "$PKI/ca"
openssl req -newkey rsa:3072 -nodes -keyout "$D/$U.key" -out "$D/$U.csr" -subj "/O=VPN/CN=$U" 2>/dev/null
# SAN(メール形式 user@FQDN)はユーザごとの拡張ファイルで渡す。ca.cnf に環境変数参照を置くと gencrl/revoke でも展開されて失敗する
EXTF="$(mktemp)"; trap 'rm -f "$EXTF"' EXIT
printf '[ext_client]\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=clientAuth\n' > "$EXTF"
[ "${ADDUSER_NO_SAN:-}" = 1 ] || printf 'subjectAltName=email:%s@%s\n' "$U" "$VPN_FQDN" >> "$EXTF"   # ADDUSER_NO_SAN=1 はテスト用(旧形式の証明書を再現)
openssl ca -batch -config ca.cnf -extfile "$EXTF" -extensions ext_client -in "$D/$U.csr" -out "$D/$U.crt" -notext 2>/dev/null
openssl pkcs12 -export -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 -inkey "$D/$U.key" -in "$D/$U.crt" -certfile ca.crt -name "$U" \
  -out "$D/$U.p12" -passout "pass:$P12PASS"
printf %s "$P12PASS" > "$D/$U.p12pass"   # 管理画面での再表示用
chmod 600 "$D"/*
rm -f "$D/$U.csr"
# セクション名にユーザ名を使わない: "." 等を含むと設定全体が文法エラーになり、全接続が読み込めなくなる
SEC="eap-u$(printf %s "$U" | sha256sum | cut -c1-16)"
cp -p "$SW/conf.d/users.conf" "$SW/conf.d/.users.conf.bak"
cat >> "$SW/conf.d/users.conf" <<CONF
secrets {
  $SEC {
    id = "$U"
    secret = "$PASS"
  }
}
CONF
if ! reload; then   # 設定が壊れた場合は元に戻す (VPN全体を止めない)
  mv "$SW/conf.d/.users.conf.bak" "$SW/conf.d/users.conf"; reload >/dev/null || true
  rm -rf "$D"; echo "設定の読み込みに失敗したため、ユーザ追加を取り消しました" >&2; exit 1
fi
rm -f "$SW/conf.d/.users.conf.bak"
echo "ユーザ: $U"; echo "パスワード: $PASS"; echo "p12: $D/$U.p12 (p12パスワード: $P12PASS)"
echo "CA証明書: $PKI/ca/ca.crt"
