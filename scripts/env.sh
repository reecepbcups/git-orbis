# Shared env for the local orbis stack. Source this, don't run it.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ORBIS_CLI="${ORBIS_CLI:-$ROOT/.tools/bin/cli-tool}"
export ORBIS_ENDPOINT="${ORBIS_ENDPOINT:-http://127.0.0.1:39051}"
export ORBIS_RPC_URL="${ORBIS_RPC_URL:-http://127.0.0.1:39657}"
export ORBIS_REST_URL="${ORBIS_REST_URL:-http://127.0.0.1:39317}"
export ORBIS_CHAIN_GRPC_URL="${ORBIS_CHAIN_GRPC_URL:-http://127.0.0.1:39090}"
export ORBIS_CHAIN_ID="${ORBIS_CHAIN_ID:-vera-localnet}"
# public vera localnet devnet key. it's also the node controller in our compose.
export ORBIS_SIGNING_KEY="${ORBIS_SIGNING_KEY:-c4a48e2fce1481cd3294b4490f6678090ea98d3d0e5cd984558ab0968741b104}"
