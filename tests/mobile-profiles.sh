#!/bin/bash
# クライアント用配布物のテスト
#  Android: .sswan (strongSwan アプリ用) の構造検証 + 同じ値の swanctl クライアントで接続
#  Mac    : 接続一式 (tar.gz) の内容検証 + 同梱の connect.sh を本物の charon-cmd で実行して接続 (Linux コンテナ上)
#  ※ Android / Mac の実機での動作は未検証 (TEST.md 参照)
cd "$(dirname "$0")/.."
DOCKER="docker"; docker info >/dev/null 2>&1 || DOCKER="sudo docker"
PW=$(sudo grep '^ADMIN_PASSWORD=' .env | cut -d= -f2); B=https://localhost:8443
FQDN=$(grep '^VPN_FQDN=' vpn.env | cut -d= -f2); ADDR=$(grep '^VPN_ADDR=' vpn.env | cut -d= -f2); ADDR=${ADDR:-$FQDN}
. tests/legacy-user.sh; legacy_setup
U=profuser; W=$(mktemp -d); rc=0
A=(-sk -m 60 -u "admin:$PW"); H=(-H "Origin: $B" -H "X-Requested-With: vpn-admin" -H "Content-Type: application/json")
ok(){ echo "PASS $1"; }; ng(){ echo "FAIL $1"; rc=1; }
established(){ echo "$1" | grep -q "CHILD_SA .* established"; }
curl "${A[@]}" "${H[@]}" -X DELETE $B/api/users/$U >/dev/null 2>&1
R=$(curl "${A[@]}" "${H[@]}" -X POST -d "{\"user\":\"$U\"}" $B/api/users)
VPNPW=$(echo "$R" | python3 -c "import sys,json;print(json.load(sys.stdin)['pw'])"); P12PW=$(echo "$R" | python3 -c "import sys,json;print(json.load(sys.stdin)['p12pw'])")
[ -n "$VPNPW" ] && ok "テスト用ユーザ $U を作成" || { ng "ユーザ作成"; exit 1; }
code(){ curl "${A[@]}" -o "$W/$2" -w '%{http_code}' $B/dl/$1; }

