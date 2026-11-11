#!/bin/bash
# iOS/Mac (.mobileconfig) と Android (.sswan) プロファイルのテスト
#  1) 管理画面で新規ユーザを作り、プロファイルをダウンロード  2) 構造・埋め込み証明書の検証
#  3) プロファイル内の値だけを使った swanctl クライアントで実際に接続 (iOS風/Android風)
#  ※ 実機のiOS/Android/macOSでの取り込み・接続は未検証 (README/TEST.md 参照)
cd "$(dirname "$0")/.."
. tests/legacy-user.sh; legacy_setup
DOCKER="docker"; docker info >/dev/null 2>&1 || DOCKER="sudo docker"
PW=$(sudo grep '^ADMIN_PASSWORD=' .env | cut -d= -f2); B=https://localhost:8443; FQDN=$(grep '^VPN_FQDN=' vpn.env | cut -d= -f2); ADDR=$(grep '^VPN_ADDR=' vpn.env | cut -d= -f2); ADDR=${ADDR:-$FQDN}
U=profuser; W=$(mktemp -d); rc=0
A=(-sk -m 60 -u "admin:$PW"); H=(-H "Origin: $B" -H "X-Requested-With: vpn-admin" -H "Content-Type: application/json")
ok(){ echo "PASS $1"; }; ng(){ echo "FAIL $1"; rc=1; }
curl "${A[@]}" "${H[@]}" -X DELETE $B/api/users/$U >/dev/null 2>&1
R=$(curl "${A[@]}" "${H[@]}" -X POST -d "{\"user\":\"$U\"}" $B/api/users)
VPNPW=$(echo "$R" | python3 -c "import sys,json;print(json.load(sys.stdin)['pw'])"); P12PW=$(echo "$R" | python3 -c "import sys,json;print(json.load(sys.stdin)['p12pw'])")
[ -n "$VPNPW" ] && ok "テスト用ユーザ $U を作成" || { ng "ユーザ作成"; exit 1; }

code(){ curl "${A[@]}" -o "$W/$2" -w '%{http_code}' $B/dl/$1; }
[ "$(code $U.mobileconfig $U.mobileconfig)" = 200 ] && ok "iOS/Mac: .mobileconfig をダウンロード (HTTP 200)" || ng ".mobileconfig のダウンロード"
[ "$(code $U.sswan $U.sswan)" = 200 ] && ok "Android: .sswan をダウンロード (HTTP 200)" || ng ".sswan のダウンロード"
[ "$(curl "${A[@]}" -o /dev/null -w '%{http_code}' $B/dl/$LEGACY_USER.mobileconfig)" = 409 ] && ok "旧形式の証明書(SANなし)のiOS/Mac用は409で再発行を促す" || ng "alice.mobileconfig が409でない"
[ "$(curl "${A[@]}" -o /dev/null -w '%{http_code}' $B/dl/$LEGACY_USER.sswan)" = 200 ] && ok "旧形式の証明書でもAndroid用(.sswan)は生成できる (HTTP 200)" || ng "alice.sswan"
[ "$(curl -sk -m 10 -o /dev/null -w '%{http_code}' $B/dl/$U.sswan)" = 401 ] && ok "認証なしでのプロファイル取得は401" || ng "未認証で取得できてしまう"

# --- 構造の検証 + 埋め込み証明書の取り出し ---
python3 -I - "$W" "$U" "$FQDN" "$P12PW" "$ADDR" <<'PY' || rc=1
import sys, json, plistlib, base64, subprocess, uuid, os
W, U, FQDN, P12PW, ADDR = sys.argv[1:6]
res = []
def chk(name, cond): print(("PASS " if cond else "FAIL ") + name); res.append(cond)
ca_der = subprocess.run(["openssl","x509","-in","pki/ca/ca.crt","-outform","DER"], capture_output=True).stdout

