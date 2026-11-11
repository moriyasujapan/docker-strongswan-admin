#!/bin/bash
# CA・サーバ証明書・CRL・swanctl.conf を生成
set -euo pipefail
. "$(dirname "$0")/common.sh"
[ -f "$PKI/ca/ca.key" ] && { echo "既にPKIが存在します"; exit 1; }
mkdir -p "$PKI/ca/newcerts" "$PKI/clients" "$SW"/{x509ca,x509,private,x509crl,conf.d}
cd "$PKI/ca"; : > index.txt; echo 1000 > serial; echo 1000 > crlnumber
cat > ca.cnf <<CNF
[ca]
default_ca=CA
[CA]
dir=.
database=\$dir/index.txt
new_certs_dir=\$dir/newcerts
serial=\$dir/serial
crlnumber=\$dir/crlnumber
private_key=\$dir/ca.key
certificate=\$dir/ca.crt
default_md=sha256
default_days=825
default_crl_days=30
crl_extensions=crl_ext
policy=any
unique_subject=no
[crl_ext]
authorityKeyIdentifier=keyid:always
[any]
commonName=supplied
organizationName=optional
emailAddress=optional
[ext_server]
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth,1.3.6.1.5.5.7.3.17
subjectAltName=DNS:$VPN_FQDN
[ext_client]
basicConstraints=CA:FALSE
keyUsage=digitalSignature
extendedKeyUsage=clientAuth
CNF
openssl req -x509 -newkey rsa:4096 -nodes -keyout ca.key -out ca.crt -days 3650 \
  -subj "/O=VPN/CN=VPN Root CA" -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
chmod 600 ca.key
openssl req -newkey rsa:3072 -nodes -keyout server.key -out server.csr -subj "/O=VPN/CN=$VPN_FQDN" 2>/dev/null
openssl ca -batch -config ca.cnf -extensions ext_server -in server.csr -out server.crt -notext 2>/dev/null
openssl ca -config ca.cnf -gencrl -out ca.crl 2>/dev/null
cp ca.crt "$SW/x509ca/"; cp server.crt "$SW/x509/"; cp server.key "$SW/private/"; chmod 600 "$SW/private/server.key"
openssl crl -in ca.crl -outform DER -out "$SW/x509crl/ca.crl"
cat > "$SW/swanctl.conf" <<CONF
connections {
  rw {
    version = 2
    proposals = aes256gcm16-prfsha384-ecp384,aes256-sha256-modp2048,aes256-sha256-ecp256
    pools = vpn-pool
    dpd_delay = 30s   # 応答のない端末のセッションを自動で片付ける (死活監視)
    local {
      auth = pubkey
      certs = server.crt
      id = $VPN_FQDN
    }
    # 1回目: クライアント証明書、2回目: ユーザ名+パスワード (EAP-MSCHAPv2)
    remote {
      auth = pubkey
      cacerts = ca.crt
    }
    remote2 {
      auth = eap-mschapv2
      eap_id = %any
    }
    children {
      rw {
        # VPNに通す宛先 (スプリットトンネル)。クライアントが全通信を要求してもこの範囲に絞られる
        local_ts = $VPN_ROUTES
        esp_proposals = aes256gcm16-ecp384,aes256-sha256-modp2048,aes256-sha256
      }
    }
  }
}
pools {
  vpn-pool {
    addrs = ${VPN_POOL:-192.168.90.128/25}
$( [ -n "${DNS:-}" ] && echo "    dns = $DNS" )
  }
}
include conf.d/*.conf
CONF
: > "$SW/conf.d/users.conf"
echo "PKI初期化完了: $PKI"
