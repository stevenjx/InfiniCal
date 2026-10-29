#!/bin/bash
# Dump EVERY SMC key + value the helper can see, so two snapshots can be diffed.
# Read-only: no SMC writes anywhere in here.
#
#   ./smc_diff.sh idle        # while AlDente is idle
#   ...start AlDente discharge...
#   ./smc_diff.sh discharge
#
# Needs the helper from InfiniCal 1.0.8.1+ (it adds the "keys" command).
# Pure bash on purpose: macOS awk chokes on the pipe expression this used.

set -uo pipefail

LABEL="${1:-snap}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BASE="$PWD/smc-$LABEL-$STAMP"
SOCK=/var/run/com.infinitycomputer.infinical.helper.sock
BATCH=120

if [ ! -S "$SOCK" ]; then
  echo "helper socket missing: open InfiniCal and install/update its helper first"
  exit 1
fi

KEYS_JSON="$(printf '{"cmd":"keys"}\n' | nc -U -w 20 "$SOCK")"
case "$KEYS_JSON" in
  *'"ok":true'*) ;;
  *) echo "helper does not support enumeration yet (update the helper):"; echo "$KEYS_JSON"; exit 1 ;;
esac

# {"ok":true,...,"keys":["#KEY","B0AC",...]}
NAMES_STR="$(printf '%s' "$KEYS_JSON" | sed 's/.*"keys":\[//; s/\]}.*//')"

NAMES=()
while IFS= read -r k; do
  [ -n "$k" ] && NAMES+=("$k")
done < <(printf '%s' "$NAMES_STR" | tr ',' '\n' | tr -d '"' | grep -E '^[^",\\]{4}$' | sort -u)

COUNT=${#NAMES[@]}
echo "keys: $COUNT"
if [ "$COUNT" -eq 0 ]; then
  echo "no keys parsed; raw response follows:"
  echo "$KEYS_JSON"
  exit 1
fi

{
  echo "# label: $LABEL  time: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "# model: $(sysctl -n hw.model 2>/dev/null)  os: $(sw_vers -productVersion)"
  pmset -g batt | head -2
} > "$BASE.txt"

i=0
while [ "$i" -lt "$COUNT" ]; do
  batch=""
  j=0
  while [ "$j" -lt "$BATCH" ] && [ $((i + j)) -lt "$COUNT" ]; do
    [ "$j" -gt 0 ] && batch="$batch,"
    batch="$batch\"${NAMES[$((i + j))]}\""
    j=$((j + 1))
  done
  printf '{"cmd":"info","keys":[%s]}\n' "$batch" | nc -U -w 20 "$SOCK" >> "$BASE.txt"
  printf '\n' >> "$BASE.txt"
  i=$((i + BATCH))
done

VALUES=$(grep -o '"exists":true' "$BASE.txt" | wc -l | tr -d ' ')
echo "values read: $VALUES"
echo "saved: $BASE.txt"
echo "now compare: diff -u smc-idle-*.txt smc-discharge-*.txt"
