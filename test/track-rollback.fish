# Regression tests for the dotfile track path — the bug that moved four
# directories out of a user's ~ and symlinked only one of them back.
#
# The trigger was ~/.config/iterm2/AppSupport, an absolute symlink inside an
# otherwise ordinary directory. GNU stow refuses a package containing one at
# any depth, and home/ is a single package, so the first bad track poisoned
# every track that followed. Each subsequent [t]rack still ran its mv, still
# failed at stow, and still reported success — _track returned 0 either way.
#
# Three properties are pinned here:
#   1. a path stow cannot manage is reported and never moved
#   2. a stow failure rolls the mv back, so ~ is left as it was
#   3. one stow failure stops the pass instead of stranding the next path
#
# Hermeticity: fixture repo + fake HOME, per test/helpers/fixture.fish.

set -l repo_root (dirname (realpath (status -f)))/..
source $repo_root/test/helpers/fixture.fish

# A `stow` that fails on one specific invocation and succeeds otherwise.
#
# Call ordering matters: sync's Pass 4 re-stow runs before the dotfile pass,
# and it exits 1 on failure, so a stub that always failed would never let the
# test reach _track at all. Call 1 is Pass 4; call 2 is the re-stow inside the
# first _track; call 3 is _track's post-rollback check.
function _stow_stub --argument-names dir fail_on
    set -l counter $dir/stow-calls
    echo 0 > $counter
    printf '%s\n' \
        '#!/bin/sh' \
        "c=\$(cat $counter 2>/dev/null || echo 0)" \
        'c=$((c+1))' \
        "echo \$c > $counter" \
        "if [ \"\$c\" = \"$fail_on\" ]; then" \
        '  echo "WARNING! stowing home would cause conflicts:" >&2' \
        '  echo "  * existing target is not owned by stow: .config/blocker" >&2' \
        '  echo "All operations aborted." >&2' \
        '  exit 1' \
        'fi' \
        'exit 0' > $dir/stow
    chmod +x $dir/stow
    echo '#!/bin/sh' > $dir/brew
    echo 'exit 0' >> $dir/brew
    chmod +x $dir/brew
end

# Fixture with a fake HOME that is past both one-time prompts, so the only
# prompts in a run are the dotfile pass's own. Echoes fixture, home, stubdir.
function _track_fixture --inherit-variable repo_root
    set -l fix (mktemp -d)
    set -l home_dir (mktemp -d)
    set -l stubdir (mktemp -d)

    _wrangle_fixture_init_repo $fix "track-rollback-test" main
    _wrangle_fixture_install_scripts $fix $repo_root
    # `real` ignore files: the top-level dotfile glob works now, and the real
    # .dotignore is what keeps ~/.cache and friends out of the candidate list.
    _wrangle_fixture_seed_files $fix $repo_root real

    git -C $fix add -A
    git -C $fix commit -q -m "fixture seed"
    git -C $fix checkout -q -b personal

    # Past the first-run banner and the claude opt-in question.
    mkdir -p $home_dir/.cache/dotfiles
    touch $home_dir/.cache/dotfiles/last-wrangle
    echo "claude_doc_review no" > $home_dir/.cache/dotfiles/wrangle-config

    mkdir -p $home_dir/.config

    echo $fix
    echo $home_dir
    echo $stubdir
end

# ─── A path stow cannot manage is reported, not moved ────────────────────
# The shape that broke: a real directory holding an absolute symlink. The
# candidate itself is not a symlink, so the old `test -L` filter saw nothing.

set -l f1 (_track_fixture)
set -l fix1 $f1[1]; set -l home1 $f1[2]; set -l stub1 $f1[3]
_stow_stub $stub1 0   # never fail: real stow is not the thing under test here

mkdir -p $home1/.config/hazardous/nested
echo real > $home1/.config/hazardous/afile
ln -s /var/tmp $home1/.config/hazardous/nested/AppSupport

begin
    set -lx HOME $home1
    set -lx PATH $stub1 $PATH
    printf 's\n' | env WRANGLE_NO_BRANCH_SWITCH=1 $fix1/scripts/wrangle sync \
        >$home1/run.log 2>&1
