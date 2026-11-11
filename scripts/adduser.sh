#!/bin/bash
# 使い方: adduser.sh <username> [password]  -> pki/clients/<user>.p12 を生成
set -euo pipefail
. "$(dirname "$0")/common.sh"
U="${1:?username}"; [[ "$U" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "不正なユーザ名"; exit 1; }
grep -q "eap-$U " "$SW/conf.d/users.conf" 2>/dev/null && { echo "既に存在"; exit 1; }
PASS="${2:-$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-16)}"
P12PASS="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-12)"
D="$PKI/clients/$U"; mkdir -p "$D"; cd "$PKI/ca"
openssl req -newkey rsa:3072 -nodes -keyout "$D/$U.key" -out "$D/$U.csr" -subj "/O=VPN/CN=$U" 2>/dev/null
openssl ca -batch -config ca.cnf -extensions ext_client -in "$D/$U.csr" -out "$D/$U.crt" -notext 2>/dev/null
openssl pkcs12 -export -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 -inkey "$D/$U.key" -in "$D/$U.crt" -certfile ca.crt -name "$U" \
  -out "$D/$U.p12" -passout "pass:$P12PASS"
printf %s "$P12PASS" > "$D/$U.p12pass"   # 管理画面での再表示用
chmod 600 "$D"/*
rm -f "$D/$U.csr"
cat >> "$SW/conf.d/users.conf" <<CONF
secrets {
  eap-$U {
    id = $U
    secret = "$PASS"
  }
}
CONF
reload
echo "ユーザ: $U"; echo "パスワード: $PASS"; echo "p12: $D/$U.p12 (p12パスワード: $P12PASS)"
echo "CA証明書: $PKI/ca/ca.crt"
