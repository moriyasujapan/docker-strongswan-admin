#!/bin/bash
cd "$(dirname "$0")/.."
DOCKER="docker"; docker info >/dev/null 2>&1 || DOCKER="sudo docker"
S=$(mktemp -d)
FQDN=$(grep "^VPN_FQDN=" vpn.env | cut -d= -f2)
try(){ U=$1; PW=$2; T=$S/cl-$U-$RANDOM; mkdir -p $T/{x509ca,x509,private}
 sudo cp pki/ca/ca.crt $T/x509ca/; sudo cp ${CERT_DIR:-pki/clients/$U}/$U.crt $T/x509/; sudo cp ${CERT_DIR:-pki/clients/$U}/$U.key $T/private/
 cat > $T/swanctl.conf <<CONF
connections {
  c {
    version = 2
    remote_addrs = 192.168.90.10
    vips = 0.0.0.0
    local {
      auth = pubkey
      certs = $U.crt
      id = "CN=$U, O=VPN"
    }
    local2 {
      auth = eap-mschapv2
      eap_id = $U
      id = $U
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
    secret = "$PW"
  }
}
CONF
 echo "== $U (password: ${3})"
 timeout 60 $DOCKER run --rm --network "${NET:-strongswan_vpn}" --cap-add NET_ADMIN -v $T:/etc/swanctl --entrypoint sh local/strongswan-swanctl:1 -c 'mkdir -p /run/vici; /usr/sbin/charon-systemd >/dev/null 2>&1 & sleep 3; swanctl --load-all >/dev/null 2>&1; timeout 20 swanctl --initiate --child c 2>&1 | grep -E "established between|CHILD_SA .* established|EAP_MSCHAPV2 failed|failed" | grep -v plugin | cut -c1-170'; }
pw(){ sudo grep -A2 "eap-$1 " swanctl/conf.d/users.conf | grep secret | cut -d'"' -f2; }
USERS=("$@"); [ ${#USERS[@]} -eq 0 ] && USERS=(alice bob)
for u in "${USERS[@]}"; do try "$u" "$(pw "$u")" correct; done
try "${USERS[0]}" "wrong-password" WRONG
rm -rf "$S"
