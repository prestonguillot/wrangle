# Setup: new macOS machine

## TL;DR

```bash
git clone <this-repo-url> <wherever-you-want>
cd <that-dir>
./scripts/bootstrap
```

The bootstrap script handles the automatable parts and then drops you into a `wrangle` session that walks through everything already on the machine.

---

## What `./scripts/bootstrap` actually does

Everything below is idempotent. Safe to re-run on a partially-set-up machine; nothing destructive.

1. **Homebrew** — installs it if missing; sources `brew shellenv` for the rest of the script.
2. **Minimum kit** — `brew install fish stow git mas`. fish is the shell the scripts are written in; stow manages the symlinks; git pinned for clarity (you cloned this repo with it); mas is the only CLI gateway to the Mac App Store, so `brew bundle dump` can see MAS apps.
3. **Login shell** — adds `$(brew --prefix)/bin/fish` to `/etc/shells` (sudo), then `chsh -s` to fish. Skipped if already in place.
4. **Machine-branch.** Prompts for the branch name (default: `personal`). Writes `wrangle.machine-branch` to `.git/config` (per-clone, not pushed). If the branch already exists locally or on origin, switches to it. Otherwise creates a fresh branch — by default from `main`, optionally seeded from another existing machine-branch (a one-time copy of starting state; no persistent relationship).
5. **Stow framework** — runs `stow --no-folding -t ~ home`. Creates a symlink for the framework's `wrangle_integration.fish` conf.d hook, plus any other tracked files under `home/`.
6. **Fisher** — bootstraps the fish plugin manager if not already present.
7. **First wrangle** — execs into a fresh fish session and runs `wrangle sync` (so PATH integration from the just-stowed conf.d hook is live).

---

## Manual steps `bootstrap` can't do

1. **Git remote auth (if you'll push).** Set up auth however you prefer: osxkeychain credential helper (built into git on macOS), SSH keys, the `gh` CLI, etc. Plain `git push` over HTTPS works out of the box once your credential helper is configured. On the first push of your machine-branch, git will prompt with `git push --set-upstream origin <branch>` — accept it (or use a different remote if you'd rather push that branch elsewhere).

