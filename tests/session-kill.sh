#!/bin/bash
# ユーザの削除・再発行で、接続中のセッションが即時に切断されること。他のユーザのセッションは影響を受けないこと
cd "$(dirname "$0")/.."
DOCKER="docker"; docker info >/dev/null 2>&1 || DOCKER="sudo docker"
PW=$(sudo grep '^ADMIN_PASSWORD=' .env | cut -d= -f2); B=https://localhost:8443; FQDN=$(grep '^VPN_FQDN=' vpn.env | cut -d= -f2); rc=0
A=(-sk -m 90 -u "admin:$PW" -H "Origin: $B" -H "X-Requested-With: vpn-admin" -H "Content-Type: application/json")
ok(){ echo "PASS $1"; }; ng(){ echo "FAIL $1"; rc=1; }
W=$(mktemp -d)
sess(){ $DOCKER exec strongswan swanctl --list-sas 2>&1 | grep -cE "EAP: '$1'|remote '$1' @"; }
up(){ # $1=ユーザ $2=EAPラウンドで名乗るIKEのID(省略可): 作成して、接続を保持するクライアントを起動
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
$( [ -n "${2:-}" ] && echo "      id = $2" )
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
  $DOCKER rm -f sk-$1 >/dev/null 2>&1
  $DOCKER run -d --rm --name sk-$1 --network strongswan_vpn --cap-add NET_ADMIN -v $T:/etc/swanctl --entrypoint sh local/strongswan-swanctl:1 -c 'mkdir -p /run/vici; /usr/sbin/charon-systemd >/dev/null 2>&1 & sleep 3; swanctl --load-all >/dev/null 2>&1; swanctl --initiate --child c >/dev/null 2>&1; sleep 120' >/dev/null
}
up skdel; up skmod; up skkeep; up skid skid; sleep 9   # skid: IKE の ID としてユーザ名そのものを名乗るクライアント
[ "$(sess skdel)" = 1 ] && [ "$(sess skmod)" = 1 ] && [ "$(sess skkeep)" = 1 ] && ok "3ユーザが接続中 (削除対象 / 再発行対象 / 無関係)" || ng "事前の接続: del=$(sess skdel) mod=$(sess skmod) keep=$(sess skkeep)"
curl "${A[@]}" -X DELETE -o /dev/null $B/api/users/skdel; sleep 2
[ "$(sess skdel)" = 0 ] && ok "ユーザを削除すると、接続中のセッションが即時に切断される" || ng "【重大】削除後もセッションが残っている"
curl "${A[@]}" -X POST -o /dev/null $B/api/users/skmod/reissue; sleep 2
[ "$(sess skmod)" = 0 ] && ok "ユーザを再発行すると、旧証明書でつながっていたセッションが切断される" || ng "【重大】再発行後も旧セッションが残っている"
[ "$(sess skid)" = 1 ] && curl "${A[@]}" -X DELETE -o /dev/null $B/api/users/skid && sleep 2 && [ "$(sess skid)" = 0 ] && ok "IKE の ID がユーザ名そのもののクライアントも、削除で切断される" || ng "【重大】ID がユーザ名のクライアントのセッションが残っている (sess=$(sess skid))"
[ "$(sess skkeep)" = 1 ] && ok "無関係なユーザのセッションは切断されない" || ng "無関係なユーザのセッションが切れた"
$DOCKER exec strongswan swanctl --list-conns 2>&1 | grep -q "dpd" && ok "死活監視 (DPD) が接続設定に入っている" || ng "DPD が設定されていない"
for u in skdel skmod skkeep skid; do $DOCKER rm -f sk-$u >/dev/null 2>&1; curl "${A[@]}" -X DELETE -o /dev/null $B/api/users/$u 2>/dev/null; done
[ "$(sess skkeep)" = 0 ] && ok "後片付け: 残りのテスト用ユーザも削除でセッションが切れる" || ng "後片付けでセッションが残った"
sudo rm -rf pki/clients/.revoked-sk*; rm -rf "$W"
exit $rc
