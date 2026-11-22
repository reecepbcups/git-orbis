#!/bin/bash
# End to end: alice pushes an encrypted .env to a bare "github" remote,
# bob (reader) clones and sees plaintext, mallory (not a reader) only sees
# the pointer, carol gets added to the ops team later and only reads prod. Needs `make up setup` first.
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
PROD="STRIPE_KEY=sk_live_topsecret"
SECRET2="DATABASE_URL=postgres://prod:rotated-$RANDOM@db/app"

echo "==> alice creates repo + pushes .env"
git init -q --bare -b main "$W/origin.git"
mkdir "$W/alice"; cd "$W/alice"; git init -q -b main
export ORBIS_READER_DID_PK=alice # alice's shell; other users go through as()
git remote add origin "$W/origin.git"
git orbis init >/dev/null
mkdir .orbis; cp "$ROOT/.orbis-ring.env" .orbis/config
printf '# alice\n%s\n# bob\n%s\n' "$(did alice)" "$(did bob)" > .orbis/readers
printf '# ops\nops: %s\n' "$(did alice)" > .orbis/teams
printf '.env*  @all\n.env.production  @ops\n' > .orbis/access
git orbis sync >/dev/null
printf '%s\nAPI_KEY=abc123\n' "$SECRET1" > .env
echo "DEBUG=1" > .env.development
echo "$PROD" > .env.production
echo "hello" > README.md
git add -A
gitq alice commit -qm "init with encrypted env"
git push -q origin main

echo "==> what github sees"
blob="$(git -C "$W/origin.git" show main:.env)"
head -1 <<<"$blob" | grep -qx "orbis-git v1" && ok "committed .env is a pointer" || fail "not a pointer: $blob"
git -C "$W/origin.git" cat-file --batch-all-objects --batch | grep -qE 'hunter2|DEBUG=1|topsecret' \
  && fail "plaintext leaked into remote objects" || ok "no plaintext in any remote object"
[ "$(cat .env)" = "$(printf '%s\nAPI_KEY=abc123' "$SECRET1")" ] && ok "alice working copy still plaintext" || fail "alice .env changed"
[ -z "$(git status --porcelain)" ] && ok "alice tree clean" || fail "alice dirty: $(git status --porcelain)"
[ "$(git -C "$W/origin.git" show main:README.md)" = hello ] && ok "files outside .orbis/access stay plaintext" || fail "README got filtered"

echo "==> new rule works without sync"
echo '.secrets/*  @all' >> .orbis/access
mkdir .secrets; echo "TOKEN=staging-only" > .secrets/staging
git add -A
gitq alice commit -qm "add staging secret"
git push -q origin main
git -C "$W/origin.git" cat-file --batch-all-objects --batch | grep -q staging-only \
  && fail "staging leaked" || ok "new pattern encrypted, no sync needed"

echo "==> bob (reader) clones"
clone bob
grep -q hunter2 "$W/bob/.env" && ok "bob decrypts .env" || fail "bob got: $(cat "$W/bob/.env")"
grep -q DEBUG=1 "$W/bob/.env.development" && ok "bob decrypts .env.development" || fail "bob dev: $(cat "$W/bob/.env.development")"
head -1 "$W/bob/.env.production" | grep -qx "orbis-git v1" && ok "bob (not ops) can't read .env.production" || fail "bob read prod"
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

echo "==> alice adds carol to ops"
cd "$W/alice"
git orbis grant "$(did carol)" ops >/dev/null
gitq alice commit -qam "add carol to ops"
git push -q origin main
clone carol 2>/dev/null
grep -q topsecret "$W/carol/.env.production" && ok "carol decrypts .env.production" || fail "carol got: $(cat "$W/carol/.env.production")"
head -1 "$W/carol/.env" | grep -qx "orbis-git v1" && ok "carol (not @all) can't read .env" || fail "carol read .env"

echo "==> alice pushes a private branch for @ops"
cd "$W/alice"
echo 'branch:feat-*  @ops' >> .orbis/access
gitq alice commit -qam "ops only feature branches"
git push -q origin main
git checkout -q -b feat-x
echo "func launch() {} // PRIVATE_FEATURE_CODE" > launch.go
git add launch.go
gitq alice commit -qm "PRIVATE_COMMIT_MSG"
git orbis push-private feat-x >/dev/null
git checkout -q main
git -C "$W/origin.git" rev-parse -q --verify refs/heads/feat-x >/dev/null \
  && ok "feat-x visible on remote" || fail "feat-x not on remote"
git -C "$W/origin.git" cat-file --batch-all-objects --batch | grep -qaE 'PRIVATE_FEATURE_CODE|PRIVATE_COMMIT_MSG' \
  && fail "private branch leaked" || ok "no private code or commit msg in remote objects"
as carol git orbis fetch-private feat-x >/dev/null
as carol git show feat-x:launch.go | grep -q PRIVATE_FEATURE_CODE \
  && ok "carol (ops) gets the private branch" || fail "carol missing feat-x"
as bob git orbis fetch-private feat-x 2>/dev/null && fail "bob fetched feat-x" || ok "bob (not ops) can't fetch feat-x"

echo "==> plain git push of a private branch encrypts it"
cd "$W/alice"
git checkout -q feat-x
echo "func land() {} // PRIVATE_PLAIN_PUSH" > land.go
git add land.go
gitq alice commit -qm "PRIVATE_MSG_2"
git push -q origin feat-x 2>/dev/null
git checkout -q main
git -C "$W/origin.git" cat-file --batch-all-objects --batch | grep -qaE 'PRIVATE_PLAIN_PUSH|PRIVATE_MSG_2' \
  && fail "plain push leaked feat-x" || ok "plain git push of feat-x stays encrypted"
as carol git orbis fetch-private feat-x >/dev/null
as carol git show feat-x:land.go | grep -q PRIVATE_PLAIN_PUSH \
  && ok "carol gets the plain pushed update" || fail "carol missing land.go"
as bob git pull -q --ff-only
as bob git checkout -q -b feat-bob
echo "BOB_SECRET" > "$W/bob/bob.txt"
as bob git add bob.txt
as bob gitq bob commit -qm "bob"
as bob git push -q origin feat-bob </dev/null 2>/dev/null && fail "bob pushed feat-bob" || ok "bob (not ops, no tty) can't push feat-bob"
git -C "$W/origin.git" cat-file --batch-all-objects --batch | grep -qa BOB_SECRET \
  && fail "feat-bob leaked" || ok "nothing from feat-bob on remote"

echo "==> sync grants existing private branches to new readers"
git orbis grant "$(did bob)" ops >/dev/null
git orbis sync >/dev/null
as bob git orbis fetch-private feat-x >/dev/null 2>&1 \
  && ok "bob fetches feat-x after joining ops + sync" || fail "bob still locked out of feat-x"

echo "==> alice publishes feat-x"
cd "$W/alice"
git orbis private-publish feat-x </dev/null 2>/dev/null && fail "published without confirm" || ok "private-publish needs a confirm"
git orbis private-publish --yes feat-x launch >/dev/null 2>&1
git -C "$W/origin.git" show launch:land.go | grep -q PRIVATE_PLAIN_PUSH \
  && ok "launch is public plaintext" || fail "launch not public"
git -C "$W/origin.git" rev-parse -q --verify refs/heads/feat-x >/dev/null \
  && fail "feat-x stub still on remote" || ok "encrypted feat-x removed"

echo "PASS ($pass checks)"
