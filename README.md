# git-orbis

Private `.env` files in a normal (even public) git repo.

Git is all or nothing. If you can clone the repo you can read every file in it. git-orbis lets you commit a secret file to the same repo as your code while only the people you pick can read it. Everyone else, GitHub included, just sees a pointer:

```text
orbis-git v1
object: 7c438b3a4ccea43321576e74421c7b9cc0bf3baaa8cd207b474508dd0e7b48ee
```

You don't need a special git host or a new workflow. It's a plain git filter, so `git add`, `commit`, `push`, `pull` and `clone` all work like normal.

## What it does

- You `git commit` a `.env`. The real contents go into [Orbis](https://github.com/sourcenetwork/orbis-rs), and only a pointer goes into git.
- A teammate on the readers list clones or pulls and gets the real `.env` on disk.
- Someone not on the list (or a random person on GitHub) clones fine but keeps the pointer. Their checkout doesn't break, they just get a warning.
- Old versions stay readable from history for readers, like any other file.

## How it works

Orbis is a threshold secret engine. A few nodes (3 here) run a DKG, which gives them one shared public key. Each node only holds a *share* of the private key, so no single node can decrypt anything. 2 of the 3 have to cooperate.

Reading a secret uses **proxy re-encryption (PRE)**. The nodes take the ciphertext (encrypted to the ring) and transform it so it's encrypted to *your* throwaway key instead. The plaintext never exists on any node, it only shows up on your machine.

Who's allowed to ask for that? Each node checks an access control policy on the Vera chain before it helps. Your identity is a `did:key` (an Ed25519 key) and you sign every request with it.

Here's the flow:

```text
git add .env
  -> clean filter
     1. store the file in orbis (encrypted to the ring's public key)
     2. register it as an object in the ACP policy
     3. grant "reader" to you + every DID in .orbis/readers
     4. hand git the pointer (orbis-git v1 / object: <id>)

git checkout / clone / pull
  -> smudge filter
     1. read the object id from the pointer
     2. ask the ring to re-encrypt it for a fresh throwaway key (signed with your DID)
     3. nodes check the ACP policy, 2 of 3 send back shares
     4. combine, decrypt, write the real .env
     (no access? keep the pointer, print a warning, carry on)
```

Few details that matter:

- **Same content, same pointer.** Clean caches `sha256(plaintext) -> pointer` in `.git/orbis/`, and smudge fills that cache too. Without it every `git status` would think `.env` changed.
- **Fails closed.** `filter.orbis.required=true` means if clean can't reach orbis, git refuses to commit. It never falls back to committing plaintext.
- **The repo files.** `.orbis/config` (ring id, ring public key, policy id) and `.orbis/readers` (one DID per line) get committed. Neither is secret, it's fine for them to be public.

## Try it locally

Needs docker and a rust toolchain (for `make tools`).

```bash
make up      # vera + 3 orbis nodes in docker, project "git-orbis", ports 390xx
make setup   # policy + 2-of-3 ring + DKG, writes .orbis-ring.env
make e2e     # alice / bob / mallory / carol against a local bare "github" remote
make down    # wipes the chain. pointers made against it are dead after this
```

`make e2e` checks 13 things: nothing secret ever reaches the remote, readers decrypt, non-readers get the pointer, rotation, history and granting a new reader. Takes about a minute.

Images are public and pinned by digest: `ghcr.io/sourcenetwork/orbis-rs` (jubjub build) and `ghcr.io/sourcenetwork/vera` (the `:dev` build from 2026-11-12).

## Using it in a repo

```bash
export PATH=/path/to/git-orbis/bin:$PATH
export ORBIS_READER_DID_PK=<your identity seed>   # treat it like a password

git orbis init                                   # once per clone, before checkout
mkdir -p .orbis && cp /path/to/git-orbis/.orbis-ring.env .orbis/config
echo '.env filter=orbis' >> .gitattributes
git orbis whoami                                 # your DID, send it to whoever manages access
git orbis grant did:key:z6Mk...                  # give someone access, then commit .orbis/readers
```

When you clone an existing repo, run `git orbis init` before checking out, so the filter's there when `.env` gets written:

```bash
git clone --no-checkout <url> app && cd app
git orbis init && git checkout main
```

## Known gaps

It's a POC, so:

- **Single machine.** The stack is on localhost, so only this machine can decrypt. A real team needs the nodes + chain hosted somewhere they can all reach.
- **No revoke.** Removing a reader doesn't take anything back. Rotate the actual secret (true for every git secret tool, old versions live in history).
- **Slow-ish commits.** A changed `.env` costs ~20s (1 store + 1 register + 1 grant per reader, each waits for a block). Unchanged files are instant. Batching the grants into one tx would get it to ~8s.
- **`ps` can see it.** The secret goes to `cli-tool` as `--secret` while committing.
- **Shared writer key.** Everyone writes with the public devnet key, which owns the ACP objects.
- **Seeds are toy strings** in the demo. Use random ones.

## The cli-tool patch

`patches/cli-tool.patch` is applied on top of orbis-rs `51162e5` by `make tools`. It adds:

- `reader-did` prints the DID for a seed
- `set-relationship-on-chain --actor-did` grants by DID (before you needed the reader's private seed)
- `ring_policy` and `ring` resources in the default policy, since this vera build requires them to create a ring
