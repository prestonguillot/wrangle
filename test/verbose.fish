# `wrangle sync --verbose` behavior tests. For each domain that does
# silent skiplist filtering, verify a one-line "matches .<file>" note
# fires under --verbose and does NOT fire without it.
#
# Hermeticity: same fixture pattern as test/wrangle-behavior.fish — copy
# scripts/ into a fresh `git init`ed repo and run THAT copy with a fake
# HOME so universals + state files stay isolated.

set -l repo_root (dirname (realpath (status -f)))/..
source $repo_root/test/helpers/fixture.fish

# Build a minimal sync-capable fixture. Returns: <fix> <home_dir>.
function _wrangle_verbose_fixture --inherit-variable repo_root
    set -l fix (mktemp -d)
    set -l home_dir (mktemp -d)

    _wrangle_fixture_init_repo $fix "verbose-test" main
    _wrangle_fixture_install_scripts $fix $repo_root
    # Blank ignore files: these tests write their own entries per domain.
    _wrangle_fixture_seed_files $fix $repo_root empty

    git -C $fix add -A
    git -C $fix commit -q -m "seed"
    git -C $fix checkout -q -b personal
    git -C $fix commit -q --allow-empty -m "personal: init"

    echo $fix
    echo $home_dir
end

# ─── Domain 1: .dotignore ─────────────────────────────────────────────────
# Add a real path under $fake_home/.config/foo and a `.config/foo` entry
# in $fix/.dotignore. Run `wrangle sync --dry-run [--verbose]` and verify
# the verbose-only emit.

set -l f1 (_wrangle_verbose_fixture)
set -l fix1 $f1[1]; set -l home1 $f1[2]
mkdir -p $home1/.config
echo "dummy" > $home1/.config/dotignore-test-file
echo ".config/dotignore-test-file" >> $fix1/.dotignore
git -C $fix1 commit -q -am 'dotignore entry for test'

# Without --verbose: silent skip.
begin
    set -lx HOME $home1
    set -l out (env WRANGLE_NO_BRANCH_SWITCH=1 $fix1/scripts/wrangle sync --dry-run 2>&1)
    not string match -q '*matches .dotignore*' -- "$out"
    @test "dotfile: no --verbose → no 'matches .dotignore' line" $status -eq 0
end

# With --verbose: emit appears.
begin
    set -lx HOME $home1
    set -l out (env WRANGLE_NO_BRANCH_SWITCH=1 $fix1/scripts/wrangle sync --dry-run --verbose 2>&1)
    string match -q '*matches .dotignore*' -- "$out"
    @test "dotfile: --verbose → 'matches .dotignore' line appears" $status -eq 0
    string match -q '*dotignore-test-file*' -- "$out"
    @test "dotfile: --verbose mentions the specific path" $status -eq 0
end

rm -rf $fix1 $home1

# ─── Domain 2: .fisherignore ─────────────────────────────────────────────
# Stub `fisher list` via a conf.d file in fake HOME so the fisher pass
# runs (the gate `functions -q fisher` will pass because conf.d files
# are sourced by all fish processes, interactive or not).

set -l f2 (_wrangle_verbose_fixture)
set -l fix2 $f2[1]; set -l home2 $f2[2]
mkdir -p $home2/.config/fish/conf.d
echo 'function fisher; if test "$argv[1]" = list; echo "stub-author/stub-plugin"; end; end' \
    > $home2/.config/fish/conf.d/fisher-stub.fish
echo "stub-author/stub-plugin" >> $fix2/.fisherignore
git -C $fix2 commit -q -am 'fisherignore entry for test'

# Pin XDG_CONFIG_HOME so fish finds our conf.d stub regardless of the host's
# XDG settings (Linux CI sometimes presets XDG_CONFIG_HOME to a path that
# bypasses $HOME/.config/fish/ entirely).
begin
    set -lx HOME $home2
    set -lx XDG_CONFIG_HOME $home2/.config
    set -l out (env WRANGLE_NO_BRANCH_SWITCH=1 $fix2/scripts/wrangle sync --dry-run 2>&1)
    not string match -q '*matches .fisherignore*' -- "$out"
    @test "fisher: no --verbose → no 'matches .fisherignore' line" $status -eq 0
end

begin
    set -lx HOME $home2
    set -lx XDG_CONFIG_HOME $home2/.config
    set -l out (env WRANGLE_NO_BRANCH_SWITCH=1 $fix2/scripts/wrangle sync --dry-run --verbose 2>&1)
    string match -q '*matches .fisherignore*' -- "$out"
    @test "fisher: --verbose → 'matches .fisherignore' line appears" $status -eq 0
    string match -q '*stub-author/stub-plugin*' -- "$out"
    @test "fisher: --verbose mentions the specific plugin" $status -eq 0
end

rm -rf $fix2 $home2

# ─── Domain 3: .univignore ───────────────────────────────────────────────
# Pre-populate $fake_home/.config/fish/fish_variables so the wrangle
# subprocess (which inherits HOME) sees a fake universal.
#
# fish's fish_variables format is one line per var, e.g.:
#   SETUVAR _testvar:foo
# The wrangle subprocess reads this on startup.