# ================= Android (.sswan) =================
[ "$(code $U.sswan $U.sswan)" = 200 ] && ok "Android: .sswan をダウンロード (HTTP 200)" || ng ".sswan のダウンロード"
[ "$(curl "${A[@]}" -o /dev/null -w '%{http_code}' $B/dl/$LEGACY_USER.sswan)" = 200 ] && ok "Android: 旧形式(SANなし)の証明書のユーザでも .sswan を生成できる" || ng "旧形式ユーザの .sswan"
[ "$(curl -sk -m 10 -o /dev/null -w '%{http_code}' $B/dl/$U.sswan)" = 401 ] && ok "認証なしでの .sswan 取得は401" || ng "未認証で .sswan を取得できる"
[ "$(curl "${A[@]}" -o /dev/null -w '%{http_code}' $B/dl/$U.mobileconfig)" = 404 ] && ok "iOS/Mac 標準クライアント用 .mobileconfig は提供しない (404。MFAで動かないため)" || ng ".mobileconfig が404でない"
python3 -I - "$W" "$U" "$FQDN" "$P12PW" "$ADDR" <<'PY' || rc=1
import sys, json, base64, subprocess, uuid
W, U, FQDN, P12PW, ADDR = sys.argv[1:6]; res=[]
def chk(n, c): print(("PASS " if c else "FAIL ")+n); res.append(c)
ca_der = subprocess.run(["openssl","x509","-in","pki/ca/ca.crt","-outform","DER"], capture_output=True).stdout
s = json.load(open(f"{W}/{U}.sswan"))
chk("Android: JSONとして正しく読める / uuid は UUIDv4", uuid.UUID(s["uuid"]).version == 4)
chk("Android: type=ikev2-cert-eap (証明書 → ユーザ名/パスワード)", s["type"]=="ikev2-cert-eap")
chk("Android: remote.addr=接続先(VPN_ADDR)、remote.id=サーバFQDN(証明書SAN)", s["remote"]["addr"]==ADDR and s["remote"]["id"]==FQDN)
chk("Android: remote.cert が ca.crt と一致 (Base64 DER)", base64.b64decode(s["remote"]["cert"])==ca_der)
chk("Android: local.eap_id がユーザ名", s["local"]["eap_id"]==U)
chk("Android: split-tunneling.subnets が VPN_ROUTES (192.168.90.0/24 のみVPN経由)", s.get("split-tunneling",{}).get("subnets")==["192.168.90.0/24"])
open(f"{W}/android.p12","wb").write(base64.b64decode(s["local"]["p12"]))
r = subprocess.run(["openssl","pkcs12","-in",f"{W}/android.p12","-passin",f"pass:{P12PW}","-nodes"], capture_output=True, text=True)
open(f"{W}/android.pem","w").write(r.stdout)
chk("Android: local.p12 が .p12 パスワードで開け、証明書と秘密鍵を含む", r.returncode==0 and "BEGIN CERTIFICATE" in r.stdout and "PRIVATE KEY" in r.stdout)
chk("Android: パスワード(shared_secret等)を埋め込んでいない", "shared_secret" not in s["local"] and "password" not in json.dumps(s).lower())
open(f"{W}/android-ca.der","wb").write(base64.b64decode(s["remote"]["cert"]))
sys.exit(0 if all(res) else 1)
PY
android(){ # $1=EAPパスワード  (.sswan の値だけを使う swanctl クライアント)
  local T=$W/c-android-$RANDOM; mkdir -p $T/{x509ca,x509,private}
  openssl x509 -in $W/android.pem -out $T/x509/c.crt; openssl pkey -in $W/android.pem -out $T/private/c.key
  openssl x509 -inform DER -in $W/android-ca.der -out $T/x509ca/ca.crt
  cat > $T/swanctl.conf <<CONF
connections {
  c {
    version = 2
    remote_addrs = 192.168.90.10
    vips = 0.0.0.0
    proposals = aes256-sha256-modp2048
    local {
      auth = pubkey
      certs = c.crt
    }
    local2 {
      auth = eap-mschapv2
      eap_id = $U
    }
    remote {
      auth = pubkey
      id = $FQDN
    }
    children {
      c {
        remote_ts = 0.0.0.0/0
        esp_proposals = aes256-sha256
      }
    }
  }
}
secrets {
  eap-c {
    id = $U
    secret = "$1"
  }
}
CONF
  timeout 60 $DOCKER run --rm --network strongswan_vpn --cap-add NET_ADMIN -v $T:/etc/swanctl --entrypoint sh local/strongswan-swanctl:1 -c 'mkdir -p /run/vici; /usr/sbin/charon-systemd >/dev/null 2>&1 & sleep 3; swanctl --load-all >/dev/null 2>&1; timeout 25 swanctl --initiate --child c 2>&1 | grep -E "CHILD_SA .* established|AUTH_FAILED|EAP.*failed|failed"'
}
OUT=$(android "$VPNPW"); established "$OUT" && ok "Android風クライアント(.sswan の値: 証明書+EAP)で接続成功" || ng "Android風クライアントで接続失敗: $OUT"
echo "$OUT" | grep -q "=== 192.168.90.0/24" && ok "全通信(0.0.0.0/0)を要求しても、サーバが 192.168.90.0/24 に絞る (スプリットトンネル)" || ng "トラフィックセレクタが絞られていない: $OUT"
OUT=$(android "wrong-password"); established "$OUT" && ng "Android風: 誤パスワードで接続できてしまった" || ok "Android風クライアント: 誤パスワードは拒否"

