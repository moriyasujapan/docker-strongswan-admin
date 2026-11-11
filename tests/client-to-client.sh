#!/bin/bash
# VPNクライアント同士の通信: 2台を同時に接続し、B → A に TCP 接続できること、A から見える送信元が B の仮想IPであること
cd "$(dirname "$0")/.."
DOCKER="docker"; docker info >/dev/null 2>&1 || DOCKER="sudo docker"
PW=$(sudo grep '^ADMIN_PASSWORD=' .env | cut -d= -f2); B=https://localhost:8443; FQDN=$(grep '^VPN_FQDN=' vpn.env | cut -d= -f2); rc=0
A=(-sk -m 60 -u "admin:$PW" -H "Origin: $B" -H "X-Requested-With: vpn-admin" -H "Content-Type: application/json")
ok(){ echo "PASS $1"; }; ng(){ echo "FAIL $1"; rc=1; }
$DOCKER image inspect local/strongswan-pytest:1 >/dev/null 2>&1 || printf 'FROM local/strongswan-swanctl:1\nRUN apt-get update && apt-get install -y --no-install-recommends python3-minimal && rm -rf /var/lib/apt/lists/*\n' | $DOCKER build -q -t local/strongswan-pytest:1 - >/dev/null
W=$(mktemp -d); mkdir -p $W/x; chmod 777 $W/x
mk(){ # $1=ユーザ → $W/$1 に swanctl 設定
  curl "${A[@]}" -X DELETE $B/api/users/$1 >/dev/null 2>&1
  local pw; pw=$(curl "${A[@]}" -X POST -d "{\"user\":\"$1\"}" $B/api/users | python3 -c "import sys,json;print(json.load(sys.stdin)['pw'])")
  local T=$W/$1; mkdir -p $T/{x509ca,x509,private}
  sudo cp pki/ca/ca.crt $T/x509ca/; sudo cp pki/clients/$1/$1.crt $T/x509/c.crt; sudo cp pki/clients/$1/$1.key $T/private/c.key; sudo chown -R $USER $T
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
      eap_id = $1
    }
    remote {
      auth = pubkey
      id = $FQDN
    }
    children {
      c {
        remote_ts = 192.168.90.0/24
        esp_proposals = aes256-sha256
      }
    }
  }
}
secrets {
  eap-c {
    id = $1
    secret = "$pw"
  }
}
CONF
}
mk c2ca; mk c2cb
UP='mkdir -p /run/vici; /usr/sbin/charon-systemd >/dev/null 2>&1 & sleep 3; swanctl --load-all >/dev/null 2>&1; VIP=$(timeout 25 swanctl --initiate --child c 2>&1 | grep -o "installing new virtual IP [0-9.]*" | grep -o "[0-9.]*$")'
$DOCKER run -d --rm --name c2c-a --network strongswan_vpn --cap-add NET_ADMIN -v $W/c2ca:/etc/swanctl -v $W/x:/x --entrypoint sh local/strongswan-pytest:1 -c "$UP"'; echo "$VIP" > /x/vipa; python3 -c "
import socket
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind((\"0.0.0.0\",9000)); s.listen(1); s.settimeout(40)
c,a=s.accept(); open(\"/x/peer\",\"w\").write(a[0]); c.send(b\"hello\"); c.close()"' >/dev/null
$DOCKER run --rm --name c2c-b --network strongswan_vpn --cap-add NET_ADMIN -v $W/c2cb:/etc/swanctl -v $W/x:/x --entrypoint sh local/strongswan-pytest:1 -c "$UP"'; echo "$VIP" > /x/vipb; for i in $(seq 1 20); do [ -s /x/vipa ] && break; sleep 1; done; python3 -c "
import socket
s=socket.socket(); s.settimeout(10)
try: s.connect((open(\"/x/vipa\").read().strip(),9000)); open(\"/x/got\",\"w\").write(s.recv(10).decode())
except Exception as e: open(\"/x/got\",\"w\").write(\"ERR \"+type(e).__name__)"' >/dev/null 2>&1
sleep 2; $DOCKER rm -f c2c-a >/dev/null 2>&1
VA=$(cat $W/x/vipa 2>/dev/null); VB=$(cat $W/x/vipb 2>/dev/null); PEER=$(cat $W/x/peer 2>/dev/null); GOT=$(cat $W/x/got 2>/dev/null)
[ -n "$VA" ] && [ -n "$VB" ] && [ "$VA" != "$VB" ] && ok "2台のクライアントが同時に接続し、別々の仮想IPを受け取る ($VA / $VB)" || ng "2台の接続: A=$VA B=$VB"
[ "$GOT" = hello ] && ok "クライアント B → A (仮想IP宛て) に TCP 接続できる" || ng "クライアント同士の通信: $GOT"
[ -n "$PEER" ] && [ "$PEER" = "$VB" ] && ok "A から見える送信元は B の仮想IP ($PEER。VPNサーバのIPに書き換わらない)" || ng "A から見える送信元が B の仮想IPでない (見えたIP: ${PEER:-なし} / Bの仮想IP: $VB)"
for u in c2ca c2cb; do curl "${A[@]}" -X DELETE $B/api/users/$u >/dev/null 2>&1; done; sudo rm -rf pki/clients/.revoked-c2c*
for i in $($DOCKER exec strongswan swanctl --list-sas 2>&1 | awk '/^rw: #/{id=$2; gsub(/[#,]/,"",id)} /EAP: .c2c[ab]./{print id}'); do $DOCKER exec strongswan swanctl --terminate --ike-id $i --force >/dev/null 2>&1; done
rm -rf "$W"
exit $rc