set -l f3 (_wrangle_verbose_fixture)
set -l fix3 $f3[1]; set -l home3 $f3[2]
mkdir -p $home3/.config/fish $home3/.local/share/fish
# fish_variables format requires the magic VERSION header — without it
# fish prints "Unable to parse universal variable message" and skips all
# our seeded vars.
#
# Seed BOTH the legacy ($XDG_CONFIG_HOME/fish/) and modern
# ($XDG_DATA_HOME/fish/) locations because fish 3.4+ moved the file
# (CI's fish version may differ from local).
printf '%s\n%s\n%s\n' \
    '# This file contains fish universal variable definitions.' \
    '# VERSION: 3.0' \
    'SETUVAR univignore_test_var:bar' \
    | tee $home3/.config/fish/fish_variables $home3/.local/share/fish/fish_variables \
    > /dev/null
echo "univignore_test_var" >> $fix3/.univignore
git -C $fix3 commit -q -am 'univignore entry for test'

begin
    set -lx HOME $home3
    set -lx XDG_CONFIG_HOME $home3/.config
    set -lx XDG_DATA_HOME $home3/.local/share
    set -l out (env WRANGLE_NO_BRANCH_SWITCH=1 $fix3/scripts/wrangle sync --dry-run 2>&1)
    not string match -q '*matches .univignore*' -- "$out"
    @test "univ-var: no --verbose → no 'matches .univignore' line" $status -eq 0
end

begin
    set -lx HOME $home3
    set -lx XDG_CONFIG_HOME $home3/.config
    set -lx XDG_DATA_HOME $home3/.local/share
    set -l out (env WRANGLE_NO_BRANCH_SWITCH=1 $fix3/scripts/wrangle sync --dry-run --verbose 2>&1)
    string match -q '*matches .univignore*' -- "$out"
    @test "univ-var: --verbose → 'matches .univignore' line appears" $status -eq 0
    string match -q '*univignore_test_var*' -- "$out"
    @test "univ-var: --verbose mentions the specific var" $status -eq 0
end

rm -rf $fix3 $home3

# ─── Domain 4: .brewignore (via dump-brewfile) ───────────────────────────
# Stub `brew` so `brew bundle dump --force --file=<tmp>` writes
# a fake Brewfile containing a line matching the .brewignore pattern.
# dump-brewfile's filter then drops it, and --verbose surfaces what was dropped.

set -l f4 (_wrangle_verbose_fixture)
set -l fix4 $f4[1]; set -l home4 $f4[2]
set -l stubdir4 (mktemp -d)

# Brew stub: when invoked as `brew bundle dump ... --file=<path>` OR
# `brew bundle dump ... --file <path>`, write a fake one-line Brewfile
# to that path. For any other invocation, exit 0.
echo '#!/bin/sh' > $stubdir4/brew
echo 'while [ $# -gt 0 ]; do' >> $stubdir4/brew
echo '  case "$1" in' >> $stubdir4/brew
echo '    --file=*) path="${1#--file=}"; printf "brew \"brewignore-test-pkg\"\n" > "$path"; exit 0 ;;' >> $stubdir4/brew
echo '    --file)   path="$2"; printf "brew \"brewignore-test-pkg\"\n" > "$path"; exit 0 ;;' >> $stubdir4/brew
echo '  esac' >> $stubdir4/brew
echo '  shift' >> $stubdir4/brew
echo 'done' >> $stubdir4/brew
echo 'exit 0' >> $stubdir4/brew
chmod +x $stubdir4/brew

echo "brewignore-test-pkg" >> $fix4/.brewignore
git -C $fix4 commit -q -am 'brewignore entry for test'

# Without --verbose: silent.
begin
    set -lx HOME $home4
    set -lx PATH $stubdir4 $PATH
    set -l out (env WRANGLE_NO_BRANCH_SWITCH=1 $fix4/scripts/wrangle sync --dry-run 2>&1)
    not string match -q '*matches .brewignore*' -- "$out"
    @test "brew: no --verbose → no 'matches .brewignore' line" $status -eq 0
end

# With --verbose: dump-brewfile emits to stderr, wrangle re-emits as dim info.
begin
    set -lx HOME $home4
    set -lx PATH $stubdir4 $PATH
    set -l out (env WRANGLE_NO_BRANCH_SWITCH=1 $fix4/scripts/wrangle sync --dry-run --verbose 2>&1)
    string match -q '*matches .brewignore*' -- "$out"
    @test "brew: --verbose → 'matches .brewignore' line appears" $status -eq 0
    string match -q '*brewignore-test-pkg*' -- "$out"
    @test "brew: --verbose mentions the specific package" $status -eq 0
end

rm -rf $fix4 $home4 $stubdir4

# ─── CLI: --verbose accepted on sync, rejected on update/push/review-docs/merge

set -l fcli (_wrangle_verbose_fixture)
set -l fixcli $fcli[1]; set -l homecli $fcli[2]

# Accepted on sync (no error from the flag gate).
begin
    set -lx HOME $homecli
    env WRANGLE_NO_BRANCH_SWITCH=1 $fixcli/scripts/wrangle sync --dry-run --verbose >/dev/null 2>&1
    @test "sync --verbose accepted (no flag-gate error)" $status -eq 0
end

# Rejected on merge.
env HOME=$homecli $fixcli/scripts/wrangle merge personal --verbose 2>/dev/null
@test "merge --verbose rejected" $status -ne 0

set -l rej_out (env HOME=$homecli $fixcli/scripts/wrangle merge personal --verbose 2>&1)
string match -q '*unknown option*' -- "$rej_out"; or string match -q '*--verbose*' -- "$rej_out"
@test "merge --verbose rejection mentions the flag" $status -eq 0

# Rejected on update / push / review-docs.
for sub in update push review-docs
    env HOME=$homecli $fixcli/scripts/wrangle $sub --verbose 2>/dev/null
    @test "$sub --verbose rejected" $status -ne 0
end

rm -rf $fixcli $homecli
