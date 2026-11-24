#!/bin/bash
# Release tarball for one platform, laid out the way `git orbis update` unpacks it.
# Needs `make tools` first. usage: scripts/package.sh <version> <os> <arch> <out dir>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
v="$1" os="$2" arch="$3" out="$4"

stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT
d="$stage/git-orbis"
mkdir -p "$d/.tools/bin" "$out"
cp -R "$ROOT/bin" "$ROOT/scripts" "$ROOT/completions" "$ROOT/README.md" "$ROOT/release.pub" "$d/"
cp "$ROOT/.tools/bin/cli-tool" "$ROOT/.tools/bin/orbis-filter" "$d/.tools/bin/"
echo "$v" >"$d/VERSION"
tar -C "$stage" -czf "$out/git-orbis-$v-$os-$arch.tar.gz" git-orbis
echo "$out/git-orbis-$v-$os-$arch.tar.gz"
