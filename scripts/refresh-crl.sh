#!/bin/bash
# CRL を再発行してサーバへ反映する (有効期間30日のCRLが期限切れにならないよう定期実行する)
set -euo pipefail
. "$(dirname "$0")/common.sh"
cd "$PKI/ca"
openssl ca -config ca.cnf -gencrl -out ca.crl 2>/dev/null
openssl crl -in ca.crl -outform DER -out "$SW/x509crl/ca.crl"
chmod 644 "$SW/x509crl/ca.crl"
reload >/dev/null
echo "CRL更新: $(openssl crl -in ca.crl -noout -crlnumber) $(openssl crl -in ca.crl -noout -nextupdate)"