end

test -d $home1/.config/hazardous
@test "unstowable path is left in ~" $status -eq 0

test -f $home1/.config/hazardous/afile
@test "unstowable path keeps its contents in ~" $status -eq 0

not test -e $fix1/home/.config/hazardous
@test "unstowable path is NOT moved into the repo" $status -eq 0

grep -q "can't be tracked" $home1/run.log
@test "unstowable path is reported as untrackable" $status -eq 0

grep -q 'AppSupport' $home1/run.log
@test "report names the offending path inside the directory" $status -eq 0

grep -q 'absolute path' $home1/run.log
@test "report states the cause in plain language" $status -eq 0

rm -rf $fix1 $home1 $stub1

# ─── [t]rack is not accepted for an unstowable path ──────────────────────
# Asserted behaviorally rather than by reading the prompt: fish's `read -P`
# writes no prompt when stdin is a pipe, so the prompt text never reaches a
# test log. Typing `t` here must be rejected as unrecognized input.

set -l f1b (_track_fixture)
set -l fix1b $f1b[1]; set -l home1b $f1b[2]; set -l stub1b $f1b[3]
_stow_stub $stub1b 0

mkdir -p $home1b/.config/hazardous
ln -s /var/tmp $home1b/.config/hazardous/AppSupport

begin
    set -lx HOME $home1b
    set -lx PATH $stub1b $PATH
    printf 't\n' | env WRANGLE_NO_BRANCH_SWITCH=1 $fix1b/scripts/wrangle sync \
        >$home1b/run.log 2>&1
end

grep -q "answer i/s/q" $home1b/run.log
@test "[t] is rejected as unrecognized for an unstowable path" $status -eq 0

test -d $home1b/.config/hazardous
@test "answering [t] on an unstowable path still leaves it in ~" $status -eq 0

not test -e $fix1b/home/.config/hazardous
@test "answering [t] on an unstowable path moves nothing" $status -eq 0

rm -rf $fix1b $home1b $stub1b

# ─── A stow failure rolls the move back ──────────────────────────────────
# Force the failure at the _track re-stow (call 2) with an otherwise
# trackable path, so the rollback path is what's under test.

set -l f2 (_track_fixture)
set -l fix2 $f2[1]; set -l home2 $f2[2]; set -l stub2 $f2[3]
_stow_stub $stub2 2

mkdir -p $home2/.config/plain
echo content > $home2/.config/plain/settings

begin
    set -lx HOME $home2
    set -lx PATH $stub2 $PATH
    printf 't\n' | env WRANGLE_NO_BRANCH_SWITCH=1 $fix2/scripts/wrangle sync \
        >$home2/run.log 2>&1
end

test -d $home2/.config/plain
@test "rollback: path is back in ~ after stow fails" $status -eq 0

test -f $home2/.config/plain/settings
@test "rollback: contents survive the round trip" $status -eq 0

not test -e $fix2/home/.config/plain
@test "rollback: path is not left stranded in the repo" $status -eq 0

grep -q 'STOW REFUSED' $home2/run.log
@test "rollback: failure is reported loudly" $status -eq 0

grep -q 'rolled back' $home2/run.log
@test "rollback: message says the move was undone" $status -eq 0

not grep -q '1 tracked' $home2/run.log
@test "rollback: a failed track is NOT counted as tracked" $status -eq 0

rm -rf $fix2 $home2 $stub2

# ─── One stow failure stops the pass ─────────────────────────────────────
# Two trackable paths, stow failing on the first track. The second must not
# be moved: home/ is one package, so it would fail identically — after its
# own mv had already taken it out of ~. That cascade is what stranded three
# directories in the original report.

set -l f3 (_track_fixture)
set -l fix3 $f3[1]; set -l home3 $f3[2]; set -l stub3 $f3[3]
_stow_stub $stub3 2

mkdir -p $home3/.config/aaa $home3/.config/bbb
echo a > $home3/.config/aaa/file
echo b > $home3/.config/bbb/file

