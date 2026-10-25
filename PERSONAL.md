# Personal post-bootstrap setup

`setup-new-machine.md` covers the genesys framework. This file covers the steps specific to my (Preston's) personal layer — tools installed via my Brewfile that have post-install configuration not handled by `brew install` alone.

Run any of these you need after `./scripts/bootstrap` completes.

## GitHub auth (`gh`)

My `home/.gitconfig` configures git to use the `gh` CLI as its credential helper for github.com and gist.github.com. For that to work, you have to authenticate gh once per machine:

```fish
gh auth login
```

Pick HTTPS, authorize in the browser. After this, `git push`/`git pull` to private GitHub repos works without prompts for the lifetime of the token.

If on a given machine you'd rather use a different credential strategy (osxkeychain alone, SSH, etc.), edit `home/.gitconfig` to drop the `!gh auth git-credential` lines.

## Link openjdk so `java` actually works

`openjdk` (and its dependent `sbt`) are in my Brewfile, but Homebrew can't symlink the JDK into `/Library/Java/JavaVirtualMachines/` without root. After `brew bundle install`:

```fish
sudo ln -sfn "$(brew --prefix)/opt/openjdk/libexec/openjdk.jdk" \
              /Library/Java/JavaVirtualMachines/openjdk.jdk
```

Run this **in a real terminal** — `sudo` needs a TTY for the password prompt.

Verify: `java --version` should print something like `openjdk 26.x.x …`.

If you don't actually want Java on a given machine, remove `brew "openjdk"` and `brew "sbt"` from the Brewfile and uninstall them.

## Install a Node version (`fnm`)

`fnm` is wired into `config.fish` (`fnm env --use-on-cd | source`) so node-version auto-switching works in any directory with a `.nvmrc` or `.node-version`. But fnm doesn't ship with a node; install one once:

```fish
fnm install --lts
fnm default lts-latest
```

`node --version` should report the LTS now.

## Claude Code (`npm`)

`@anthropic-ai/claude-code` is installed through npm in the Brewfile, so it needs a node version first (see the `fnm` section above). Once `fnm install --lts` has run, `brew bundle install` can install it. Then sign in once per machine:

```fish
claude
```

Follow the login prompt on first launch.

## Wireshark capture permissions

`wireshark` (CLI) and `wireshark-app` (GUI) are in my Brewfile. Capturing packets needs access to `/dev/bpf*`, which macOS restricts. Open the Wireshark app once and install the "ChmodBPF" helper when it offers (this prompts for an admin password). Without it Wireshark can open capture files but not capture live traffic.

## Mac App Store

Sign into the App Store app with the Apple ID that originally purchased my MAS apps (currently just Fantastical, `id: 975937182`). `brew bundle install` will skip MAS lines for unowned apps with a warning rather than failing.

## Neovim plugin bootstrap (LazyVim)

`home/.config/nvim/` is a LazyVim config. On first run after stow, neovim bootstraps lazy.nvim (git clone) and then installs all plugins — this can take 30–60 seconds and the screen will show install progress. Just let it finish; subsequent launches are normal.

```fish
nvim
```

When the lazy.nvim UI closes and the normal editor appears, plugins are installed.

## Fisher plugins

`fish_plugins` (tracked in the repo, symlinked into `~/.config/fish/`) lists `jorgebucaran/fisher` itself plus `fzf.fish`, `autopair.fish`, and `sponge`. Bootstrap installs fisher but doesn't auto-install the plugins. One-liner:

```fish
fish -c 'fisher update'
```

Wrangle's fisher-drift pass on the next run will also notice any missing-from-installed plugins and offer to install them per-item.
