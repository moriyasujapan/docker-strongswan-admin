#!/bin/bash
# CRL自動更新のテスト: 更新間隔を短くして管理画面を再起動し、CRL番号と更新日時が進むこと・サーバに反映されることを確認
cd "$(dirname "$0")/.."
DOCKER="docker"; docker info >/dev/null 2>&1 || DOCKER="sudo docker"
num(){ sudo openssl crl -in pki/ca/ca.crl -noout -crlnumber | cut -d= -f2 | sed "s/^0x//"; }
srv(){ $DOCKER exec strongswan swanctl --list-certs --type x509_crl 2>&1 | grep -E '^\s+serial:' | tail -1 | awk '{print $2}'; }
B=$(num); echo "更新前: CRL番号=$B サーバ側=$(srv)"
compose_up(){ if [ "$DOCKER" = docker ]; then CRL_REFRESH_HOURS=$1 docker compose up -d admin; else sudo env CRL_REFRESH_HOURS=$1 docker compose up -d admin; fi >/dev/null 2>&1; }
compose_up 0.004                                                       # 約14秒間隔 (sudoは環境変数を落とすため env 経由)
sleep 50
A=$(num); S=$(srv); echo "更新後: CRL番号=$A サーバ側=$S"
$DOCKER logs strongswan-admin 2>&1 | grep "^\[crl\]" | tail -4
rc=0
D=$((16#$A - 16#$B))
[ "$D" -ge 2 ] && echo "PASS 自動更新が繰り返し実行された (CRL番号 $B → $A, ${D}回)" || { echo "FAIL 繰り返し更新されていない (${D}回)"; rc=1; }
[ "$(echo $S | tr -d ':' | tr 'a-f' 'A-F')" = "$(echo $A | tr 'a-f' 'A-F')" ] && echo "PASS サーバが最新のCRLを保持" || { echo "FAIL サーバのCRLが古い (server=$S file=$A)"; rc=1; }
n=$($DOCKER exec strongswan swanctl --list-certs --type x509_crl 2>&1 | grep -cE '^\s+serial:')
[ "$n" = "1" ] && echo "PASS サーバ上のCRLは1つだけ (古いCRLが残らない)" || { echo "FAIL サーバ上のCRLが $n 個"; rc=1; }
compose_up 24                                                         # 既定(24時間)に戻す
exit $rc
