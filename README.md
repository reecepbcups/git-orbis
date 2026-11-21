# git-orbis

Private `.env` files in a normal git repo. GitHub (or any remote) only ever sees a pointer like:

```text
orbis-git v1
object: 7c438b3a4c...
```

The real content lives in Orbis, encrypted to a 2-of-3 threshold ring. Only DIDs listed as readers can get the ring to proxy re-encrypt it for them. Everyone else just keeps the pointer, and checkout still works for them.

## Try it

```bash
make up      # vera + 3 orbis nodes in docker (project "git-orbis")
make setup   # policy + ring + DKG, writes .orbis-ring.env
make e2e     # alice/bob/mallory/carol against a local bare "github" remote
make down
```

`make tools` builds a patched orbis `cli-tool` (see `patches/cli-tool.patch`). The first build is slow.

## Using it in a repo

```bash
export PATH=/path/to/this/repo/bin:$PATH
export ORBIS_READER_DID_PK=<your identity seed>   # keep it secret
git orbis init                                   # per clone
echo '.env filter=orbis' >> .gitattributes
git orbis whoami                                 # share this DID with the team
git orbis grant did:key:z6Mk...                  # give someone access
```

Commit `.orbis/config` (ring id, ring pk, policy) and `.orbis/readers` (one DID per line).

## How it works

- **clean** (on add/commit): stores the file in orbis, registers it in ACP, grants you plus everyone in `.orbis/readers`, and emits a pointer. Results are cached by content hash in `.git/orbis/`, so `git status` stays quiet.
- **smudge** (on checkout): runs PRE with a fresh ephemeral key and writes the plaintext. With no access, it keeps the pointer and prints a warning.
- `filter.orbis.required=true`, so if clean fails git refuses to commit. It never falls back to plaintext.

## Known gaps (it's a poc)

- No revoke. Removing someone stops nothing, so rotate the actual secret. That's true for any git secret tool, since old versions are in history.
- Every content change is a new orbis object plus a few chain txs (~5s per commit of a changed file).
- The secret is passed to `cli-tool` via `--secret`, so it's visible in `ps` on your box.
- Writers share the devnet signing key (it owns the ACP objects). Real use needs per-writer keys.
- Depends on Vera. See the research notes on swapping it for a light GitHub-key based ACL service.

The patch adds `reader-did`, `set-relationship-on-chain --actor-did` (grant by DID, no seed needed), and the `ring_policy`/`ring` resources this vera build wants in the default policy.
