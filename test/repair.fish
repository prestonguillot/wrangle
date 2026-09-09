# `wrangle repair` — recovering a machine whose home/ package will not stow.
#
# The fixture reproduces the reported end state: home/ holds an absolute
# symlink (which stow refuses, blocking the whole package) and also holds
# paths that were moved in before the breakage and never symlinked back. That
# is the state sync cannot fix, because sync stops at the re-stow pass.
#
# These tests use REAL stow rather than a stub — the behavior under test is
# stow's own refusal and its recovery, so a stub would assert nothing.
# scripts/run-tests requires stow for this reason.

set -l repo_root (dirname (realpath (status -f)))/..
source $repo_root/test/helpers/fixture.fish

# A repo whose home/ is poisoned, plus a fake HOME with nothing linked.
# Echoes fixture repo, then fake home.
function _repair_fixture --inherit-variable repo_root
    set -l fix (mktemp -d)
    set -l home_dir (mktemp -d)

    _wrangle_fixture_init_repo $fix "repair-test" main
    _wrangle_fixture_install_scripts $fix $repo_root
    _wrangle_fixture_seed_files $fix $repo_root real

    # The poison: an absolute symlink inside an otherwise ordinary directory.
    mkdir -p $fix/home/.config/iterm2
    echo plist > $fix/home/.config/iterm2/prefs
    ln -s /var/tmp $fix/home/.config/iterm2/AppSupport

    # Stranded: moved into the repo before the breakage, never linked back.
    mkdir -p $fix/home/.config/mc
    echo hotlist > $fix/home/.config/mc/hotlist

    git -C $fix add -A
    git -C $fix commit -q -m "fixture seed"
    git -C $fix checkout -q -b personal

    mkdir -p $home_dir/.cache/dotfiles $home_dir/.config
    touch $home_dir/.cache/dotfiles/last-wrangle
    echo "claude_doc_review no" > $home_dir/.cache/dotfiles/wrangle-config

    echo $fix
    echo $home_dir
end

# Does this stow refuse to store an absolute symlink?
#
# The refusal landed in stow 2.4.0; 2.3.1 (what Ubuntu ships, and so what CI
# runs) stows one happily — producing a link in ~ that stow can never remove
# again. wrangle's pre-flight refuses these on every version, because they are
# a bad idea on every version, but only a stow that refuses can put a machine
# into the state the next block establishes. So that block is gated, and the
# recovery tests below are not: they hold regardless.
function _stow_refuses_abs_symlinks
    set -l d (mktemp -d)
    mkdir -p $d/pkg/sub $d/target
    ln -s /var/tmp $d/pkg/sub/abs
    set -l refused 0
    if stow --no-folding -t $d/target -d $d -n pkg >/dev/null 2>&1
        set refused 1
    end
    rm -rf $d
    return $refused
end

# ─── The broken state is real ────────────────────────────────────────────
# Establish that sync genuinely cannot proceed, so the recovery below is
# recovering something rather than passing vacuously.

if _stow_refuses_abs_symlinks
set -l f0 (_repair_fixture)
set -l fix0 $f0[1]; set -l home0 $f0[2]

set -l sync_rv
begin
    set -lx HOME $home0
    printf 's\ns\ns\n' | env WRANGLE_NO_BRANCH_SWITCH=1 WRANGLE_NO_COMMIT=1 \
        WRANGLE_NO_PUSH=1 $fix0/scripts/wrangle sync >$home0/sync-before.log 2>&1
    set sync_rv $status
end

test $sync_rv -ne 0
@test "sync fails while home/ holds an unstowable path" $status -eq 0

grep -q 'STOW REFUSED' $home0/sync-before.log
@test "sync explains why it stopped" $status -eq 0

not test -e $home0/.config/mc/hotlist
@test "stranded file is not linked into ~ before repair" $status -eq 0

rm -rf $fix0 $home0
end

# ─── repair --dry-run changes nothing ────────────────────────────────────