begin
    set -lx HOME $home3
    set -lx PATH $stub3 $PATH
    printf 't\nt\n' | env WRANGLE_NO_BRANCH_SWITCH=1 $fix3/scripts/wrangle sync \
        >$home3/run.log 2>&1
end

test -d $home3/.config/aaa
@test "cascade: first path is restored to ~" $status -eq 0

test -d $home3/.config/bbb
@test "cascade: second path is still in ~" $status -eq 0

not test -e $fix3/home/.config/bbb
@test "cascade: second path was never moved into the repo" $status -eq 0

grep -q 'stopping the dotfile pass' $home3/run.log
@test "cascade: the pass reports that it stopped" $status -eq 0

rm -rf $fix3 $home3 $stub3

# ─── The success path still works ────────────────────────────────────────
# Guard against over-refusing: an ordinary directory must still track.

set -l f4 (_track_fixture)
set -l fix4 $f4[1]; set -l home4 $f4[2]; set -l stub4 $f4[3]
_stow_stub $stub4 0

mkdir -p $home4/.config/ordinary
echo fine > $home4/.config/ordinary/conf

begin
    set -lx HOME $home4
    set -lx PATH $stub4 $PATH
    printf 't\n' | env WRANGLE_NO_BRANCH_SWITCH=1 $fix4/scripts/wrangle sync \
        >$home4/run.log 2>&1
end

test -f $fix4/home/.config/ordinary/conf
@test "success: an ordinary path still moves into the repo" $status -eq 0

grep -q 'moved to home/.config/ordinary' $home4/run.log
@test "success: the track is reported" $status -eq 0

rm -rf $fix4 $home4 $stub4

# ─── Pass 4 names the real cause ─────────────────────────────────────────
# This is the gate a machine with an already-broken home/ hits on every run,
# so it is the message that has to explain the situation. It used to say
# "resolve conflicts (real files at target paths)" — one of several things
# stow refuses, and not the one that actually breaks people — and named no
# path at all.

set -l f5 (_track_fixture)
set -l fix5 $f5[1]; set -l home5 $f5[2]; set -l stub5 $f5[3]
_stow_stub $stub5 1   # fail the very first stow: Pass 4 itself

set -l rv5
begin
    set -lx HOME $home5
    set -lx PATH $stub5 $PATH
    env WRANGLE_NO_BRANCH_SWITCH=1 $fix5/scripts/wrangle sync >$home5/run.log 2>&1
    set rv5 $status
end

@test "Pass 4 stow failure exits non-zero" $rv5 -ne 0

grep -q 'STOW REFUSED' $home5/run.log
@test "Pass 4 stow failure is reported loudly" $status -eq 0

grep -q 'blocker' $home5/run.log
@test "Pass 4 stow failure names the path stow complained about" $status -eq 0

grep -q 'wrangle repair' $home5/run.log
@test "Pass 4 stow failure points at wrangle repair" $status -eq 0

not grep -q 'real files at target paths' $home5/run.log
@test "Pass 4 no longer blames 'real files at target paths'" $status -eq 0

rm -rf $fix5 $home5 $stub5

# ─── Pass 3 finds dangling symlinks ──────────────────────────────────────
# The detection ran realpath on links it had already established were broken.
# BSD realpath exits 1 without output on those, so the prefix match always
# failed and the pass matched nothing — including the exact dangling links a
# half-finished track leaves behind.

set -l f6 (_track_fixture)
set -l fix6 $f6[1]; set -l home6 $f6[2]; set -l stub6 $f6[3]
_stow_stub $stub6 0

# A symlink into the repo's home/ whose target does not exist.
ln -s $fix6/home/.config/vanished $home6/.config/dangling

begin
    set -lx HOME $home6
    set -lx PATH $stub6 $PATH
    printf 's\n' | env WRANGLE_NO_BRANCH_SWITCH=1 $fix6/scripts/wrangle sync \
        >$home6/run.log 2>&1
end

grep -q 'Orphan symlinks' $home6/run.log
@test "orphan pass reports a dangling link into home/" $status -eq 0

grep -q 'dangling' $home6/run.log
@test "orphan pass names the dangling link" $status -eq 0

rm -rf $fix6 $home6 $stub6
