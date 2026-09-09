# 🤠 wrangle 

A fish-shell + Homebrew sync system that keeps your tooling, dotfiles, and plugin state consistent across macOS machines, without ever asking you to maintain the inventory by hand.

## What this is

You install tools, write dotfiles, install fisher plugins, configure plugins via fish universals. Over time your machine drifts from anything you've checked in. Normally you'd notice this only when standing up a new machine — at which point you scramble to reconstruct what you had.

Wrangle is a fish script that turns "the current state of my machine" into something **git-tracked, branchable per-machine, and replayable on a fresh box**. The way it does that:

- Each run, wrangle walks your live machine and compares it against the tracked state. Drift goes both ways, and the prompts differ depending on which direction is out of sync:
  - **The machine has something the repo doesn't** (you installed a brew, added a fisher plugin, dropped a new dotfile in `~/.config/`) → wrangle prompts per item: `[t]rack` it into the repo, `[i]gnore forever`, or `[s]kip` for now.
  - **The repo has something the machine doesn't yet** (you ran `wrangle update` to bring `origin/main` down, or `wrangle merge <branch>` to adopt content from another of your machines) → for fisher and brew, wrangle prompts per item: `[i]nstall` it or `[r]emove` it from the tracked list. For dotfiles, no prompt — stow symlinks newly-tracked files into `~` automatically. The one case that *does* halt is a conflict: a tracked dotfile whose target path already has a real (non-symlink) file with different contents. Stow refuses to clobber, wrangle reports the conflict, and you resolve it by hand (typically: diff, move your local copy aside, re-run — or accept the local copy and re-track it).
  
  Once an already-tracked dotfile is symlinked, "conflicting contents" can't happen — `~/.config/foo` and `home/.config/foo` are the same inode, so editing either is editing both. Conflicts only arise the first time a tracked file lands on a machine that already had its own version.

