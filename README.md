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
     3. grant "reader" to you + whoever .orbis/access says can read this path
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
- **One process, like git-lfs.** `.gitattributes` has `* filter=orbis`, so every file goes through the filter. `orbis-filter` (Go, in `cmd/orbis-filter`) is started once per git command and passes plain files straight back, so 5k files cost about 0.2s on top of plain git. Only files `.orbis/access` covers get handed to the `git-orbis` script.
- **Fails closed.** `filter.orbis.required=true` means if clean can't reach orbis, git refuses to commit. It never falls back to committing plaintext.
- **The repo files.** `.orbis/config` (ring id, ring public key, policy id), `.orbis/readers`, `.orbis/teams` and `.orbis/access` get committed. None of them are secret, it's fine for them to be public.

## Try it locally

Needs docker, a rust toolchain and go (for `make tools`). `make test` runs the go tests.

```bash
make up      # vera + 3 orbis nodes in docker, project "git-orbis", ports 390xx
make setup   # policy + 2-of-3 ring + DKG, writes .orbis-ring.env
make e2e     # alice / bob / mallory / carol against a local bare "github" remote
make down    # wipes the chain. pointers made against it are dead after this
```

`make e2e` checks 22 things: nothing secret ever reaches the remote, readers decrypt, non-readers get the pointer, per-file teams, rotation, history, adding someone to a team and private branches. Takes about a minute.

Images are public and pinned by digest: `ghcr.io/sourcenetwork/orbis-rs` (jubjub build) and `ghcr.io/sourcenetwork/vera` (the `:dev` build from 2026-11-12).

## Using it

Once per machine:

```bash
export PATH="$HOME/git-orbis/bin:$PATH"   # put it in your shell rc
git orbis install                             # global filter, zsh completion, creates ~/.ssh/git-orbis, prints your DID
```

After that a plain `git clone` of a repo using git-orbis decrypts on its own. If you got access after cloning, `git orbis refresh`.

Adding it to a repo:

```bash
mkdir -p .orbis && cp ~/git-orbis/.orbis-ring.env .orbis/config
git orbis whoami > .orbis/readers
echo '.env* @all' > .orbis/access
git orbis sync     # writes the filter lines into .gitattributes
git add -A && git commit -m "encrypted env"
```

### Who can read what

`.orbis/access` works like CODEOWNERS. A pattern, then who can read it. Last match wins.

```text
.env*             @all
.env.production   @ops did:key:z6MkExtra...
```

Teams go in `.orbis/teams`. `@all` is the built-in team and it's just `.orbis/readers`, so older repos keep working without an access file.

```text
ops: did:key:z6MkA... did:key:z6MkB...
```

Or skip editing it by hand:

```bash
git orbis access .env.staging @ops           # file rule, runs sync for you
git orbis access 'branch:private/*' @ops     # branch rule
```

Same pattern again replaces the old rule where it sits.

After you edit `.orbis/access` run `git orbis sync`. It rewrites the git-orbis block in `.gitattributes` and grants the current version of every file to whoever can read it now.

Giving someone access:

```bash
git orbis grant did:key:z6Mk...        # adds to @all
git orbis grant did:key:z6Mk... ops    # adds to the ops team
git commit -am "give <name> access" && git push
```

### Private branches

A whole branch can be private too. Add a `branch:` rule to `.orbis/access` (glob, last match wins, same owners as files):

```text
branch:feat-*   @ops
```

```bash
git orbis push-private feat-x            # [remote] [base], defaults origin origin/main
git orbis fetch-private feat-x           # readers get a real local feat-x
```

GitHub gets a branch called `feat-x`, so everyone can see it's there. It's just `origin/main` plus two files:

- `.orbis/branches/feat-x` - the orbis object id and the base commit
- `.orbis/branches/feat-x.bundle` - the branch as a `git bundle`, AES-256 encrypted

The AES key (and the bundle's sha256) is the orbis secret, so only DIDs on the rule can decrypt it. Code, file names, commit messages and authors stay hidden. The branch name, its size and when you pushed don't.

No matching `branch:` rule means push-private refuses, it won't fall back to `@all`.

You don't have to remember push-private either. Run `git orbis init` once in the clone and plain `git push` does it for you. It sets origin's pushurl to `orbis::<url>`, so pushes go through `git-remote-orbis`:

- branch matches a `branch:` rule and you're on it - encrypted push
- matches but you're not on it - it asks: encrypted, plaintext or abort. no terminal means abort
- anything else - normal push

Done hiding it? `git orbis private-publish feat-x launch` renames it to a public name, pushes the real commits and deletes the encrypted copy. It asks you to type `yes` first (`--yes` skips that), since there's no taking it back.

Tab completion (zsh) comes with `git orbis install`. It links into `~/.oh-my-zsh/custom/completions`, no `.zshrc` edit. Without oh-my-zsh, add `~/git-orbis/completions` to your `fpath`.

Your identity seed lives in `~/.ssh/git-orbis` (0600). `ORBIS_READER_DID_PK` overrides it, `ORBIS_IDENTITY_FILE` moves it. `git orbis init` sets the filter for one clone only if you'd rather not touch your global config.

## Known gaps

It's a POC, so:

- **Single machine.** The stack is on localhost, so only this machine can decrypt. A real team needs the nodes + chain hosted somewhere they can all reach.
- **Teams are read only.** They control who can decrypt, not who can change a file. Anyone who can push can commit a new `.env` or edit `.orbis/access`. Use GitHub CODEOWNERS + branch protection on `.orbis/` and the secret files for that.
- **Forget `sync`, leak plaintext.** A new pattern in `.orbis/access` isn't encrypted until `git orbis sync` puts it in `.gitattributes`.
- **No revoke.** Removing a reader doesn't take anything back. Rotate the actual secret (true for every git secret tool, old versions live in history).
- **Slow-ish commits.** A changed secret costs ~7s: 1 block to store it, 1 block to register it and grant every reader in one tx. Unchanged files are instant. Blocks are 5s on the localnet, so that's most of it.
- **Plain `git push` only encrypts after `git orbis init`.** A clone without the orbis pushurl pushes private branches in plaintext.
- **Private branches are last push wins.** Every `push-private` force pushes a full new bundle. Two people pushing the same one clobber each other. No PR diff view on GitHub either, merging means pushing the code to main for real.
- **`ps` can see it.** The secret goes to `cli-tool` as `--secret` while committing.
- **Shared writer key.** Everyone writes with the public devnet key, which owns the ACP objects.
- **Seeds are toy strings** in the demo. Use random ones.

## The cli-tool patch

`patches/cli-tool.patch` is applied on top of orbis-rs `51162e5` by `make tools`. It adds:

- `reader-did` prints the DID for a seed
- `set-relationship-on-chain --actor-did` grants by DID (before you needed the reader's private seed)
- `grant-batch --actor-dids a,b,c [--register]` grants many DIDs (and registers the object) in one tx
- `ring_policy` and `ring` resources in the default policy, since this vera build requires them to create a ring