def p12_ok(data, tag):
    open(f"{W}/{tag}.p12","wb").write(data)
    r = subprocess.run(["openssl","pkcs12","-in",f"{W}/{tag}.p12","-passin",f"pass:{P12PW}","-nodes"], capture_output=True, text=True)
    open(f"{W}/{tag}.pem","w").write(r.stdout)
    return r.returncode == 0 and "BEGIN CERTIFICATE" in r.stdout and "PRIVATE KEY" in r.stdout

# ---- Apple ----
p = plistlib.load(open(f"{W}/{U}.mobileconfig","rb"))
pl = {x["PayloadType"]: x for x in p["PayloadContent"]}
chk("Apple: plistとして正しく読め、構成プロファイルである", p["PayloadType"] == "Configuration")
chk("Apple: CA/PKCS12/VPN の3ペイロードを含む", set(pl) == {"com.apple.security.root","com.apple.security.pkcs12","com.apple.vpn.managed"})
v = pl["com.apple.vpn.managed"]["IKEv2"]
chk("Apple: IKEv2 + 証明書認証 + EAP(ExtendedAuthEnabled=1)", pl["com.apple.vpn.managed"]["VPNType"]=="IKEv2" and v["AuthenticationMethod"]=="Certificate" and v["ExtendedAuthEnabled"]==1)
chk("Apple: RemoteAddress=接続先(VPN_ADDR)、RemoteIdentifier=サーバFQDN(証明書SAN)", v["RemoteAddress"]==ADDR and v["RemoteIdentifier"]==FQDN)
chk("Apple: AuthName がユーザ名、LocalIdentifier が証明書SANのメール", v["AuthName"]==U and v["LocalIdentifier"]==f"{U}@{FQDN}")
chk("Apple: PayloadCertificateUUID が PKCS12 ペイロードを指す", v["PayloadCertificateUUID"]==pl["com.apple.security.pkcs12"]["PayloadUUID"])
uuids=[x["PayloadUUID"] for x in p["PayloadContent"]]+[p["PayloadUUID"]]
chk("Apple: PayloadUUID が全て異なる", len(set(uuids))==4)
chk("Apple: CAペイロードが ca.crt と一致 (DER)", pl["com.apple.security.root"]["PayloadContent"]==ca_der)
chk("Apple: p12 が .p12 パスワードで開け、証明書と秘密鍵を含む", p12_ok(pl["com.apple.security.pkcs12"]["PayloadContent"], "apple"))
chk("Apple: パスワード類(p12/VPN)をプロファイルに埋め込んでいない", "Password" not in pl["com.apple.security.pkcs12"] and "AuthPassword" not in v)
san = subprocess.run(["openssl","x509","-in",f"{W}/apple.pem","-noout","-ext","subjectAltName"], capture_output=True, text=True).stdout
chk("Apple: 埋め込み証明書のSANが LocalIdentifier と一致", f"email:{U}@{FQDN}" in san)

# ---- Android ----
s = json.load(open(f"{W}/{U}.sswan"))
chk("Android: JSONとして正しく読める / uuid は UUIDv4", uuid.UUID(s["uuid"]).version == 4)
chk("Android: type=ikev2-cert-eap (証明書 → ユーザ名/パスワード)", s["type"]=="ikev2-cert-eap")
chk("Android: remote.addr=接続先(VPN_ADDR)、remote.id=サーバFQDN(証明書SAN)", s["remote"]["addr"]==ADDR and s["remote"]["id"]==FQDN)
chk("Android: remote.cert が ca.crt と一致 (Base64 DER)", base64.b64decode(s["remote"]["cert"])==ca_der)
chk("Android: local.eap_id がユーザ名", s["local"]["eap_id"]==U)
chk("Android: local.p12 が .p12 パスワードで開け、証明書と秘密鍵を含む", p12_ok(base64.b64decode(s["local"]["p12"]), "android"))
chk("Android: パスワード(shared_secret等)を埋め込んでいない", "shared_secret" not in s["local"] and "password" not in json.dumps(s).lower())
sys.exit(0 if all(res) else 1)
PY