set -l f1 (_repair_fixture)
set -l fix1 $f1[1]; set -l home1 $f1[2]

begin
    set -lx HOME $home1
    env $fix1/scripts/wrangle repair --dry-run >$home1/dry.log 2>&1
end

grep -q 'Dry run' $home1/dry.log
@test "repair --dry-run says it is a dry run" $status -eq 0

grep -q 'AppSupport' $home1/dry.log
@test "repair --dry-run names the unstowable path" $status -eq 0

test -L $fix1/home/.config/iterm2/AppSupport
@test "repair --dry-run leaves the repo untouched" $status -eq 0

not test -e $home1/.config/iterm2
@test "repair --dry-run writes nothing into ~" $status -eq 0

rm -rf $fix1 $home1

# ─── repair recovers the machine ─────────────────────────────────────────
# One [u]ntrack for the absolute symlink; the re-stow that follows is what
# links back everything the breakage stranded.

set -l f2 (_repair_fixture)
set -l fix2 $f2[1]; set -l home2 $f2[2]

begin
    set -lx HOME $home2
    printf 'u\n' | env $fix2/scripts/wrangle repair >$home2/repair.log 2>&1
end

test -L $home2/.config/iterm2/AppSupport
@test "repair moves the unstowable symlink back to ~" $status -eq 0

test (readlink $home2/.config/iterm2/AppSupport) = /var/tmp
@test "repair preserves the symlink's target" $status -eq 0

not test -e $fix2/home/.config/iterm2/AppSupport
@test "repair removes the unstowable path from home/" $status -eq 0

test -L $home2/.config/mc/hotlist
@test "repair links back the file the breakage stranded" $status -eq 0

test (cat $home2/.config/mc/hotlist) = hotlist
@test "the relinked file resolves to its content" $status -eq 0

test -L $home2/.config/iterm2/prefs
@test "repair links back the sibling of the offending symlink" $status -eq 0

grep -q 'moved back' $home2/repair.log
@test "repair reports what it moved back" $status -eq 0

# And the machine works again.
set -l after_rv
begin
    set -lx HOME $home2
    printf 's\ns\ns\n' | env WRANGLE_NO_BRANCH_SWITCH=1 WRANGLE_NO_COMMIT=1 \
        WRANGLE_NO_PUSH=1 $fix2/scripts/wrangle sync >$home2/sync-after.log 2>&1
    set after_rv $status
end

test $after_rv -eq 0
@test "sync succeeds after repair" $status -eq 0

rm -rf $fix2 $home2

# ─── repair never overwrites something already in ~ ──────────────────────
# wrangle does not remove or clobber local state, so an occupied target is a
# refusal, not an overwrite.

set -l f3 (_repair_fixture)
set -l fix3 $f3[1]; set -l home3 $f3[2]
mkdir -p $home3/.config/iterm2
echo "mine" > $home3/.config/iterm2/AppSupport

begin
    set -lx HOME $home3
    printf 'u\n' | env $fix3/scripts/wrangle repair >$home3/repair.log 2>&1
end

test (cat $home3/.config/iterm2/AppSupport) = mine
@test "repair does not overwrite an existing path in ~" $status -eq 0

grep -q 'already exists' $home3/repair.log
@test "repair says why it refused" $status -eq 0

rm -rf $fix3 $home3

# ─── repair on a healthy repo reports nothing to do ──────────────────────

set -l f4 (_repair_fixture)
set -l fix4 $f4[1]; set -l home4 $f4[2]
rm $fix4/home/.config/iterm2/AppSupport
git -C $fix4 commit -q -am "drop the unstowable path"

begin
    set -lx HOME $home4
    env $fix4/scripts/wrangle repair >$home4/repair.log 2>&1
end

grep -q 'nothing in .*home/.* that stow refuses' $home4/repair.log
@test "repair reports a clean package as clean" $status -eq 0

grep -q 'no symlinks in ~ pointing at missing paths' $home4/repair.log
@test "repair reports no dangling symlinks" $status -eq 0

rm -rf $fix4 $home4