- The capture strategy per domain:
  - **Dotfiles** go under `home/` and get [GNU stow](https://www.gnu.org/software/stow/)–symlinked back into `~`.
  - **Brew formulae, casks, and Mac App Store apps** go into a `Brewfile` (via `brew bundle dump`, filtered through your `.brewignore`). On a new machine, `brew bundle install` (or wrangle's own prompt) reinstalls everything from that file.
  - **Fisher plugins** go into `fish_plugins`. Wrangle calls `fisher install` / `fisher remove` itself when you accept an install/uninstall prompt.
  - **Fish universal variables** (the ones plugins like tide use for config) get captured into a sourceable file at `home/.config/fish/exported-univ-vars.fish`. `wrangle sync` handles replay automatically: on a new machine, missing tracked vars are applied silently the first time you sync; if a tracked var's live value differs from the repo's, sync prompts per-var.

- The whole repo is a **git repo with a branch per machine**. Wrangle's commits go to your machine's branch; framework changes (the wrangle script itself, etc.) live on `main`. Each machine-branch is independent and diverges freely from the others after init. Framework updates flow `main → your machine-branch` via `wrangle update`; cross-machine personal-layer content moves explicitly via `wrangle merge <branch>`. The `wrangle sync` / `update` / `merge` / `push` / `status` subcommands wrap the git-side mechanics so you rarely touch git directly.

- Every commit goes through a **pre-commit regex secret-scan** that catches the obvious shapes (AWS / GitHub / Slack / Stripe / OpenAI / Anthropic / Google API keys, JWTs, PEM / OpenSSH / PGP private-key blocks). On a hit wrangle refuses to commit unless you set `WRANGLE_ALLOW_SECRETS=1`.

- Wrangle optionally uses [claude-code](https://github.com/anthropics/claude-code) for two things: summarizing commit diffs into nicer commit messages, and reviewing the repo's docs when changes accumulate. Both are opt-in; first run asks. Everything else works with claude off.

Day-to-day there are three subcommands that matter:

- `wrangle sync` — the main one: detect drift, ask per-item, commit, optionally push.
- `wrangle update` — bring framework updates from `main` into your machine-branch.
- `wrangle push` — push your current branch's commits.

`wrangle status` gives a read-only summary when you sit down at a machine: whether `origin/main` has updates waiting, which peer machine-branches exist and when each was last touched, and what `wrangle sync` would surface as drift. `wrangle help` lists the rest.

## Quick start

```bash
git clone <this-repo-url> <wherever-you-want>
cd <that-dir>
./scripts/bootstrap
```

`bootstrap` is a bash script that:

1. Installs Homebrew if missing.
2. Brew-installs the minimum kit wrangle needs: `fish`, `stow`, `git`, `mas`.
3. Adds fish to `/etc/shells` (sudo) and `chsh`'s your login shell to fish.
4. Prompts for this machine's branch name (default `personal`), optionally seeded from another existing machine-branch.
5. Stows the framework's conf.d hooks into `~/.config/fish/conf.d/`.
6. Bootstraps fisher.
7. Launches your first `wrangle sync`.

Everything is idempotent and non-destructive — safe to re-run on a partially-set-up machine. The full walkthrough is in [setup-new-machine.md](setup-new-machine.md).

## The flow you'll actually use

After bootstrap:

- **You install a new tool / edit a dotfile / install a fisher plugin.** Wrangle doesn't watch for changes — it's pull-based.
- **You run `wrangle sync` whenever you want to capture what's drifted.** It walks each domain (dotfiles, fisher, universals, brew), prompts per-item, makes the chosen edits, commits, and offers to push.
- **You run `wrangle update` when a framework release ships.** It fetches origin and merges `origin/main` into your current machine-branch.
- **You run `wrangle merge <branch>` when you want to pull specific content from another of your machines** (e.g. you installed `mergiraf` on the work box and want it on the laptop too). Per-item prompts — you decide what comes across.
- **You run `wrangle push` when the shell-start nag tells you have unpushed commits** — usually because you said `[N]o` to the push prompt at the end of a sync.

Three nags fire on shell start to keep you honest: staleness (haven't run wrangle in a week), unpushed (you have local commits not on origin), and update-pending (`origin/main` has commits you haven't merged into your machine-branch). All three are colorized and prefixed with `wrangle:` and each one suggests the exact subcommand that resolves it.

## How tracking works

`stow` is the load-bearing piece. The repo has a `home/` directory that mirrors your `~` layout. When a file lives at `home/.config/fish/config.fish`, stow creates a symlink at `~/.config/fish/config.fish` pointing back into the repo. Edits to either path are edits to the same file. Wrangle re-stows every run, so newly-tracked files get linked automatically.

Domain-specific bits:

- **Dotfiles**: wrangle walks top-level `~/.<name>` files and `~/.config/*` entries. For each untracked entry on the machine, you get `[t]rack` (mv into `home/`, symlink back), `[i]gnore forever` (append to `.dotignore`), `[s]kip`, or `[q]uit`. Paths stow cannot store are the exception: they're reported with the reason and offered only `[i]gnore forever` / `[s]kip` / `[q]uit`, never `[t]rack`. Three things disqualify a path — a symlink to an absolute path (stow refuses it outright, because it could never remove it again), a symlink pointing outside the path being tracked (it would resolve against the repo after the move, not `~`), and a socket, pipe or device file (git can't store it). This matters more than it sounds: `home/` is a **single stow package**, so one path stow won't take blocks every file in it. If a track does fail at the stow step, the move is rolled back and the run stops rather than continuing into the next path. The other direction (file in `home/` but missing from `~`) splits into two cases: if you previously had it and deleted it, you get a yoink prompt asking whether to remove it from the repo or restore via stow; if it's genuinely new (e.g. arrived via `wrangle update` or `wrangle merge`), stow symlinks it into `~` silently.
- **Fisher plugins**: compares `fisher list` against the tracked `fish_plugins` file, filtering both sides through `.fisherignore`. Plugins installed but not tracked → `[t]rack` / `[i]gnore` (appends to `.fisherignore`, leaves the plugin installed) / `[s]kip`. Plugins tracked but not installed → `[i]nstall` / `[r]emove from fish_plugins` / `[s]kip`. To uninstall a plugin, run `fisher remove` directly.
- **Fish universals**: two sub-passes, matching the two-direction shape of the fisher and brew passes. **Capture**: collects current universals (`set -U -L`), auto-skips anything starting with `_` (fish + plugin internal convention), groups the rest by prefix. For each new prefix group, offers to track the pattern (e.g. `tide_*`) into `.univexport`, ignore forever into `.univignore`, or skip. Tracked vars get regenerated into `home/.config/fish/exported-univ-vars.fish`. **Import**: parses that same file for tracked names + values, compares to your live shell. Missing-on-machine → silent apply (matching how stow silently symlinks newly-tracked dotfiles). Different value live vs repo → prompts `[a]pply repo value / [k]eep local / [s]kip / [q]uit`. No `[k]eep local forever` memory needed — the capture sub-pass that follows regenerates the file with whatever's live, so the conflict one-shots itself.
- **Brew**: calls `dump-brewfile` (a thin wrapper around `brew bundle dump --describe --force`, filtered through `.brewignore`) and diffs the result against your tracked `Brewfile`. When something's installed locally but missing from the Brewfile, wrangle asks whether to track it, add a `.brewignore` substring so it stops nagging, or skip. When something's in the Brewfile but not installed locally, it asks whether to install it, drop it from the Brewfile, or skip.

Wrangle also catches files that are tracked but have uncommitted changes (e.g. you edited your `config.fish` directly without running wrangle): each pass reports its domain's dirty files so they get committed alongside any newly-tracked items.

## Branch model

Machines are peers. Each owns one branch (the "machine-branch") and commits to it. Framework changes (the wrangle script itself, etc.) live on `main` and flow down to machine-branches via `wrangle update`. Personal-layer content (Brewfile entries, dotfiles, plugins) is owned by whatever machine added it; cross-pollinating it between machines is an explicit per-item act via `wrangle merge <branch>`.

```
main                     framework — shared, semver-tagged
  ├─ personal            your laptop  (owns its own state)
  ├─ work                your work machine  (owns its own state)
  └─ workshop            your shop machine  (owns its own state)
```

One git config key controls this, per-clone (not pushed):

- `wrangle.machine-branch <name>` — which branch this clone commits to. Defaults to `personal` if unset. Bootstrap sets it explicitly on first run.

**`wrangle update`** fetches origin and merges `origin/main` into the current machine-branch. On merge conflict it stops, prints what to resolve; resolve manually (`git add` + `git commit`), then re-run.

**`wrangle merge <branch>`** brings personal-layer content from another machine-branch into the current one. Walks dotfiles + Brewfile + fish_plugins + univ-vars, comparing the source branch's tracked state to the current branch's. For each item the source has and you don't (or have differently), it prompts: `[a]dopt` source's version, `skip [f]orever` (never adopt this in any future merge — appends to `.merge-skip`), `[k]eep mine` (on conflict only), `[d]iff` (on conflict only), `[s]kip` (this run only), `[q]uit`. Items matching the current branch's `.ignore` files OR `.merge-skip` are skipped with a one-line note. `wrangle merge <branch> --force` bypasses `.merge-skip` so previously-`skip [f]orever`ed items re-surface.

`wrangle merge` is **add-only**: items YOU have that the source doesn't are left alone. To stop tracking something, use the existing `[i]gnore` flow on your machine. Framework files (`scripts/`, `README.md`, etc.) only change through the framework path: PR → `main` → `wrangle update`.

On a new machine, `bootstrap` initializes the machine-branch from `main` by default. Optionally you can seed it from another existing machine-branch (one-time copy of starting state); the new branch then diverges freely from that point.

## Repo layout

```
scripts/
  bootstrap      Bash. The one-time setup script.
  wrangle        Fish. The everyday command.
  dump-brewfile  Fish. `brew bundle dump` with .brewignore filtering applied.
  scan-secrets   Fish. Pre-commit safety net for high-confidence secret patterns.
  bump-version   Bash. Semver-tags main. Called by the release workflow, rarely manually.
  run-tests      Bash. Wraps fishtape over test/*.fish. Needs fish, fishtape
                 and stow (the dotfile tests exercise real stow behavior).
  _*.fish        Fish. Units sourced by wrangle, split out so more than one
                 subcommand (and the tests) can use them: _skiplist (ignore-file
                 parsing), _univ_parse / _univ_helpers (universals), _commit_msg
                 (commit messages), _drift (Passes 5-8, shared by `sync` and
                 `status`), _nag_state (pull-nag state file format),
                 _stow_guard (what stow can't store, the stow runner itself,
                 and stow's failure text translated into a cause).

test/            Fishtape tests covering wrangle CLI surface, scan-secrets, dump-brewfile, bump-version.
  helpers/       Shared fixture construction. Not collected by `fishtape test/*.fish`
                 (that glob doesn't recurse), so it's sourceable without being run.

.github/workflows/
  test.yml       Runs the test suite on every push/PR.
  release.yml    On a release:*-labeled PR merging to main, tags + cuts a GitHub Release.

home/            Mirrors ~. Stow-managed. On main, only contains the framework's
                 conf.d hooks. Your machine-branch builds up tracked dotfiles here.

.dotignore       Per-line substring patterns / globs that the dotfile pass skips.
.brewignore      Per-line substrings that get stripped from auto-dumped Brewfile.
.fisherignore    Per-line exact plugin identifiers the fisher pass skips.
.univexport      Allowlist of fish-universal-variable patterns to capture.
.univignore      Blocklist of universals to never ask about.
.merge-skip      Items `wrangle merge` silently skips (populated by `skip [f]orever`; bypass with --force).
.gitignore       Editor swap files, macOS noise, .env, .wrangle-changelog, etc.

setup-new-machine.md   Walkthrough for the first run on a fresh machine.
```

Things that aren't on `main` (they're personal-layer, on your machine-branch): `Brewfile`, your personal `config.fish` / `fish_plugins` / `.gitconfig` / vim configs, the auto-generated `home/.config/fish/exported-univ-vars.fish`.

## Subcommand reference

`wrangle help` is the authoritative source — it prints subcommands, env vars, and git config keys in one shot. `wrangle help <subcmd>` (or equivalently `wrangle <subcmd> --help`) describes a single subcommand's flags.

| Subcommand | What it does |
|---|---|
| `wrangle sync` | The main workflow. Detect drift across all domains, prompt per item, commit, push. Accepts `--dry-run`, `--force`, `--verbose` (surface silent skiplist matches), `--with-claude` / `--suppress-claude`, `--no-branch-switch`. |
| `wrangle update` | Fetch origin and merge `origin/main` into the current machine-branch (framework updates). On merge conflict, resolve manually + re-run. |
| `wrangle merge <branch>` | Per-item adoption of personal-layer content from another machine-branch. Walks dotfiles + Brewfile + fish_plugins + univ-vars; prompts `[a]dopt / [k]eep mine / [d]iff / [s]kip / [q]uit` per item. Add-only; honors `.ignore` files; scoped to personal-layer content. |
| `wrangle push` | Push the current branch to origin, with a preview of what's about to ship. No prompt — typing the subcommand is the decision. |
| `wrangle status` | Read-only summary. Fetches origin, then reports **Update status** (this branch vs `origin/<branch>` — unpushed or unpulled commits), **Framework update** (commits on `origin/main` not yet merged in), peer machine-branches with last-updated timestamps, and a `wrangle sync --dry-run` of local drift. Mutates nothing. |
| `wrangle review-docs` | Skip drift; have claude review the repo's docs against recent commits. |
| `wrangle repair` | Recover a `home/` that stow refuses. Offers to move each unstowable path back to `~`, re-stows (which re-links anything stranded by the breakage), then clears symlinks in `~` pointing at paths no longer in `home/`. Accepts `--dry-run`. Run this when `wrangle sync` stops at the re-stow pass. |

Bare `wrangle`, `wrangle -h`, and `wrangle --help` all print top-level help. There's no implicit-sync shortcut — type `wrangle sync` to sync.

## Customization

There are six user-editable files at the repo root that wrangle reads. All take one entry per line; `#` comments are fine.

| File | What it controls | Typical entries |
|---|---|---|
| `.dotignore` | Paths under `~` that wrangle never asks about. Pre-populated with credential-bearing paths (`.aws`, `.config/gh`, `.npmrc`, etc.). Substring patterns / fish-globs. | Credential dirs, caches, history files, big data dirs. |
| `.brewignore` | Lines stripped from the auto-dumped Brewfile *before* wrangle compares against the tracked Brewfile. Substring matches. | Apps you've installed locally but don't want to drag to other machines. |
| `.fisherignore` | Fisher plugins wrangle never asks about. Exact match against `fisher list` output. | `PatrickF1/fzf.fish`, etc. |
| `.univexport` | Fish universal-variable names/patterns to capture into the exportable file. | `tide_*`, `sponge_*`, etc. Exact names also work (override the auto-skip of `_*`). |
| `.univignore` | Universal-variable names/patterns wrangle never asks about. | `_*` (fish/plugin internal state) — already auto-skipped, so this is mainly for one-off vars. |
| `.merge-skip` | Items `wrangle merge` silently skips. Format: `<domain> <item>` (domain ∈ dotfile/brew/fisher/univ). Populated by the `skip [f]orever` prompt action. Bypass for one run with `wrangle merge <branch> --force`. | `brew brew "mergiraf"`, `fisher PatrickF1/fzf.fish`, etc. |

All of them can be edited by hand. Wrangle also writes to them when you answer `[t]rack` or `[i]gnore forever` during a sync, or `skip [f]orever` during a merge, so you usually don't have to.

The default `.dotignore` ships pre-populated with credential paths, key-file globs, common shell/OS noise, and tool caches that you almost certainly don't want to sync. Delete any line you disagree with. `wrangle sync --force` bypasses `.dotignore` entirely (including the credential entries) — the pre-commit secret-scan is the secondary safety net that catches anything obvious in that case.

## Shell integration

Bootstrap stows one conf.d hook into your `~/.config/fish/conf.d/` (it's a symlink, so updates flow automatically through `wrangle update`):

**`wrangle_integration.fish`** does four things on every interactive shell start:

1. Adds `<repo>/scripts/` to `$PATH` so `wrangle` and friends are callable.
2. **Staleness nag** if wrangle hasn't run in > 7 days. Suggests `wrangle sync`.
3. **Unpushed nag** if your current branch has unpushed commits. Suggests `wrangle push`.
4. **Update nag** if `origin/main` has commits not yet merged into the current machine-branch. Suggests `wrangle update`. Self-suppresses for already-seen `origin/main` SHAs, so it only re-fires on genuinely new commits.

All three nags are colorized and prefixed with `wrangle:`. Each has a corresponding `WRANGLE_NO_*_NAG=1` env var to silence it (see [Env vars](#env-vars-and-git-config) below).

## Env vars and git config

Env vars (set in `config.fish` for permanent effect):

| Var | Effect |
|---|---|
| `WRANGLE_NO_COMMIT` | Skip the commit step at the end of `sync`. |
| `WRANGLE_NO_PUSH` | Skip the push step at the end of `sync`. |
| `WRANGLE_NO_PUSH_NAG` | Silence the shell-start unpushed-commits nag. |
| `WRANGLE_NO_PULL_NAG` | Silence the shell-start update-pending nag. |
| `WRANGLE_NO_STALENESS_NAG` | Silence the shell-start staleness nag. |
| `WRANGLE_NO_BRANCH_SWITCH` | Skip the framework update at the start of `sync`. |
| `WRANGLE_ALLOW_SECRETS` | Bypass `scan-secrets` at commit time (use only when you've verified the hits are test fixtures or false positives). |
| `WRANGLE_CLAUDE_MODEL` | Override the claude model (default `sonnet`). |
| `WRANGLE_CLAUDE_EFFORT` | Override claude effort: `low` (default) / `medium` / `high` / `xhigh` / `max`. |

Git config (per-clone, in `.git/config`):

| Key | Default | Purpose |
|---|---|---|
| `wrangle.machine-branch` | `personal` | Which branch this clone commits to. |

Cache files at `~/.cache/dotfiles/` (nothing user-facing — documented here for the rare debug case):

```
last-wrangle           timestamp of last successful sync (drives staleness nag)
wrangle-config         "WRANGLE_CLAUDE_OPT_IN=yes" or =no, set by first-run question
pull-nag-state         origin/main SHA last nagged about (deduplicates the update nag)
```

## Releasing framework updates (for maintainers)

Framework changes ship through a PR-driven flow. Tagging and the GitHub Release are automated.

```fish
git checkout main && git pull
git checkout -b some-change
# edit scripts/, tests, docs, etc.
git commit -am "describe the change"
git push -u origin some-change
gh pr create --base main --title "..." --label release:patch   # or release:minor / release:major
```

When the PR is green and you merge it (rebase merge — main stays linear), `.github/workflows/release.yml` reads the `release:*` label, calls `scripts/bump-version`, pushes the next `vX.Y.Z` tag, and creates a GitHub Release with auto-generated notes.

PRs without a `release:*` label merge normally but don't bump the version — use that for changes that aren't user-visible (CI tweaks, README typos, etc.). To release after the fact, label another PR or run `scripts/bump-version` manually.

Released framework updates flow into your machine-branch the next time you run `wrangle update` (or `wrangle sync`, which starts with an update).
