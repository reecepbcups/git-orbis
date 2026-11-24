#!/bin/bash
# Creates an ACP policy + 2-of-3 ring on the local stack and writes the
# result to $1 (default .orbis-ring.env). Run once after `make up`.
set -euo pipefail
source "$(dirname "$0")/env.sh"
OUT="${1:-$ROOT/.orbis-ring.env}"
cli() { "$ORBIS_CLI" "$@"; }
# node txs fail with "unchanged"/"already" on reruns, that's fine
# nodes register their own node info after they're funded, so right after
# `make up` it can still be missing. wait for it instead of failing.
idem() {
  local out i
  for i in $(seq 1 60); do
    out="$("$ORBIS_CLI" "$@" 2>&1)" && return 0
    grep -qiE 'unchanged|already' <<<"$out" && return 0
    grep -q 'node info not found' <<<"$out" || break
    sleep 2
  done
  echo "$out" >&2; return 1
}
field() { grep "$1" | head -1 | sed "s/.*$1 *//"; }

keys=()
for port in 39051 39052 39053; do
  n=$((port - 39050))
  info="$(cli -e "http://127.0.0.1:$port" info)"
  key="$(printf '%s\n' "$info" | field 'Node Key:')"
  peer="$(printf '%s\n' "$info" | field 'Peer ID:')"
  keys+=("$key")
  eval "NODE${n}_KEY=$key NODE${n}_PEER=$peer"
done

policy="$(cli add-policy-to-chain | grep '^POLICY_ID=' | cut -d= -f2)"
echo "policy: $policy"
# owning the ring_policy object is what lets us create rings under this policy
cli register-object-to-chain --policy-id "$policy" --object-id "$policy" --resource ring_policy >/dev/null

for n in 1 2 3; do
  key="NODE${n}_KEY"; peer="NODE${n}_PEER"
  # nodes advertise a NAT address, so point peers at the docker service name
  idem update-node-peer-id --node-key "${!key}" --peer-id "${!peer}@node$n:9001"
  idem add-node-to-whitelist --node-key "${!key}" --policy-id "$policy"
done

ring="$(cli create-ring --peer-node-keys "$(IFS=,; echo "${keys[*]}")" --threshold 2 \
  --policy-id "$policy" --nonce "$(date +%s)" | grep '^RING_ID=' | cut -d= -f2)"
echo "ring: $ring"
cli dkg --ring-id "$ring" >/dev/null

ring_pk=""
for _ in $(seq 1 60); do
  ring_pk="$(cli get-latest-ring --ring-id "$ring" 2>/dev/null | grep '^RING_PK=' | cut -d= -f2 || true)"
  [ -n "$ring_pk" ] && break
  sleep 3
done
[ -n "$ring_pk" ] || { echo "dkg never finalized" >&2; exit 1; }

cat > "$OUT" <<EOF
ORBIS_RING_ID=$ring
ORBIS_RING_PK=$ring_pk
ORBIS_POLICY_ID=$policy
EOF
echo "wrote $OUT"