# ================= Mac (Homebrew strongSwan / charon-cmd 用の一式) =================
[ "$(code $U.tgz mac.tgz)" = 200 ] && ok "Mac: 接続一式 (tar.gz) をダウンロード (HTTP 200)" || ng "Mac用一式のダウンロード"
[ "$(curl -sk -m 10 -o /dev/null -w '%{http_code}' $B/dl/$U.tgz)" = 401 ] && ok "Mac: 認証なしでの取得は401" || ng "未認証で Mac 用一式を取得できる"
mkdir -p $W/mac && tar -C $W/mac -xzf $W/mac.tgz 2>/dev/null; M=$W/mac/vpn-$U
[ "$(ls $M 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')" = "Make-Dock-App.command README.txt VPN-Connect.command ca.crt connect.sh $U.crt $U.key " ] && ok "Mac: 一式の内容 (ca.crt / 証明書 / 秘密鍵 / connect.sh / README.txt / ダブルクリック用・Dock用 .command)" || ng "Mac用一式の内容: $(ls $M 2>/dev/null | tr '\n' ' ')"
cmp -s $M/ca.crt pki/ca/ca.crt && openssl verify -CAfile $M/ca.crt $M/$U.crt >/dev/null 2>&1 && ok "Mac: 同梱の CA が ca.crt と一致し、クライアント証明書を検証できる" || ng "Mac: 証明書の検証"
[ "$(openssl x509 -in $M/$U.crt -noout -pubkey | sha256sum)" = "$(openssl pkey -in $M/$U.key -pubout | sha256sum)" ] && ok "Mac: 秘密鍵が証明書と対応" || ng "Mac: 鍵の対応"
grep -q -- "--profile ikev2-pub-eap" $M/connect.sh && grep -q -- "--eap-identity \"$U\"" $M/connect.sh && grep -q -- "--remote-identity \"$FQDN\"" $M/connect.sh && grep -q "VPN_HOST:-$ADDR" $M/connect.sh && ok "Mac: connect.sh は証明書→EAPの2段階 (ikev2-pub-eap)、接続先=VPN_ADDR、識別名=FQDN" || ng "Mac: connect.sh の内容"
grep -q -- "--remote-ts 192.168.90.0/24" $M/connect.sh && ok "Mac: connect.sh は 192.168.90.0/24 宛てだけをVPNに通す (--remote-ts)" || ng "Mac: --remote-ts が無い"
[ -x $M/VPN-Connect.command ] && [ -x $M/Make-Dock-App.command ] && bash -n $M/VPN-Connect.command && bash -n $M/Make-Dock-App.command && grep -q "osacompile" $M/Make-Dock-App.command && ok "Mac: ダブルクリック用/Dock用 .command が実行可能で、シェルの構文として正しい (macOS での動作は未確認)" || ng "Mac: .command ファイル"
! grep -rq -- "$VPNPW" $M && ok "Mac: VPN パスワードを同梱していない (接続時に入力)" || ng "Mac: パスワードが同梱されている"
$DOCKER image inspect local/strongswan-cmdtest:1 >/dev/null 2>&1 || printf 'FROM local/strongswan-swanctl:1\nRUN apt-get update && apt-get install -y --no-install-recommends charon-cmd bsdutils && rm -rf /var/lib/apt/lists/*\n' | $DOCKER build -q -t local/strongswan-cmdtest:1 - >/dev/null
mac(){ # $1=入力するパスワード。同梱の connect.sh を本物の charon-cmd で実行 (疑似端末でパスワードを入力)
  # Debian の kernel-libipsec はコンテナ内でカーネルIPsecと競合するため無効化 (Homebrew 版には含まれない)
  timeout 70 $DOCKER run --rm --network strongswan_vpn --cap-add NET_ADMIN -e VPN_HOST=192.168.90.10 -e EAPPW="$1" -v $M:/b:ro --entrypoint sh local/strongswan-cmdtest:1 -c \
   'printf "charon-cmd {\n  plugins {\n    kernel-libipsec {\n      load = no\n    }\n  }\n}\n" >> /etc/strongswan.conf; cp -r /b /w && cd /w && (sleep 6; echo "$EAPPW"; sleep 12) | timeout 25 script -qec ./connect.sh /dev/null 2>&1 | grep -aE "CHILD_SA .* established|EAP.*(failed|succeeded)|AUTH_FAILED|installing new virtual IP|EAP password"' | tr -d '\r'
}
OUT=$(mac "$VPNPW"); established "$OUT" && ok "Mac用一式: connect.sh (charon-cmd, 証明書→パスワード) で接続成功 $(echo "$OUT" | grep -ao 'virtual IP [0-9.]*' | head -1)" || ng "Mac用一式で接続失敗: $OUT"
echo "$OUT" | grep -aq "=== 192.168.90.0/24" && ok "Mac用一式: トンネルの宛先は 192.168.90.0/24 のみ" || ng "Mac用一式: 宛先が 192.168.90.0/24 でない: $OUT"
echo "$OUT" | grep -aq "EAP password" && ok "Mac用一式: 接続時にパスワードの入力を求める" || ng "パスワードのプロンプトが出ない: $OUT"
OUT=$(mac "wrong-password"); established "$OUT" && ng "Mac用一式: 誤パスワードで接続できてしまった" || ok "Mac用一式: 誤パスワードは拒否"

curl "${A[@]}" "${H[@]}" -X DELETE $B/api/users/$U >/dev/null 2>&1; legacy_teardown; rm -rf "$W"
exit $rc
