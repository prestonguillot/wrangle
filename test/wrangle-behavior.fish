# wrangle behavior tests — invoke wrangle inside a hermetic fixture repo
# and assert observable side-effects.
#
# Hermeticity: wrangle resolves its repo from its own script path
# (`git -C $script_dir rev-parse --show-toplevel`), so to isolate a test
# we copy scripts/ into a fresh `git init`ed fixture and run THAT copy.
# Combined with HOME=$fake_home this isolates BOTH the repo and all state
# files. Earlier versions of these tests ran wrangle against the real
# working tree (only HOME was isolated), which caused Pass 1's auto-switch
# to silently move the developer's HEAD to `personal` mid-test — see
# memory note `feedback_tests_switch_branches.md`.

set -l repo_root (dirname (realpath (status -f)))/..
source $repo_root/test/helpers/fixture.fish

# Build a fresh fixture: clone scripts/ + minimal repo skeleton into a
# new git repo with `personal` checked out. Echoes two paths on stdout:
# fixture repo, then fake home.
function _wrangle_fixture --inherit-variable repo_root
    set -l fix (mktemp -d)
    set -l home_dir (mktemp -d)

    _wrangle_fixture_init_repo $fix "wrangle-behavior-test" main
    _wrangle_fixture_install_scripts $fix $repo_root
    # `real` ignore files (the repo's own templates) so behavior here matches
    # what wrangle does against an actual clone.
    _wrangle_fixture_seed_files $fix $repo_root real

    git -C $fix add -A
    git -C $fix commit -q -m "fixture seed"

    # wrangle expects a `personal` branch (the default machine-branch).
    # Create it directly off main so the auto-switch pass has somewhere to go.
    git -C $fix checkout -q -b personal

    echo $fix
    echo $home_dir
end

# ─── review-docs requires claude ──────────────────────────────────────────

set -l f1 (_wrangle_fixture)
set -l fix1 $f1[1]; set -l home1 $f1[2]
env HOME=$home1 PATH=/nonexistent-bin $fix1/scripts/wrangle review-docs 2>/dev/null
@test "review-docs without claude on PATH exits non-zero" $status -ne 0
rm -rf $fix1 $home1

# ─── Dry-run is hermetic ─────────────────────────────────────────────────
# `sync --dry-run` must never create a last-wrangle stamp.

set -l f2 (_wrangle_fixture)
set -l fix2 $f2[1]; set -l home2 $f2[2]
env HOME=$home2 $fix2/scripts/wrangle sync --dry-run >/dev/null 2>&1
test -f $home2/.cache/dotfiles/last-wrangle
@test "sync --dry-run does NOT create last-wrangle stamp" $status -ne 0
rm -rf $fix2 $home2

# ─── Pass 1 skip causes are reported differently ─────────────────────────
# The header prints inside each branch, so a skipped pass leaves no empty
# section. --no-branch-switch is silent (you just typed it); the env var is
# explained (set once and forgotten, it silently stops framework updates).

set -l f3 (_wrangle_fixture)
set -l fix3 $f3[1]; set -l home3 $f3[2]

set -l out_flag (env HOME=$home3 $fix3/scripts/wrangle sync --dry-run --no-branch-switch 2>&1 | string join \n)
string match -q "*Framework update*" -- "$out_flag"
@test "sync --no-branch-switch prints no Framework update section" $status -ne 0

set -l out_env (env HOME=$home3 WRANGLE_NO_BRANCH_SWITCH=1 $fix3/scripts/wrangle sync --dry-run 2>&1 | string join \n)
string match -q "*Framework update*" -- "$out_env"
@test "WRANGLE_NO_BRANCH_SWITCH prints a Framework update section" $status -eq 0

string match -q "*WRANGLE_NO_BRANCH_SWITCH=1 is set in your environment*" -- "$out_env"
@test "WRANGLE_NO_BRANCH_SWITCH names the variable that caused the skip" $status -eq 0

string match -q "*was not merged into*" -- "$out_env"
@test "WRANGLE_NO_BRANCH_SWITCH says what did not happen" $status -eq 0

string match -q "*wrangle update*unset the variable*" -- "$out_env"
@test "WRANGLE_NO_BRANCH_SWITCH says what to do about it" $status -eq 0

set -l out_none (env HOME=$home3 $fix3/scripts/wrangle sync --dry-run 2>&1 | string join \n)
string match -q "*Framework update*" -- "$out_none"
@test "sync with no skip flag runs Pass 1 normally" $status -eq 0

rm -rf $fix3 $home3

# ─── Brew drift: failed state scan ────────────────────────────────────────
# Regression: when `brew bundle dump` fails, dump-brewfile writes nothing and
# the old code compared the Brewfile against an empty dump — reporting every
# tracked entry as "NOT installed" and offering to install or remove them all.
# A failed scan must say so and skip the pass instead.

set -l f4 (_wrangle_fixture)
set -l fix4 $f4[1]; set -l home4 $f4[2]
set -l stubdir4 (mktemp -d)

printf '#!/bin/sh\nif [ "$1" = "bundle" ]; then echo "Error: dump is broken" >&2; exit 1; fi\nexit 0\n' > $stubdir4/brew
chmod +x $stubdir4/brew

printf 'brew "bash"\nbrew "jq"\nbrew "ripgrep"\n' > $fix4/Brewfile
git -C $fix4 commit -q -am 'brewfile entries for failed-scan test'

begin
    set -lx HOME $home4
    set -lx PATH $stubdir4 $PATH
    set -l out (env WRANGLE_NO_BRANCH_SWITCH=1 $fix4/scripts/wrangle sync --dry-run 2>&1 | string join \n)

    string match -q '*brew state scan failed*' -- "$out"
    @test "failed brew scan → says the scan failed" $status -eq 0

    not string match -q '*NOT installed*' -- "$out"
    @test "failed brew scan → does not report tracked entries as missing" $status -eq 0
end

rm -rf $fix4 $home4 $stubdir4