# --- プロファイルの値だけで実接続 (iOS風 / Android風) ---
connect(){ # $1=名前 $2=local id行 $3=ike提案 $4=esp提案 $5=pem接頭辞 $6=EAPパスワード $7=eap_id
  local T=$W/c-$1-$RANDOM; mkdir -p $T/{x509ca,x509,private}
  openssl x509 -in $W/$5.pem -out $T/x509/c.crt; openssl pkey -in $W/$5.pem -out $T/private/c.key
  openssl x509 -inform DER -in <(python3 -I -c "
import sys,json,base64,plistlib
W,U,k=sys.argv[1:4]
if k=='apple':
    d=[x for x in plistlib.load(open(f'{W}/{U}.mobileconfig','rb'))['PayloadContent'] if x['PayloadType']=='com.apple.security.root'][0]['PayloadContent']
else:
    d=base64.b64decode(json.load(open(f'{W}/{U}.sswan'))['remote']['cert'])
sys.stdout.buffer.write(d)" $W $U $1) -out $T/x509ca/ca.crt
  cat > $T/swanctl.conf <<CONF
connections {
  c {
    version = 2
    remote_addrs = 192.168.90.10
    vips = 0.0.0.0
    proposals = $3
    local {
      auth = pubkey
      certs = c.crt
$2
    }
    local2 {
      auth = eap-mschapv2
      eap_id = $7
    }
    remote {
      auth = pubkey
      id = $FQDN
    }
    children {
      c {
        remote_ts = 0.0.0.0/0
        esp_proposals = $4
      }
    }
  }
}
secrets {
  eap-c {
    id = $7
    secret = "$6"
  }
}
CONF
  timeout 60 $DOCKER run --rm --network strongswan_vpn --cap-add NET_ADMIN -v $T:/etc/swanctl --entrypoint sh local/strongswan-swanctl:1 -c 'mkdir -p /run/vici; /usr/sbin/charon-systemd >/dev/null 2>&1 & sleep 3; swanctl --load-all >/dev/null 2>&1; timeout 25 swanctl --initiate --child c 2>&1 | grep -E "CHILD_SA .* established|AUTH_FAILED|EAP.*failed|NO_PROPOSAL|failed"'
}
OUT=$(connect apple "      id = $U@$FQDN" "aes256-sha256-modp2048" "aes256-sha256-modp2048" apple "$VPNPW" $U); echo "$OUT" | grep -q "CHILD_SA .* established" && ok "iOS風クライアント(プロファイルの値: ID=メールSAN, IKE=AES256/SHA2-256/DH14, ESP+PFS DH14, 証明書+EAP)で接続成功" || { ng "iOS風クライアントで接続失敗: $OUT"; }
OUT=$(connect apple "      id = $U@$FQDN" "aes256-sha256-modp2048" "aes256-sha256-modp2048" apple "wrong-password" $U); echo "$OUT" | grep -q "CHILD_SA .* established" && ng "iOS風: 誤パスワードで接続できてしまった" || ok "iOS風クライアント: 誤パスワードは拒否"
OUT=$(connect android "" "aes256-sha256-modp2048" "aes256-sha256" android "$VPNPW" $U); echo "$OUT" | grep -q "CHILD_SA .* established" && ok "Android風クライアント(プロファイルの値: ID=証明書DN, IKE=aes256-sha256-modp2048, ESP=aes256-sha256, 証明書+EAP)で接続成功" || { ng "Android風クライアントで接続失敗: $OUT"; }
OUT=$(connect android "" "aes256-sha256-modp2048" "aes256-sha256" android "wrong-password" $U); echo "$OUT" | grep -q "CHILD_SA .* established" && ng "Android風: 誤パスワードで接続できてしまった" || ok "Android風クライアント: 誤パスワードは拒否"

curl "${A[@]}" "${H[@]}" -X DELETE $B/api/users/$U >/dev/null 2>&1; legacy_teardown; rm -rf "$W"
exit $rc
