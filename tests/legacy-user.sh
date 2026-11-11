# 旧形式(SANなし)の証明書を持つテスト用ユーザ。リポジトリのルートで source して使う
legacy_setup() {
  if [ -z "${LEGACY_USER:-}" ]; then
    LEGACY_USER="legacy$$"; _LEGACY_OWN=1
    sudo env ADDUSER_NO_SAN=1 ./scripts/adduser.sh "$LEGACY_USER" >/dev/null 2>&1
    sudo rm -f "pki/clients/$LEGACY_USER/$LEGACY_USER.p12pass"   # 旧版では .p12 パスワードを保存していなかった
  fi
  export LEGACY_USER
}
legacy_teardown() { [ -n "${_LEGACY_OWN:-}" ] && sudo ./scripts/deluser.sh "$LEGACY_USER" >/dev/null 2>&1; true; }
