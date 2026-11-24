#!/bin/bash
# git orbis update against fake releases on disk, signed with a throwaway key.
# No chain needed. Needs `make tools` first (package.sh ships .tools/bin).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="$ROOT/.update-test"; rm -rf "$W"; mkdir -p "$W"
pass=0
ok() { echo "  ok  $*"; pass=$((pass + 1)); }
fail() { echo "  FAIL $*" >&2; exit 1; }

case "$(uname -s)" in Darwin) os=darwin ;; *) os=linux ;; esac
case "$(uname -m)" in x86_64 | amd64) arch=amd64 ;; *) arch=arm64 ;; esac

openssl ecparam -name prime256v1 -genkey -noout -out "$W/test.key"
openssl ec -in "$W/test.key" -pubout -out "$W/test.pub" 2>/dev/null
openssl ecparam -name prime256v1 -genkey -noout -out "$W/other.key"

# releases/latest/download/SHA256SUMS{,.sig} + releases/download/<v>/<tarball>, like github
release() { # version signing_key
  local rel="$W/releases"
  rm -rf "$rel/latest"; mkdir -p "$rel/latest/download" "$rel/download/$1"
  "$ROOT/scripts/package.sh" "$1" "$os" "$arch" "$rel/download/$1" >/dev/null
  (cd "$rel/download/$1" && shasum -a 256 ./*.tar.gz | sed 's| \./| |') >"$rel/latest/download/SHA256SUMS"
  openssl dgst -sha256 -sign "$2" -out "$rel/latest/download/SHA256SUMS.sig" "$rel/latest/download/SHA256SUMS"
}

# an install of v0.0.1 that trusts the test key, plus a file of the user's
install() {
  rm -rf "$W/install"; mkdir -p "$W/install"
  "$ROOT/scripts/package.sh" v0.0.1 "$os" "$arch" "$W" >/dev/null
  tar -xzf "$W/git-orbis-v0.0.1-$os-$arch.tar.gz" -C "$W/install" --strip-components 1
  cp "$W/test.pub" "$W/install/release.pub"
  echo "mine" >"$W/install/.orbis-ring.env"
}
# output of an update, never fails, so callers can grep it under pipefail
update() { ORBIS_RELEASE_URL="file://$W/releases" "$W/install/bin/git-orbis" update "$@" </dev/null 2>&1 || true; }

echo "==> git orbis update"
install
release v0.0.1 "$W/test.key"
grep -q 'v0.0.1 is the latest' <<<"$(update --yes)" && ok "same version is a no-op" || fail "no-op"

release v0.0.2 "$W/test.key"
grep -q 'no terminal to confirm' <<<"$(update)" && ok "needs a tty or --yes" || fail "updated with no tty and no --yes"
grep -q 'updated v0.0.1 -> v0.0.2' <<<"$(update --yes)" && ok "updates v0.0.1 -> v0.0.2" || fail "update"
[ "$(cat "$W/install/VERSION")" = v0.0.2 ] && ok "VERSION is v0.0.2" || fail "VERSION $(cat "$W/install/VERSION")"
[ "$(cat "$W/install/.orbis-ring.env")" = mine ] && ok "user files in the install survive" || fail ".orbis-ring.env gone"
grep -q 'git orbis update' <<<"$("$W/install/bin/git-orbis" 2>&1 || true)" && ok "new git-orbis runs" || fail "new git-orbis broken"
[ ! -e "$W/install/.update-old" ] && [ ! -e "$W/install/.update-new" ] && ok "no leftovers" || fail "leftovers"

install
release v0.0.2 "$W/other.key"
grep -q "isn't signed" <<<"$(update --yes)" && [ "$(cat "$W/install/VERSION")" = v0.0.1 ] \
  && ok "refuses a release signed by another key" || fail "accepted wrong key"

release v0.0.2 "$W/test.key"
echo junk >>"$W/releases/download/v0.0.2/git-orbis-v0.0.2-$os-$arch.tar.gz"
grep -q "doesn't match its signed sha256" <<<"$(update --yes)" && [ "$(cat "$W/install/VERSION")" = v0.0.1 ] \
  && ok "refuses a tampered tarball" || fail "accepted tampered tarball"

install; echo v0.0.3 >"$W/install/VERSION"
release v0.0.2 "$W/test.key"
grep -q "not downgrading" <<<"$(update --yes)" && ok "refuses to downgrade" || fail "downgraded"

grep -q "is a git checkout" <<<"$("$ROOT/bin/git-orbis" update --yes 2>&1 || true)" && ok "source checkouts say git pull" || fail "checkout"

rm -rf "$W"
echo "PASS ($pass checks)"
