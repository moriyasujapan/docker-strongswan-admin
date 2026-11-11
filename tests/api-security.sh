#!/bin/bash
# 管理APIの認証・CSRF・入力検証のテスト (curl)
cd "$(dirname "$0")/.."
PW=$(sudo grep '^ADMIN_PASSWORD=' .env | cut -d= -f2)
B=https://localhost:8443; fail=0
chk(){ # 名前 期待コード 実コード
  if [ "$2" = "$3" ]; then echo "PASS $1 (HTTP $3)"; else echo "FAIL $1 (期待 $2 / 実際 $3)"; fail=1; fi; }
code(){ curl -sk -m 15 -o /dev/null -w '%{http_code}' "$@"; }
AUTH=(-u "admin:$PW"); HDR=(-H "Origin: $B" -H "X-Requested-With: vpn-admin" -H "Content-Type: application/json")

chk "認証なしは拒否"                           401 "$(code $B/api/users)"
chk "誤パスワードは拒否"                       401 "$(code -u admin:wrong $B/api/users)"
chk "正しい認証でユーザ一覧取得"               200 "$(code "${AUTH[@]}" $B/api/users)"
chk "CSRF: カスタムヘッダ無しのPOSTは拒否"     403 "$(code "${AUTH[@]}" -H "Origin: $B" -X POST -d '{"user":"evil"}' $B/api/users)"
chk "CSRF: 別オリジンからのPOSTは拒否"         403 "$(code "${AUTH[@]}" -H "Origin: https://evil.example" -H "X-Requested-With: vpn-admin" -X POST -d '{"user":"evil"}' $B/api/users)"
chk "CSRF: ヘッダ無しのDELETEは拒否"           403 "$(code "${AUTH[@]}" -H "Origin: $B" -X DELETE $B/api/users/alice)"
chk "不正なユーザ名は400"                      400 "$(code "${AUTH[@]}" "${HDR[@]}" -X POST -d '{"user":"a b;rm -rf"}' $B/api/users)"
chk "短すぎるパスワードは400"                  400 "$(code "${AUTH[@]}" "${HDR[@]}" -X POST -d '{"user":"pwtest","pw":"short"}' $B/api/users)"
chk "パストラバーサルは404"                    404 "$(code "${AUTH[@]}" "$B/dl/..%2f..%2fca%2fca.key")"
chk "CA秘密鍵はダウンロード不可"               404 "$(code "${AUTH[@]}" $B/dl/alice.cakey)"
chk "存在しないユーザのダウンロードは404"      404 "$(code "${AUTH[@]}" $B/dl/nobody.p12)"
chk "認証情報API: 認証なしは拒否"                401 "$(code $B/api/users/alice/credentials)"
chk "認証情報API: 存在しないユーザは404"          404 "$(code "${AUTH[@]}" $B/api/users/nobody/credentials)"
chk "認証情報API: 不正なユーザ名は404"            404 "$(code "${AUTH[@]}" "$B/api/users/..%2fca/credentials")"
chk "認証情報API: 既存ユーザは200"                200 "$(code "${AUTH[@]}" $B/api/users/alice/credentials)"
ALICE_P12=$(curl -sk -m 15 "${AUTH[@]}" $B/api/users/alice/credentials | python3 -c "import sys,json;d=json.load(sys.stdin);print('null' if d['p12pw'] is None else 'set', 'pw' if d['pw'] else 'nopw')")
[ "$ALICE_P12" = "null pw" ] && echo "PASS 旧発行ユーザ(alice): VPNパスワードあり / p12パスワードは未保存(null)" || { echo "FAIL alice credentials ($ALICE_P12)"; fail=1; }
CSP=$(curl -sk -m 15 "${AUTH[@]}" -D - -o /dev/null $B/ | grep -i '^content-security-policy' | tr -d '\r')
[[ "$CSP" == *"script-src 'self'"* ]] && echo "PASS CSPヘッダ (script-src 'self')" || { echo "FAIL CSPヘッダ"; fail=1; }
exit $fail
