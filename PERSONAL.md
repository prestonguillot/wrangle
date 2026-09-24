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

## Mac App Store

Sign into the App Store app with the Apple ID that originally purchased my MAS apps (currently Okta Verify, `id: 490179405`). `brew bundle install` will skip MAS lines for unowned apps with a warning rather than failing.

## Google Cloud CLI (`gcloud`)

`gcloud-cli` installs the `gcloud` binary but ships with no credentials. Authenticate once per machine:

```fish
gcloud auth login
gcloud auth application-default login
```

The first command gives you interactive CLI access; the second sets up Application Default Credentials for SDKs and local tools. Both open a browser flow.

## AWS CLI (`awscli`)

`awscli` installs the `aws` binary but requires credentials before it can talk to AWS. The right setup depends on whether you're using IAM keys or AWS SSO (more likely for work):

```fish
# SSO (preferred for Intuit accounts):
aws configure sso

# Or for personal/static credentials:
aws configure
```

Follow the prompts. After SSO setup, authenticate per-session with `aws sso login --profile <profile-name>`.

## Git Credential Manager (`git-credential-manager`)

`git-credential-manager` (GCM) is a cross-platform credential helper for Git. It installs itself as a Git credential helper on first run. No manual configuration is needed — it will prompt on your first `git push`/`git pull` to a new host and store the token in macOS Keychain.

If you're on a machine where `gh` is already set up as the credential helper for github.com (see the GitHub auth section above), GCM and `gh` can coexist — `home/.gitconfig` controls which one handles which host.

## Rancher Desktop (`rancher`)

Rancher Desktop provides local Kubernetes and a Docker-compatible container runtime. On first launch it will ask you to:

1. Choose a container runtime (containerd or dockerd/moby).
2. Configure the Kubernetes version.

It also installs `kubectl`, `helm`, `nerdctl`, and `docker` CLI shims under `~/.rd/bin/`. Make sure that path is in `$PATH` (the fish config in this repo should handle it if `~/.rd/bin` is included).

## Jira CLI (`jira-cli`)

`jira-cli` requires a Jira API token. After install:

```fish
jira init
```

It will prompt for your Jira server URL (e.g. `https://jira.intuit.com`), email, and an API token. Generate a token at your Jira profile → Security → API tokens. Config is written to `~/.config/.jira/.config.yml`.

## ToolHive (`thv`)

`thv` (ToolHive) manages MCP servers. No mandatory setup on install, but to add and run an MCP server:

```fish
thv run <server-image>
```

See `thv --help` for available subcommands. Servers run as isolated containers; Rancher Desktop (or another OCI runtime) must be running.

## Mergiraf (syntax-aware merge driver)

`mergiraf` is a syntax-aware git merge driver for languages like Scala, Java, JSON, and others. After install, register it with git:

```fish
mergiraf install --global
```

This adds the driver config to `~/.gitconfig` and sets up `.gitattributes` patterns. After that, git will automatically use mergiraf when merging supported file types instead of the default line-based driver.

## CircleCI CLI (`circleci`)

`circleci` needs an API token before most subcommands (e.g. `circleci config validate`, `circleci local execute`) will work against your projects. After install:

```fish
circleci setup
```

It prompts for a CircleCI API token (generate one at https://app.circleci.com/settings/user/tokens) and, optionally, a custom API endpoint (leave default for circleci.com). Config is written to `~/.circleci/cli.yml`.

## Node CA certs behind Zscaler

On corporate networks with Zscaler TLS interception, curl works (it reads the macOS keychain) but Node-based tools like `npm`/`npx` fail with `UNABLE_TO_GET_ISSUER_CERT_LOCALLY`, because Node doesn't read the keychain. The fish config sets `NODE_EXTRA_CA_CERTS` if `~/zscaler-ca.pem` exists, but that file isn't created by bootstrap — generate it once per machine:

```fish
security find-certificate -a -c "Zscaler" -p /System/Library/Keychains/SystemRootCertificates.keychain > ~/zscaler-ca.pem
```

Regenerate it the same way if the proxy or its cert changes. On a machine without Zscaler, just skip this — the fish config no-ops if the file is missing.

## Fisher plugins

`fish_plugins` (tracked in the repo, symlinked into `~/.config/fish/`) lists `jorgebucaran/fisher` itself plus `fzf.fish`, `autopair.fish`, and `sponge`. Bootstrap installs fisher but doesn't auto-install the plugins. One-liner:

```fish
fish -c 'fisher update'
```

Wrangle's fisher-drift pass on the next run will also notice any missing-from-installed plugins and offer to install them per-item.
