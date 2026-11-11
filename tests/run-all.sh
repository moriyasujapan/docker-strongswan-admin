#!/bin/bash
# 管理画面(UI)〜VPN接続までの通しテスト。結果とスクリーンショットを docs/evidence/ に保存する。
# 前提: docker compose up -d 済み、init-pki.sh 済み、.env に ADMIN_PASSWORD
set -uo pipefail
cd "$(dirname "$0")/.."
DOCKER="docker"; docker info >/dev/null 2>&1 || DOCKER="sudo docker"
E=docs/evidence; U=uitest
sudo rm -rf "$E"; mkdir -p "$E"; sudo rm -rf pki/clients/.revoked-$U-*
. tests/legacy-user.sh; legacy_setup; sudo rm -rf pki/clients/.revoked-legacy*
rc=0; step(){ echo; echo "### $*"; }
strip(){ grep -v "plugin '" ; }

step "A: UIでユーザ追加 / コピー / ダウンロード";            tests/ui/run.sh A $U 2>&1 | tee $E/ui-phase-A.out || rc=1
step "D: 認証情報付きURLで開いても動く (回帰テスト)";            tests/ui/run.sh D $U 2>&1 | tee $E/ui-phase-D.out || rc=1
step "ダウンロードしたファイルのopenssl検証"
P12PW=$(sudo python3 -c "import json;print(json.load(open('$E/.creds-$U'))['p12Pw'])")
{ cd $E
  echo "証明書をCAで検証:";            sudo openssl verify -CAfile dl-ca.crt dl-$U.crt.pem
  echo "Subject/EKU/期限:";            sudo openssl x509 -in dl-$U.crt.pem -noout -subject -enddate -ext extendedKeyUsage 2>&1 | sed 's/^/  /'
  a=$(sudo openssl x509 -in dl-$U.crt.pem -noout -pubkey | sha256sum | cut -c1-16); b=$(sudo openssl pkey -in dl-$U.key.pem -pubout | sha256sum | cut -c1-16)
  echo "秘密鍵と証明書の対応: cert=$a key=$b $([ "$a" = "$b" ] && echo MATCH || echo MISMATCH)"
  echo "p12(正しいパスワード):";       sudo openssl pkcs12 -in dl-$U.p12 -passin pass:$P12PW -noout -info 2>&1 | grep -E "MAC:|PKCS7 Encrypted|Shrouded" | sed 's/^/  /'
  echo "p12(誤パスワード):";           sudo openssl pkcs12 -in dl-$U.p12 -passin pass:wrong -noout 2>&1 | head -1 | sed 's/^/  /'
  cd - >/dev/null; } 2>&1 | tee $E/openssl-check.txt
step "VPN接続: UIで発行した証明書+パスワード";                 tests/e2e.sh $U 2>&1 | strip | tee $E/vpn-login-A.log

step "B: UIで再発行 (旧証明書は失効、パスワード更新)";          tests/ui/run.sh B $U 2>&1 | tee $E/ui-phase-B.out || rc=1
step "VPN接続: 再発行後の新しい証明書+パスワード";             tests/e2e.sh $U 2>&1 | strip | tee $E/vpn-login-B.log
step "VPN接続: 失効した旧証明書 (パスワードは有効) は拒否される"
OLD=$(ls -d pki/clients/.revoked-$U-* | sort | tail -1)
CERT_DIR=$OLD tests/e2e.sh $U 2>&1 | strip | tee $E/vpn-login-revoked-cert.log
sudo docker logs strongswan 2>&1 | grep -E "certificate was revoked|certificate status is good" | tail -2 | tee $E/server-revocation.log

step "C: UIで削除";                                             tests/ui/run.sh C $U 2>&1 | tee $E/ui-phase-C.out || rc=1
{ echo "残りのユーザ数: $(./scripts/listusers.sh | wc -l) (実ユーザ名は証跡に残さない) / $U が一覧に無い: $(./scripts/listusers.sh | grep -qx "$U" && echo NO || echo yes)"
  echo "users.conf内の $U のエントリ数: $(sudo grep -cE "^    id = \"?$U\"?\$" swanctl/conf.d/users.conf || true)"
  echo "サーバ接続定義: $(sudo docker exec strongswan swanctl --list-conns 2>&1 | grep -E '^rw')"
  echo "CRL: $(sudo docker exec strongswan swanctl --list-certs --type x509_crl 2>&1 | grep -E 'revoked certificates' | tail -1)"; } | tee $E/server-after-delete.txt
step "VPN接続: 削除済みユーザは拒否される"
CERT_DIR=$(ls -d pki/clients/.revoked-$U-* | sort | tail -1) tests/e2e.sh $U 2>&1 | strip | tee $E/vpn-login-deleted-user.log

step "管理APIの認証/CSRF/入力検証"
tests/api-security.sh 2>&1 | tee $E/api-security.txt || rc=1

step "クライアント用配布物: Android .sswan / Mac 用一式 (構造検証 + 実際に接続)"
tests/mobile-profiles.sh 2>&1 | grep -v "plugin '" | tee $E/mobile-profiles.txt || rc=1

step "回帰: ドット等を含むユーザ名でも設定が壊れない"
tests/dotted-user.sh 2>&1 | grep -v "plugin '" | tee $E/dotted-user.txt || rc=1

step "CRL自動更新 (間隔を短くして繰り返し更新されることを確認)"
tests/crl-refresh.sh 2>&1 | grep -v "plugin '" | tee $E/crl-refresh.txt || rc=1

legacy_teardown; sudo rm -rf pki/clients/.revoked-legacy*

# 秘密情報を含むファイルは証跡に残さない
sudo rm -f $E/.creds-* $E/dl-*.key.pem $E/dl-*.p12 $E/dl-*.sswan $E/dl-*.tar.gz
sudo chown -R "$USER:$USER" $E 2>/dev/null
echo; echo "完了 (rc=$rc)"; exit $rc
