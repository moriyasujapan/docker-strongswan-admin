#!/bin/bash
# 使い方: deluser.sh <username>  -> 証明書失効 + パスワード削除
set -euo pipefail
. "$(dirname "$0")/common.sh"
U="${1:?username}"; D="$PKI/clients/$U"; [ -f "$D/$U.crt" ] || { echo "不明なユーザ"; exit 1; }
cd "$PKI/ca"
openssl ca -config ca.cnf -revoke "$D/$U.crt" 2>/dev/null || true
openssl ca -config ca.cnf -gencrl -out ca.crl 2>/dev/null
openssl crl -in ca.crl -outform DER -out "$SW/x509crl/ca.crl"
python3 - "$SW/conf.d/users.conf" "$U" <<'PY'
import re,sys
f,u=sys.argv[1:]; s=open(f).read()
s=re.sub(r"secrets \{\n  eap-%s \{.*?\n  \}\n\}\n"%re.escape(u),"",s,flags=re.S)
open(f,"w").write(s)
PY
mv "$D" "$PKI/clients/.revoked-$U-$(date +%s)"
reload; echo "失効完了: $U"
