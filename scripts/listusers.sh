#!/bin/bash
. "$(dirname "$0")/common.sh"
grep -o 'eap-[A-Za-z0-9._-]*' "$SW/conf.d/users.conf" | sed 's/^eap-//'
