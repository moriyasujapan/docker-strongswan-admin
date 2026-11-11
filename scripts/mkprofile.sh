#!/bin/bash
# 使い方: mkprofile.sh <apple|android> <username>   (標準出力にプロファイルを出力)
#   apple   : iOS/macOS 用 .mobileconfig  (クライアント証明書のSANが必要。旧証明書は exit 2)
#   android : strongSwan Android アプリ用 .sswan (type=ikev2-cert-eap)
# .p12 のパスワードはプロファイルに含めない (インポート時にユーザが入力)。VPNパスワードも含めない (接続時に入力)。
set -euo pipefail
. "$(dirname "$0")/common.sh"
KIND="${1:?apple|android}"; U="${2:?username}"
[[ "$U" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "不正なユーザ名" >&2; exit 1; }
D="$PKI/clients/$U"
[ -f "$D/$U.p12" ] && [ -f "$D/$U.crt" ] || { echo "ユーザが存在しません: $U" >&2; exit 1; }
if [ "$KIND" = apple ]; then
  openssl x509 -in "$D/$U.crt" -noout -ext subjectAltName 2>/dev/null | grep -q "email:$U@$VPN_FQDN" \
    || { echo "この証明書は旧形式(SANなし)のため iOS/Mac 用プロファイルを作れません。「再発行」してください" >&2; exit 2; }
fi
CA_DER="$(mktemp)"; trap 'rm -f "$CA_DER"' EXIT
openssl x509 -in "$PKI/ca/ca.crt" -outform DER -out "$CA_DER"
python3 - "$KIND" "$U" "$VPN_FQDN" "$D/$U.p12" "$CA_DER" "$VPN_ADDR" <<'PY'
import sys, uuid, json, base64, plistlib
kind, user, fqdn, p12_path, ca_path, addr = sys.argv[1:7]
p12 = open(p12_path, "rb").read(); ca = open(ca_path, "rb").read()
if kind == "android":
    prof = {
        "uuid": str(uuid.uuid4()),
        "name": f"VPN {fqdn} ({user})",
        "type": "ikev2-cert-eap",
        "remote": {"addr": addr, "id": fqdn, "cert": base64.b64encode(ca).decode()},
        "local": {"eap_id": user, "p12": base64.b64encode(p12).decode()},
        "ike-proposal": "aes256-sha256-modp2048",
        "esp-proposal": "aes256-sha256",
    }
    sys.stdout.write(json.dumps(prof, indent=2, ensure_ascii=False) + "\n")
elif kind == "apple":
    ident = f"local.vpn.{fqdn}.{user}"
    u_ca, u_p12, u_vpn, u_top = (str(uuid.uuid4()).upper() for _ in range(4))
    sa = {"EncryptionAlgorithm": "AES-256", "IntegrityAlgorithm": "SHA2-256", "DiffieHellmanGroup": 14, "LifeTimeInMinutes": 1440}
    prof = {
        "PayloadType": "Configuration", "PayloadVersion": 1, "PayloadUUID": u_top,
        "PayloadIdentifier": ident, "PayloadDisplayName": f"VPN {fqdn} ({user})",
        "PayloadDescription": "IKEv2 クライアント証明書 + ユーザ名/パスワード", "PayloadOrganization": "VPN",
        "PayloadContent": [
            {"PayloadType": "com.apple.security.root", "PayloadVersion": 1, "PayloadUUID": u_ca,
             "PayloadIdentifier": f"{ident}.ca", "PayloadDisplayName": "VPN Root CA", "PayloadContent": ca},
            {"PayloadType": "com.apple.security.pkcs12", "PayloadVersion": 1, "PayloadUUID": u_p12,
             "PayloadIdentifier": f"{ident}.cert", "PayloadDisplayName": f"{user} クライアント証明書", "PayloadContent": p12},
            {"PayloadType": "com.apple.vpn.managed", "PayloadVersion": 1, "PayloadUUID": u_vpn,
             "PayloadIdentifier": f"{ident}.vpn", "PayloadDisplayName": f"VPN {fqdn}",
             "UserDefinedName": f"VPN ({fqdn})", "VPNType": "IKEv2",
             "IKEv2": {
                 "RemoteAddress": addr, "RemoteIdentifier": fqdn, "LocalIdentifier": f"{user}@{fqdn}",
                 "AuthenticationMethod": "Certificate", "PayloadCertificateUUID": u_p12,
                 "ExtendedAuthEnabled": 1, "AuthName": user,
                 "ServerCertificateIssuerCommonName": "VPN Root CA", "ServerCertificateCommonName": fqdn,
                 "DeadPeerDetectionRate": "Medium", "EnablePFS": 1,
                 "IKESecurityAssociationParameters": sa, "ChildSecurityAssociationParameters": dict(sa),
             }},
        ],
    }
    sys.stdout.write(plistlib.dumps(prof).decode())
else:
    sys.exit("kind は apple か android")
PY
