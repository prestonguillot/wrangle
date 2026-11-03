# ── Shell behavior ────────────────────────────────────────────────────────
set -g fish_key_bindings fish_vi_key_bindings
set fish_greeting
set -g fish_history_ignore_duplicates yes
set -g fish_history_ignore_space yes
set -g history_max_size 2000

# ── PATH ──────────────────────────────────────────────────────────────────
# --path: act on $PATH directly (default acts on $fish_user_paths, which
#         only auto-prepends to PATH when universal-scoped — we want session-
#         scoped so config.fish is the source of truth across machines).
# --global: per-shell-session, not persisted as a universal var.
# --prepend / --append are idempotent: re-sourcing config.fish won't dup entries.
fish_add_path --path --global --prepend $HOME/bin
fish_add_path --path --global --append  $HOME/.local/bin /sbin /usr/sbin

# ── Env exports ───────────────────────────────────────────────────────────
# Suppress venv's `(venvname)` prompt prefix — tide already shows the venv.
set -gx VIRTUAL_ENV_DISABLE_PROMPT 1

# ── Tool integrations ─────────────────────────────────────────────────────
# Locate brew across Apple Silicon (/opt/homebrew) and Intel (/usr/local).
for _brew in /opt/homebrew/bin/brew /usr/local/bin/brew
    if test -x $_brew
        eval ($_brew shellenv)
        break
    end
end
set -e _brew
# brew shellenv moves Homebrew to the front of PATH; put ~/bin back ahead of it.
fish_add_path --path --global --move --prepend $HOME/bin

command -q zoxide; and zoxide init fish --cmd cd | source
command -q direnv; and direnv hook fish | source
command -q fnm;    and fnm env --use-on-cd | source

# ── Aliases (fish's `alias NAME CMD` is `function NAME; CMD $argv; end`) ──
# Convention: alias for one-word redirects and simple flag composition;
# function only when there's actual logic.
alias cls clear
alias h 'cd ~'
alias htop btop                          # muscle-memory redirect to the better tool
alias vim nvim                           # muscle-memory redirect to neovim
alias vi  nvim

# ls family (eza wrappers)
alias l   'eza --icons'
alias ls  'eza --icons'                  # overrides built-in /bin/ls
alias la  'eza -a --icons'
alias ll  'eza -la --git --icons'
alias lla 'eza -la --git --icons -a'

# ── Functions (logic-bearing wrappers) ────────────────────────────────────

# eza recursive/tree views with optional integer depth as the first arg.
function lr --description 'eza -R with depth (default 1)'
    set -l depth 1
    if test (count $argv) -gt 0; and string match -qr '^\d+$' -- $argv[1]
        set depth $argv[1]; set -e argv[1]
    end
    eza -R -L $depth --icons $argv
end
function lt --description 'eza -T with depth (default 1)'
    set -l depth 1
    if test (count $argv) -gt 0; and string match -qr '^\d+$' -- $argv[1]
        set depth $argv[1]; set -e argv[1]
    end
    eza -T -L $depth --icons $argv
end
function lra --description 'eza -aR with depth (default 1)'
    set -l depth 1
    if test (count $argv) -gt 0; and string match -qr '^\d+$' -- $argv[1]
        set depth $argv[1]; set -e argv[1]
    end
    eza -aR -L $depth --icons $argv
end
function lta --description 'eza -aT with depth (default 1)'
    set -l depth 1
    if test (count $argv) -gt 0; and string match -qr '^\d+$' -- $argv[1]
        set depth $argv[1]; set -e argv[1]
    end
    eza -aT -L $depth --icons $argv
end

function hey --description 'claude -p with auto-joined prompt words'
    if test (count $argv) -eq 0
        echo "hey: usage: hey <prompt words>" >&2
        return 2
    end
    claude -p "$argv"
end

# tldr-then-man: try tldr first, fall back to real man if no tldr page.
# Named `tmi` so plain `man` stays as the real man — no surprise shadowing.
function tmi --description 'tldr first, real man as fallback'
    # tldr's auto color detection also looks at stderr, and `2>/dev/null` (which
    # hides its page-not-found error) makes that look like a pipe. Ask for color
    # explicitly whenever our own stdout is a terminal.
    set -l color auto
    isatty stdout; and set color always
    if command -q tldr; and command tldr --color $color $argv 2>/dev/null
        return 0
    end
    command man $argv
end