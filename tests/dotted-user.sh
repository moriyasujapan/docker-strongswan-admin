#!/bin/bash
# 回帰テスト: ユーザ名に "." "_" "-" を含んでも、サーバの設定が壊れず接続できること
# (以前はセクション名 eap-<ユーザ名> が文法エラーになり、接続定義ごと読み込めなくなった)
cd "$(dirname "$0")/.."
DOCKER="docker"; docker info >/dev/null 2>&1 || DOCKER="sudo docker"
PW=$(sudo grep '^ADMIN_PASSWORD=' .env | cut -d= -f2); B=https://localhost:8443; U="dot.user_x-1"; rc=0
A=(-sk -m 60 -u "admin:$PW" -H "Origin: $B" -H "X-Requested-With: vpn-admin" -H "Content-Type: application/json")
ok(){ echo "PASS $1"; }; ng(){ echo "FAIL $1"; rc=1; }
conns(){ $DOCKER exec strongswan swanctl --list-conns 2>&1 | grep -cE '^rw:'; }
curl "${A[@]}" -X DELETE $B/api/users/$U >/dev/null 2>&1
R=$(curl "${A[@]}" -X POST -d "{\"user\":\"$U\"}" $B/api/users); echo "$R" | grep -q '"pw"' && ok "ドット等を含むユーザ名 ($U) を追加できる" || ng "追加に失敗: $R"
[ "$(conns)" = 1 ] && ok "追加後もサーバの接続定義 rw が読み込まれている" || ng "【重大】接続定義が消えた"
$DOCKER exec strongswan swanctl --load-all 2>&1 | grep -qE "invalid config|syntax error" && ng "【重大】設定ファイルが文法エラー" || ok "設定ファイルに文法エラーがない"
[ "$(curl "${A[@]}" $B/api/users/$U/credentials | python3 -c "import sys,json;print(bool(json.load(sys.stdin).get('pw')))")" = True ] && ok "パスワードを再表示できる" || ng "パスワードの再表示"
OUT=$(tests/e2e.sh "$U" 2>&1); echo "$OUT" | grep -q "CHILD_SA .* established" && ok "ドット入りユーザで VPN 接続 (証明書+パスワード) 成功" || ng "接続失敗: $(echo "$OUT" | grep -v plugin | tail -2)"
[ "$(curl "${A[@]}" -X DELETE -o /dev/null -w '%{http_code}' $B/api/users/$U)" = 200 ] && ! sudo ./scripts/listusers.sh | grep -qx -- "$U" && ok "削除できる" || ng "削除"
[ "$(conns)" = 1 ] && ok "削除後も接続定義 rw が読み込まれている" || ng "【重大】削除後に接続定義が消えた"
sudo rm -rf pki/clients/.revoked-$U-*
exit $rc
