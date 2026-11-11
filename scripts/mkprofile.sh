#!/bin/bash
# 使い方: mkprofile.sh android <username>   (標準出力にプロファイルを出力)
#   android : strongSwan Android アプリ用 .sswan (type=ikev2-cert-eap)
#   ※ iOS/macOS 標準クライアントは証明書+パスワードの併用ができないため .mobileconfig は提供しない (Mac は mkmacbundle.sh)
# .p12 のパスワードはプロファイルに含めない (インポート時にユーザが入力)。VPNパスワードも含めない (接続時に入力)。
set -euo pipefail
. "$(dirname "$0")/common.sh"
KIND="${1:?android}"; [ "$KIND" = android ] || { echo "kind は android のみ" >&2; exit 1; }; U="${2:?username}"
[[ "$U" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "不正なユーザ名" >&2; exit 1; }
D="$PKI/clients/$U"
[ -f "$D/$U.p12" ] && [ -f "$D/$U.crt" ] || { echo "ユーザが存在しません: $U" >&2; exit 1; }
CA_DER="$(mktemp)"; trap 'rm -f "$CA_DER"' EXIT
openssl x509 -in "$PKI/ca/ca.crt" -outform DER -out "$CA_DER"
python3 - "$KIND" "$U" "$VPN_FQDN" "$D/$U.p12" "$CA_DER" "$VPN_ADDR" "$VPN_ROUTES" <<'PY'
import sys, uuid, json, base64
kind, user, fqdn, p12_path, ca_path, addr, routes = sys.argv[1:8]
p12 = open(p12_path, "rb").read(); ca = open(ca_path, "rb").read()
if kind == "android":
    prof = {
        "uuid": str(uuid.uuid4()),
        "name": f"VPN {fqdn} ({user})",
        "type": "ikev2-cert-eap",
        "remote": {"addr": addr, "id": fqdn, "cert": base64.b64encode(ca).decode()},
        "local": {"eap_id": user, "p12": base64.b64encode(p12).decode()},
        "split-tunneling": {"subnets": [r.strip() for r in routes.split(",") if r.strip()]},
        "ike-proposal": "aes256-sha256-modp2048",
        "esp-proposal": "aes256-sha256",
    }
    sys.stdout.write(json.dumps(prof, indent=2, ensure_ascii=False) + "\n")
else:
    sys.exit("kind は android のみ")
PY
