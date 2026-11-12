#!/usr/bin/env bash
# Proves tool-feed masks secrets before anything leaves the machine.  bash tests/tool-feed-mask.test.sh
set -u
cd "$(dirname "$0")/.."
source <(sed -n '/^mask() {/,/^}/p' plugins/discord/hooks/tool-feed.sh)
fail=0
check() { local got; got=$(printf '%s' "$1" | mask); if printf '%s' "$got" | grep -qF -- "$2"; then echo "FAIL leaked '$2' in: $got"; fail=1; else echo "ok   $got"; fi; }
check 'curl -H "Authorization: Bearer abcdefghijklmnop1234"' 'abcdefghijklmnop1234'
check 'curl -H "Authorization: Bot MTIzNDU2Nzg5MDEyMzQ1Njc4.Gabcde"' 'MTIzNDU2Nzg5MDEyMzQ1Njc4'
check 'influxdb3 query --token apiv3_SuperSecretValue' 'SuperSecretValue'
check 'export PASSWORD=hunter2 TOKEN=xyz123' 'hunter2'
check 'curl -u admin:s3cretpw https://x' 's3cretpw'
check 'mosquitto_sub -u nat -P "p4ssw0rd" -t x' 'p4ssw0rd'
exit $fail
