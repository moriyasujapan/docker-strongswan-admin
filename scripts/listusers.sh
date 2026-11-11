#!/bin/bash
# ユーザ一覧 (users.conf の id 行が正。セクション名はユーザ名と無関係なハッシュ)
. "$(dirname "$0")/common.sh"
sed -n 's/^    id = "\{0,1\}\([A-Za-z0-9._-]*\)"\{0,1\}$/\1/p' "$SW/conf.d/users.conf" 2>/dev/null
