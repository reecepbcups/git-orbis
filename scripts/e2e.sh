#!/bin/bash
# End to end: alice pushes an encrypted .env to a bare "github" remote,
# bob (reader) clones and sees plaintext, mallory (not a reader) only sees
# the pointer, carol gets granted later. Needs `make up setup` first.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/env.sh"
[ -f "$ROOT/.orbis-ring.env" ] || { echo "run make setup first" >&2; exit 1; }
export PATH="$ROOT/bin:$PATH"

W="$ROOT/.e2e"; rm -rf "$W"; mkdir -p "$W"
pass=0
ok() { echo "  ok  $*"; pass=$((pass + 1)); }
fail() { echo "  FAIL $*" >&2; exit 1; }
did() { ORBIS_READER_DID_PK="$1" "$ORBIS_CLI" reader-did | cut -d= -f2; }
as() { local who="$1"; shift; (cd "$W/$who" && ORBIS_READER_DID_PK="$who" "$@"); }
clone() { # who
  git clone -q --no-checkout "$W/origin.git" "$W/$1"
  as "$1" git orbis init >/dev/null
  as "$1" git checkout -q main
}
gitq() { git -c user.name="$1" -c user.email="$1@example.com" "${@:2}"; }

SECRET1="DATABASE_URL=postgres://prod:hunter2@db/app"
SECRET2="DATABASE_URL=postgres://prod:rotated-$RANDOM@db/app"

echo "==> alice creates repo + pushes .env"
git init -q --bare -b main "$W/origin.git"
mkdir "$W/alice"; cd "$W/alice"; git init -q -b main
export ORBIS_READER_DID_PK=alice # alice's shell; other users go through as()
git remote add origin "$W/origin.git"
git orbis init >/dev/null
mkdir .orbis; cp "$ROOT/.orbis-ring.env" .orbis/config
printf '# alice\n%s\n# bob\n%s\n' "$(did alice)" "$(did bob)" > .orbis/readers
echo '.env filter=orbis' > .gitattributes
printf '%s\nAPI_KEY=abc123\n' "$SECRET1" > .env
echo "hello" > README.md
git add -A
gitq alice commit -qm "init with encrypted env"
git push -q origin main

echo "==> what github sees"
blob="$(git -C "$W/origin.git" show main:.env)"
head -1 <<<"$blob" | grep -qx "orbis-git v1" && ok "committed .env is a pointer" || fail "not a pointer: $blob"
git -C "$W/origin.git" cat-file --batch-all-objects --batch | grep -q hunter2 \
  && fail "plaintext leaked into remote objects" || ok "no plaintext in any remote object"
[ "$(cat .env)" = "$(printf '%s\nAPI_KEY=abc123' "$SECRET1")" ] && ok "alice working copy still plaintext" || fail "alice .env changed"
[ -z "$(git status --porcelain)" ] && ok "alice tree clean" || fail "alice dirty: $(git status --porcelain)"

echo "==> bob (reader) clones"
clone bob
grep -q hunter2 "$W/bob/.env" && ok "bob decrypts .env" || fail "bob got: $(cat "$W/bob/.env")"
[ -z "$(as bob git status --porcelain)" ] && ok "bob tree clean" || fail "bob dirty"

echo "==> mallory (not a reader) clones"
clone mallory 2>"$W/mallory.err"
head -1 "$W/mallory/.env" | grep -qx "orbis-git v1" && ok "mallory only sees pointer" || fail "mallory got: $(cat "$W/mallory/.env")"
grep -q "no access" "$W/mallory.err" && ok "mallory told she has no access" || fail "no warning for mallory"
[ -z "$(as mallory git status --porcelain)" ] && ok "mallory tree clean" || fail "mallory dirty"

echo "==> alice rotates secret, bob pulls"
cd "$W/alice"
printf '%s\nAPI_KEY=abc123\n' "$SECRET2" > .env
gitq alice commit -qam "rotate db password"
git push -q origin main
as bob git pull -q --ff-only
grep -q "rotated" "$W/bob/.env" && ok "bob sees rotated secret" || fail "bob has: $(cat "$W/bob/.env")"
as mallory git pull -q --ff-only 2>/dev/null
grep -q "rotated" "$W/mallory/.env" && fail "mallory read rotated secret" || ok "mallory still locked out"

echo "==> history stays readable for readers"
old="$(as bob git show HEAD~1:.env | as bob git orbis smudge .env)"
grep -q hunter2 <<<"$old" && ok "bob decrypts old version from history" || fail "history: $old"

echo "==> alice grants carol"
cd "$W/alice"
git orbis grant "$(did carol)" >/dev/null
gitq alice commit -qam "add carol to readers"
git push -q origin main
clone carol
grep -q "rotated" "$W/carol/.env" && ok "carol decrypts after grant" || fail "carol got: $(cat "$W/carol/.env")"

echo "PASS ($pass checks)"