2. **Mac App Store sign-in (if you'll install MAS apps).** Open the App Store app and sign in. `mas install <id>` won't work otherwise.

3. **Anything else you want this machine to have.** Install tools normally (`brew install foo`, drag apps to `/Applications`, write dotfiles by hand, whatever). Next time you run `wrangle`, it'll detect drift and walk you through tracking it.

---

## The first `wrangle` session

When bootstrap hands off, you're in interactive `wrangle`. What you'll see:

- A framework update (Pass 1) — fetches origin and merges `origin/main` into your machine-branch. On the very first run from a fresh branch, this typically reports "already up to date" since you just branched from main.
- A first-run welcome banner (only shows once per machine).
- A one-time question asking whether to enable claude-code doc review.
- A pre-stow integrity check for yoinked or orphaned dotfile symlinks.
- A re-stow.
- A dotfile-drift pass: walks top-level entries in `~/` and `~/.config/` that aren't tracked. For each: `[t]rack` (moves into `home/`, symlinks back), `[i]gnore forever` (writes to `.dotignore`), `[s]kip`, `[q]uit`. Paths stow can't store — a symlink to an absolute path, a symlink pointing outside the tracked path, or a socket/pipe/device file — are reported and left alone; they get `[i]gnore forever` / `[s]kip` / `[q]uit` but no `[t]rack`.
- A fisher-plugin drift pass: installed plugins not in `fish_plugins`, and vice versa.
- A univ-var drift pass with two sub-passes. **Import**: if `exported-univ-vars.fish` exists, applies any tracked vars missing from your live shell silently; prompts `[a]pply / [k]eep local / [s]kip / [q]uit` per var when live and repo values differ. **Capture**: groups remaining (untracked) live universals by prefix; `[t]rack pattern` adds e.g. `tide_*` to `.univexport` and regenerates `exported-univ-vars.fish`; `[i]gnore forever` adds the pattern to `.univignore`.
- A brew-drift pass: installed brews/casks/MAS apps not in `Brewfile`, and vice versa.
- A secret-scan against the staged diff before commit (auto-aborts on AWS/GitHub/Slack/Stripe/OpenAI/Anthropic/Google tokens, JWTs, private keys).
- A commit (auto, on your machine-branch).
- An optional claude doc-sync pass (if you opted in).
- A push prompt with preview (commit count + filename stats + `[d]iff` for full).

Everything is non-destructive. Hitting `[s]kip` for everything is a valid outcome — wrangle just makes no changes and exits.

For the per-domain detail on what each pass does, see **[README.md → How tracking works](README.md#how-tracking-works)**.

---

## Daily use

Five subcommands cover the everyday loop:

- `wrangle sync` — the main one: detect drift across all domains, prompt per-item, commit, optionally push.
- `wrangle update` — fetch origin and merge `origin/main` into your machine-branch (framework updates).
- `wrangle repair` — recover a `home/` that stow refuses to link. Offers to move each unstowable path back to `~`, re-stows (re-linking anything the breakage stranded), then clears symlinks in `~` pointing at paths no longer in `home/`. `--dry-run` reports without changing anything. Run it if `wrangle sync` stops at the re-stow step.
- `wrangle merge <branch>` — per-item adopt personal-layer content from another machine-branch (Brewfile entries, dotfiles, fisher plugins, univ-var patterns) into the current one. Per-item prompts let you `[a]dopt`, `[s]kip` once, or `skip [f]orever` (writes to `.merge-skip`; bypass with `wrangle merge <branch> --force`).
- `wrangle push` — push your current branch's commits.
- `wrangle status` — read-only "where do I stand?" check. Fetches origin, reports whether `origin/main` has updates waiting (i.e. what `wrangle update` would do), lists peer machine-branches with last-updated timestamps (i.e. candidates for `wrangle merge`), and runs `wrangle sync --dry-run` to surface local drift. Mutates no local state.

`wrangle help` lists the rest (env vars, git config keys, less-frequent subcommands like `review-docs`). `wrangle help <subcommand>` (or `wrangle <subcommand> --help`) describes a single subcommand's flags.

The repo nags you in three ways from new shells. All are colorized and prefixed with `wrangle:` so it's obvious where they come from, and each suggests a concrete subcommand to fix the situation:

- **Staleness nag** — fires once per shell if `wrangle` hasn't run in > 7 days. Suggests `wrangle sync`.
- **Unpushed nag** — fires once per shell if the current branch has unpushed commits. Suggests `wrangle push`.
- **Update nag** — fires when `origin/main` has commits not yet merged into your machine-branch, but **self-suppresses** for already-seen `origin/main` SHAs (so you're not nagged twice about the same commits). Suggests `wrangle update`.

All three are silenceable via env var (`WRANGLE_NO_STALENESS_NAG=1`, `WRANGLE_NO_PUSH_NAG=1`, `WRANGLE_NO_PULL_NAG=1`) but the nags themselves don't advertise this — they're designed to fire only when they have something new to say.

---

## Detaching a machine

```fish
cd <your-repo>
stow -t ~ -D home    # removes every symlink wrangle has stowed back into ~
```

The repo itself is untouched. Re-stow any time with `stow --no-folding -t ~ home`.

---

## Where things live

- `~/.cache/dotfiles/last-wrangle` — last successful run timestamp (machine-local).
- `~/.cache/dotfiles/wrangle-config` — claude opt-in answer (machine-local).
- `~/.cache/dotfiles/pull-nag-state` — origin/main SHA last nagged about (so the update nag doesn't re-fire for the same commits).
- `<repo>/.wrangle-changelog` — running log of structural changes (used by claude when enabled).
- `<repo>/.dotignore`, `<repo>/.brewignore`, `<repo>/.univexport`, `<repo>/.univignore` — ignore/allowlists, tracked on your machine-branch.
- `<repo>/home/.config/fish/exported-univ-vars.fish` — auto-regenerated snapshot of universals matching `.univexport` patterns. Restored automatically by the next `wrangle sync` (Pass 7's import sub-pass): missing tracked vars are silent-applied; value conflicts prompt per-var.

---

## Branches

For the full branch-model explanation see **[README.md → Branch model](README.md#branch-model)**. Quick summary:

- **`main`** is framework only — wrangle/bootstrap scripts, ignore-list templates, tests, docs. Shared and semver-tagged.
- **Your machine-branch** (default `personal`) is your machine state — `.gitconfig`, vim configs, Brewfile, plugin lists, captured universals. Each machine owns one and they diverge freely.

Wrangle's Pass 1 at the start of every `wrangle sync` merges `origin/main` into your machine-branch, so framework updates flow in automatically. To cross-pollinate personal-layer content between your own machines, use `wrangle merge <branch>` — it walks each domain and prompts per item. If you want to skip the framework update for one sync run, use `wrangle sync --no-branch-switch`.
