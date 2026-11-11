#!/bin/bash
# 使い方: moduser.sh <username> [new_password]
# 既存ユーザの証明書を失効して再発行し、パスワードも更新する (deluser.sh + adduser.sh)
set -euo pipefail
D="$(dirname "$0")"
U="${1:?username}"
"$D/listusers.sh" | grep -qx -- "$U" || { echo "存在しないユーザ: $U" >&2; exit 1; }
"$D/deluser.sh" "$U" >/dev/null
"$D/adduser.sh" "$U" ${2:+"$2"}
