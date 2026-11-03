# `wrangle merge <branch>` behavior tests. Build a hermetic fixture repo
# with two branches whose tracked content diverges, then exercise the
# merge operation by piping answers into wrangle's interactive prompts.
#
# Hermeticity: same pattern as test/wrangle-behavior.fish — copy scripts/
# into a fresh `git init`ed fixture and run THAT copy with a fake HOME so
# both the repo and state files are isolated from the developer's tree.

set -l repo_root (dirname (realpath (status -f)))/..
source $repo_root/test/helpers/fixture.fish

# Build a fixture with two branches:
#   personal: minimal seed (empty Brewfile, empty fish_plugins, no dotfiles)
#   work:     personal + extra brew, extra fisher plugin, extra dotfile
# Echoes two paths on stdout: fixture repo, then fake home. Starts on
# `personal` (the default machine-branch).
function _wrangle_merge_fixture --inherit-variable repo_root
    set -l fix (mktemp -d)
    set -l home_dir (mktemp -d)

    _wrangle_fixture_init_repo $fix "merge-test" main
    _wrangle_fixture_install_scripts $fix $repo_root
    # Minimal seed on what becomes main: blank ignore files, so nothing the
    # branches diverge on gets silently filtered.
    _wrangle_fixture_seed_files $fix $repo_root empty

    git -C $fix add -A
    git -C $fix commit -q -m "seed"

    # `personal` branch: identical to main (no extra content yet).
    git -C $fix checkout -q -b personal
    git -C $fix commit -q --allow-empty -m "personal: init"

    # `work` branch: has extra brew + fisher plugin + dotfile that personal lacks.
    git -C $fix checkout -q -b work main
    echo 'brew "mergiraf"' >> $fix/Brewfile
    echo 'PatrickF1/fzf.fish' >> $fix/home/.config/fish/fish_plugins
    mkdir -p $fix/home/.config/zed
    echo '{"theme": "ayu-dark"}' > $fix/home/.config/zed/settings.json
    git -C $fix add -A
    git -C $fix commit -q -m "work: add mergiraf + fzf.fish + zed settings"

    # End on personal — the merge source will be work.
    git -C $fix checkout -q personal

    echo $fix
    echo $home_dir
end

# ─── unknown source branch exits non-zero ──────────────────────────────

set -l f1 (_wrangle_merge_fixture)
set -l fix1 $f1[1]; set -l home1 $f1[2]
env HOME=$home1 $fix1/scripts/wrangle merge nonexistent-branch 2>/dev/null
@test "merge with unknown source branch exits non-zero" $status -ne 0
rm -rf $fix1 $home1

# ─── merging from main is rejected (use update instead) ────────────────

set -l f2 (_wrangle_merge_fixture)
set -l fix2 $f2[1]; set -l home2 $f2[2]
set -l out2 (env HOME=$home2 $fix2/scripts/wrangle merge main 2>&1)
string match -q "*update*" -- "$out2"
@test "merge main hints at `wrangle update`" $status -eq 0
rm -rf $fix2 $home2

# ─── merging into self is rejected ─────────────────────────────────────

set -l f3 (_wrangle_merge_fixture)
set -l fix3 $f3[1]; set -l home3 $f3[2]
env HOME=$home3 $fix3/scripts/wrangle merge personal 2>/dev/null
@test "merge personal (self) exits non-zero" $status -ne 0
rm -rf $fix3 $home3

# ─── adopting all from work: piped 'a' answers (4 prompts: 1 dotfile, 1
#     brew, 1 fisher, 0 univ-var) → all adopted, Brewfile/fish_plugins/
#     home/.config/zed/settings.json land on personal, commit lands.

set -l f4 (_wrangle_merge_fixture)
set -l fix4 $f4[1]; set -l home4 $f4[2]

# Stub out external tools that wrangle would invoke as side-effects of adoption:
#   brew bundle (would actually install mergiraf)
#   fisher install (would actually fetch the plugin)
#   stow         (would symlink things into ~)
# Make stubs in a directory we prepend to PATH.
set -l stubdir (mktemp -d)
for cmd in brew stow
    echo '#!/bin/sh' > $stubdir/$cmd
    echo 'exit 0' >> $stubdir/$cmd
    chmod +x $stubdir/$cmd
end
# fish-level stub for `fisher` (it's a fish function in real life).
# We can't easily stub fish builtins; rely on `functions -q fisher` being
# false inside the test shell (no fisher loaded), which our merge code
# already guards against (`if functions -q fisher`).

# Three prompts, all adopting: 'a' for dotfile, 'a' for brew, 'a' for fisher.
# No univ-var drift (both branches have empty .univexport).
set -l merge_rv
begin
    set -lx HOME $home4
    set -lx PATH $stubdir $PATH
    printf 'a\na\na\n' | $fix4/scripts/wrangle merge work >$home4/merge.log 2>&1
    set merge_rv $status
end
@test "merge work (all adopted) exits 0" $merge_rv -eq 0

# Verify the changes landed on personal: Brewfile has mergiraf, fish_plugins
# has fzf.fish, zed/settings.json exists.
grep -q 'mergiraf' $fix4/Brewfile
@test "after merge: Brewfile contains mergiraf" $status -eq 0

grep -q 'fzf.fish' $fix4/home/.config/fish/fish_plugins
@test "after merge: fish_plugins contains fzf.fish" $status -eq 0

test -f $fix4/home/.config/zed/settings.json
@test "after merge: home/.config/zed/settings.json exists on personal" $status -eq 0

# Commit was made.
set -l last_msg (git -C $fix4 log -1 --pretty=%s personal)
string match -q "*merge from*work*" -- "$last_msg"
@test "after merge: commit subject mentions 'merge from ... work'" $status -eq 0

rm -rf $fix4 $home4 $stubdir

# ─── skipping everything: piped 's' answers → no adoptions, no commit ──

set -l f5 (_wrangle_merge_fixture)
set -l fix5 $f5[1]; set -l home5 $f5[2]
set -l before_head (git -C $fix5 rev-parse personal)
set -l skip_rv
begin
    set -lx HOME $home5
    printf 's\ns\ns\n' | $fix5/scripts/wrangle merge work >$home5/merge.log 2>&1
    set skip_rv $status
end
@test "merge work (all skipped) exits 0" $skip_rv -eq 0
set -l after_head (git -C $fix5 rev-parse personal)
test "$before_head" = "$after_head"
@test "after all-skip merge: no commit on personal" $status -eq 0

# Domain-exclusion: fish_plugins is owned by the fisher domain, so the
# dotfile-domain enumeration must NOT surface it (otherwise the user
# gets prompted twice for the same change).
not grep -q 'home/\.config/fish/fish_plugins' $home5/merge.log
@test "all-skip merge: dotfile section does NOT mention home/.config/fish/fish_plugins" $status -eq 0
# Sanity: the fisher plugin name (PatrickF1/fzf.fish) still appears,
# proving the fisher domain still surfaces the drift.
grep -q 'PatrickF1/fzf.fish' $home5/merge.log
@test "all-skip merge: fisher section still surfaces the new plugin" $status -eq 0

rm -rf $fix5 $home5

# ─── ignore-file honored: brewignore entry suppresses prompt for that brew

set -l f6 (_wrangle_merge_fixture)
set -l fix6 $f6[1]; set -l home6 $f6[2]
# Add mergiraf to personal's .brewignore (substring match), commit it.
echo 'mergiraf' >> $fix6/.brewignore
git -C $fix6 commit -q -am 'personal: brewignore mergiraf'
# Now merging work should auto-skip the mergiraf brew prompt with an info
# message. The fisher and dotfile prompts still fire — pipe 'a' for each.
set -l out6
begin
    set -lx HOME $home6
    set out6 (printf 'a\na\n' | $fix6/scripts/wrangle merge work 2>&1)
end
string match -q "*matches .brewignore*" -- "$out6"
@test "merge work: brewignore entry produces 'matches .brewignore' info" $status -eq 0
# Brewfile on personal should NOT have mergiraf.
not grep -q 'mergiraf' $fix6/Brewfile
@test "after merge: Brewfile does NOT contain mergiraf (ignored)" $status -eq 0
rm -rf $fix6 $home6

# ─── [f]orever round-trip: write .merge-skip, second run auto-skips, --force re-prompts

set -l f7 (_wrangle_merge_fixture)
set -l fix7 $f7[1]; set -l home7 $f7[2]

# Stubs for adopt side-effects (in case the user picks 'a' for non-mergiraf prompts).
set -l stubdir7 (mktemp -d)
for cmd in brew stow
    echo '#!/bin/sh' > $stubdir7/$cmd
    echo 'exit 0' >> $stubdir7/$cmd
    chmod +x $stubdir7/$cmd
end

# First run: 'f' for the dotfile (zed/settings.json), 'f' for mergiraf,
# 's' for the fisher plugin. The dotfile prompt comes first (Domain 1),
# then brew (Domain 2), then fisher (Domain 3).
begin
    set -lx HOME $home7
    set -lx PATH $stubdir7 $PATH
    printf 'f\nf\ns\n' | $fix7/scripts/wrangle merge work >$home7/merge1.log 2>&1
end

# .merge-skip should now have two entries: one dotfile, one brew.
test -f $fix7/.merge-skip
@test "[f]orever: .merge-skip file is created" $status -eq 0

grep -qE '^dotfile home/\.config/zed/settings\.json$' $fix7/.merge-skip
@test "[f]orever: dotfile entry written to .merge-skip" $status -eq 0

grep -qE '^brew brew "mergiraf"$' $fix7/.merge-skip
@test "[f]orever: brew entry written to .merge-skip" $status -eq 0

# fisher entry was skipped (not [f]orever'd), so should NOT be in .merge-skip.
not grep -qE '^fisher ' $fix7/.merge-skip
@test "[f]orever: skipped (not [f]orevered) item is NOT in .merge-skip" $status -eq 0

# Second run: same fixture state. The dotfile + brew should auto-skip
# (matches .merge-skip). Only the fisher prompt fires — pipe one 's'.
begin
    set -lx HOME $home7
    set -lx PATH $stubdir7 $PATH
    printf 's\n' | $fix7/scripts/wrangle merge work >$home7/merge2.log 2>&1
end

grep -q 'matches .merge-skip' $home7/merge2.log
@test "[f]orever second run: 'matches .merge-skip' info message appears" $status -eq 0

not grep -q '(new from source)' $home7/merge2.log
@test "[f]orever second run: dotfile prompt does NOT re-surface" $status -eq 0

grep -q 'PatrickF1/fzf.fish' $home7/merge2.log
@test "[f]orever second run: fisher (non-skipped) still surfaces" $status -eq 0

# Third run with --force: .merge-skip is bypassed. All three prompts re-fire.
# Pipe 's\ns\ns\n' (skip everything to keep state clean).
begin
    set -lx HOME $home7
    set -lx PATH $stubdir7 $PATH
    printf 's\ns\ns\n' | $fix7/scripts/wrangle merge work --force >$home7/merge3.log 2>&1
end

grep -q '(new from source)' $home7/merge3.log
@test "[f]orever + --force: dotfile prompt re-surfaces" $status -eq 0

grep -q 'mergiraf' $home7/merge3.log
@test "[f]orever + --force: brew prompt re-surfaces" $status -eq 0

not grep -q 'matches .merge-skip' $home7/merge3.log
@test "[f]orever + --force: no 'matches .merge-skip' info (bypassed)" $status -eq 0

rm -rf $fix7 $home7 $stubdir7

# ─── --dry-run: previews candidates, mutates nothing, makes no commit ───
#
# The whole point of dry-run is that it walks the SAME domains as a real
# merge (so the preview never lies) but changes nothing. No input is piped:
# dry-run must not read a single prompt. `</dev/null` guarantees that a
# regression which fell through to a prompt gets EOF and fails fast instead
# of hanging the suite.

set -l f8 (_wrangle_merge_fixture)
set -l fix8 $f8[1]; set -l home8 $f8[2]
set -l before_head8 (git -C $fix8 rev-parse personal)

set -l dry_rv
begin
    set -lx HOME $home8
    $fix8/scripts/wrangle merge work --dry-run </dev/null >$home8/dry.log 2>&1
    set dry_rv $status
end
@test "merge --dry-run exits 0" $dry_rv -eq 0

# No commit landed on personal.
set -l after_head8 (git -C $fix8 rev-parse personal)
test "$before_head8" = "$after_head8"
@test "merge --dry-run: no commit on personal" $status -eq 0

# No files were mutated: work's extras did NOT land on personal.
not grep -q 'mergiraf' $fix8/Brewfile
@test "merge --dry-run: Brewfile NOT modified" $status -eq 0
not grep -q 'fzf.fish' $fix8/home/.config/fish/fish_plugins
@test "merge --dry-run: fish_plugins NOT modified" $status -eq 0
not test -f $fix8/home/.config/zed/settings.json
@test "merge --dry-run: new dotfile NOT written" $status -eq 0
not test -f $fix8/.merge-skip
@test "merge --dry-run: .merge-skip NOT written" $status -eq 0

# The preview surfaced each candidate (dotfile, brew, fisher).
grep -q 'settings.json' $home8/dry.log
@test "merge --dry-run: previews the new dotfile" $status -eq 0
grep -q 'mergiraf' $home8/dry.log
@test "merge --dry-run: previews the new brew" $status -eq 0
grep -q 'PatrickF1/fzf.fish' $home8/dry.log
@test "merge --dry-run: previews the new fisher plugin" $status -eq 0

# The dry-run banner + summary appear, and the summary counts the candidates.
# The summary numbers are bold (via _n), so strip ANSI before matching the
# count line — the escape codes sit between each digit and its word.
cat $home8/dry.log | string replace -ra '\e(\[[0-9;]*m|\(B)' '' > $home8/dry.txt
grep -q 'dry run' $home8/dry.txt
@test "merge --dry-run: prints the dry-run banner" $status -eq 0
grep -qE '1 dotfile\(s\), 1 brew\(s\), 1 fisher plugin\(s\), 0 univ-var' $home8/dry.txt
@test "merge --dry-run: summary counts candidates per domain" $status -eq 0
grep -qE 'without .*--dry-run' $home8/dry.txt
@test "merge --dry-run: points at the real merge to adopt" $status -eq 0

rm -rf $fix8 $home8

# ─── --dry-run honors ignore files (preview matches the real walk) ─────

set -l f9 (_wrangle_merge_fixture)
set -l fix9 $f9[1]; set -l home9 $f9[2]
echo 'mergiraf' >> $fix9/.brewignore
git -C $fix9 commit -q -am 'personal: brewignore mergiraf'
begin
    set -lx HOME $home9
    $fix9/scripts/wrangle merge work --dry-run </dev/null >$home9/dry.log 2>&1
end
cat $home9/dry.log | string replace -ra '\e(\[[0-9;]*m|\(B)' '' > $home9/dry.txt
grep -q 'matches .brewignore' $home9/dry.txt
@test "merge --dry-run: honors .brewignore in the preview" $status -eq 0
grep -qE '0 brew\(s\)' $home9/dry.txt
@test "merge --dry-run: ignored brew is not counted as a candidate" $status -eq 0
rm -rf $fix9 $home9

# ─── --dry-run: each dotfile carries a +N −M line count ────────────────

set -l f10 (_wrangle_merge_fixture)
set -l fix10 $f10[1]; set -l home10 $f10[2]
begin
    set -lx HOME $home10
    $fix10/scripts/wrangle merge work --dry-run </dev/null >$home10/dry.log 2>&1
end
string replace -ra '\e(\[[0-9;]*m|\(B)' '' < $home10/dry.log > $home10/dry.txt
grep -qF 'home/.config/zed/settings.json (new from source, +1 −0)' $home10/dry.txt
@test "merge --dry-run: new dotfile listed with its +N −M count" $status -eq 0
rm -rf $fix10 $home10

# ─── [d]iff on a new dotfile, then [a]dopt ─────────────────────────────
# A new file is purely additive, but it still gets a diff: that's the
# point — an accidental file on the other machine should be visible here.

set -l f11 (_wrangle_merge_fixture)
set -l fix11 $f11[1]; set -l home11 $f11[2]
set -l stubdir11 (mktemp -d)
for cmd in brew stow
    printf '#!/bin/sh\nexit 0\n' > $stubdir11/$cmd
    chmod +x $stubdir11/$cmd
end
begin
    set -lx HOME $home11
    set -lx PATH $stubdir11 $PATH
    printf 'd\na\ns\ns\n' | $fix11/scripts/wrangle merge work >$home11/merge.log 2>&1
end
string replace -ra '\e(\[[0-9;]*m|\(B)' '' < $home11/merge.log > $home11/merge.txt
grep -qx '      +++ source/home/.config/zed/settings.json' $home11/merge.txt
@test "merge [d]iff (new file): labels the source side" $status -eq 0
grep -qx '      +{"theme": "ayu-dark"}' $home11/merge.txt
@test "merge [d]iff (new file): shows the content as added" $status -eq 0
# Adopt writes the source's exact bytes — the trailing newline included.
git -C $fix11 show work:home/.config/zed/settings.json | cmp -s - $fix11/home/.config/zed/settings.json
@test "merge [a]dopt: adopted file is byte-identical to the source" $status -eq 0
rm -rf $fix11 $home11 $stubdir11

# ─── [d]iff on a content conflict, then [k]eep ─────────────────────────

set -l f12 (_wrangle_merge_fixture)
set -l fix12 $f12[1]; set -l home12 $f12[2]
mkdir -p $fix12/home/.config/zed
echo '{"theme": "sonokai"}' > $fix12/home/.config/zed/settings.json
git -C $fix12 add -A
git -C $fix12 commit -q -m 'personal: zed settings'
begin
    set -lx HOME $home12
    printf 'd\nk\ns\ns\n' | $fix12/scripts/wrangle merge work >$home12/merge.log 2>&1
end
string replace -ra '\e(\[[0-9;]*m|\(B)' '' < $home12/merge.log > $home12/merge.txt
grep -qx '      -{"theme": "sonokai"}' $home12/merge.txt
and grep -qx '      +{"theme": "ayu-dark"}' $home12/merge.txt
@test "merge [d]iff (conflict): shows mine as removed, source as added" $status -eq 0
grep -q 'sonokai' $fix12/home/.config/zed/settings.json
@test "merge [d]iff then [k]eep: local file unchanged" $status -eq 0
rm -rf $fix12 $home12

# ─── [d]iff on a univ-var pattern: live vs what adopting would set ─────

set -l f13 (_wrangle_merge_fixture)
set -l fix13 $f13[1]; set -l home13 $f13[2]
git -C $fix13 checkout -q work
echo 'tide_*' >> $fix13/.univexport
printf '%s\n' 'set -U --erase tide_color' 'set -U tide_color new' \
    'set -U --erase tide_extra' 'set -U tide_extra added' \
    > $fix13/home/.config/fish/exported-univ-vars.fish
git -C $fix13 add -A
git -C $fix13 commit -q -m 'work: track tide_*'
git -C $fix13 checkout -q personal
begin
    set -lx HOME $home13
    # Universals live under XDG_CONFIG_HOME; pin it to the fake home so
    # neither the setup nor the merge touches real fish_variables.
    set -lx XDG_CONFIG_HOME $home13/.config
    # Not --no-config: fish doesn't persist universals under it.
    fish -c 'set -U tide_color old'
    printf 's\ns\ns\nd\ns\n' | $fix13/scripts/wrangle merge work >$home13/merge.log 2>&1
end
string replace -ra '\e(\[[0-9;]*m|\(B)' '' < $home13/merge.log > $home13/merge.txt
grep -qx '      -tide_color\[1\] = old' $home13/merge.txt
and grep -qx '      +tide_color\[1\] = new' $home13/merge.txt
@test "merge [d]iff (univ): changed var shows live → source" $status -eq 0
grep -qx '      +tide_extra\[1\] = added' $home13/merge.txt
@test "merge [d]iff (univ): var new to this machine shows as added" $status -eq 0
rm -rf $fix13 $home13

# ─── brew [a]dopt: don't install what's already there ──────────────────
# A brew stub that records its arguments. `bundle check` answers per the
# BUNDLE_CHECK env var; `info --cask` reports one app artifact.

function _merge_brew_stub --argument-names dir
    printf '%s\n' '#!/bin/sh' \
        "echo \"\$*\" >> $dir/brew-calls" \
        'case "$1 $2" in' \
        '  "bundle check") exit ${BUNDLE_CHECK:-1} ;;' \
        '  "info --cask") printf "==> Artifacts\nFooApp.app (App)\n" ;;' \
        'esac' \
        'exit 0' > $dir/brew
    chmod +x $dir/brew
    printf '#!/bin/sh\nexit 0\n' > $dir/stow
    chmod +x $dir/stow
end

# Already managed by brew: appended, not installed.
set -l f14 (_wrangle_merge_fixture)
set -l fix14 $f14[1]; set -l home14 $f14[2]
set -l stub14 (mktemp -d)
_merge_brew_stub $stub14
begin
    set -lx HOME $home14
    set -lx PATH $stub14 $PATH
    set -lx BUNDLE_CHECK 0
    printf 's\na\ns\n' | $fix14/scripts/wrangle merge work >$home14/merge.log 2>&1
end
grep -q 'mergiraf' $fix14/Brewfile
@test "brew adopt (already installed): line appended to Brewfile" $status -eq 0
not grep -q '^bundle install' $stub14/brew-calls
@test "brew adopt (already installed): brew bundle install NOT run" $status -eq 0
grep -q 'already installed' $home14/merge.log
@test "brew adopt (already installed): says so" $status -eq 0
rm -rf $fix14 $home14 $stub14

# A cask whose .app is already on disk, put there outside brew: appended,
# app left alone (no install, so brew can't adopt-and-quit it).
set -l f15 (_wrangle_merge_fixture)
set -l fix15 $f15[1]; set -l home15 $f15[2]
git -C $fix15 checkout -q work
echo 'cask "foo-app"' >> $fix15/Brewfile
git -C $fix15 commit -q -am 'work: foo-app cask'
git -C $fix15 checkout -q personal
mkdir -p $home15/Applications/FooApp.app
set -l stub15 (mktemp -d)
_merge_brew_stub $stub15
begin
    set -lx HOME $home15
    set -lx PATH $stub15 $PATH
    set -lx BUNDLE_CHECK 1
    # dotfile s, mergiraf s, foo-app a, fisher s
    printf 's\ns\na\ns\n' | $fix15/scripts/wrangle merge work >$home15/merge.log 2>&1
end
grep -q 'cask "foo-app"' $fix15/Brewfile
@test "brew adopt (app on disk): line appended to Brewfile" $status -eq 0
not grep -q '^bundle install' $stub15/brew-calls
@test "brew adopt (app on disk): brew bundle install NOT run" $status -eq 0
grep -q "Applications/FooApp.app" $home15/merge.log; and grep -q 'brew install --cask --adopt foo-app' $home15/merge.log
@test "brew adopt (app on disk): names the app and how to hand it to brew" $status -eq 0
rm -rf $fix15 $home15 $stub15

# Not present: installed as before.
set -l f16 (_wrangle_merge_fixture)
set -l fix16 $f16[1]; set -l home16 $f16[2]
set -l stub16 (mktemp -d)
_merge_brew_stub $stub16
begin
    set -lx HOME $home16
    set -lx PATH $stub16 $PATH
    set -lx BUNDLE_CHECK 1
    printf 's\na\ns\n' | $fix16/scripts/wrangle merge work >$home16/merge.log 2>&1
end
grep -q '^bundle install' $stub16/brew-calls
@test "brew adopt (not installed): brew bundle install runs" $status -eq 0
string replace -ra '\e(\[[0-9;]*m|\(B)' '' < $home16/merge.log | grep -qx '    brew "mergiraf"'
@test "brew prompt (not installed): names the line it's asking about" $status -eq 0
rm -rf $fix16 $home16 $stub16

# ─── univ-vars: value changes under a pattern both branches track ──────

set -l f17 (_wrangle_merge_fixture)
set -l fix17 $f17[1]; set -l home17 $f17[2]
echo 'tide_*' >> $fix17/.univexport
printf '%s\n' 'set -U --erase tide_color' 'set -U tide_color old' \
    > $fix17/home/.config/fish/exported-univ-vars.fish
git -C $fix17 add -A
git -C $fix17 commit -q -m 'personal: track tide_*'
git -C $fix17 checkout -q work
echo 'tide_*' >> $fix17/.univexport
printf '%s\n' 'set -U --erase tide_color' 'set -U tide_color new' \
    'set -U --erase tide_items' 'set -U tide_items git sbt' \
    > $fix17/home/.config/fish/exported-univ-vars.fish
git -C $fix17 add -A
git -C $fix17 commit -q -m 'work: retune tide'
git -C $fix17 checkout -q personal
set -l stub17 (mktemp -d)
printf '#!/bin/sh\nexit 0\n' > $stub17/brew; printf '#!/bin/sh\nexit 0\n' > $stub17/stow
chmod +x $stub17/brew $stub17/stow
begin
    set -lx HOME $home17
    set -lx XDG_CONFIG_HOME $home17/.config
    set -lx PATH $stub17 $PATH
    # Not --no-config: fish doesn't persist universals under it.
    fish -c 'set -U tide_color old'
    $fix17/scripts/wrangle merge work --dry-run </dev/null >$home17/dry.log 2>&1
    # dotfile s, brew s, fisher s, tide_* values: diff then adopt
    printf 's\ns\ns\nd\na\n' | $fix17/scripts/wrangle merge work >$home17/merge.log 2>&1
    set -g _t17_live (fish -c 'echo $tide_color; echo $tide_items')
end
string replace -ra '\e(\[[0-9;]*m|\(B)' '' < $home17/dry.log > $home17/dry.txt
grep -q 'tide_\* (2 var(s) differ from source' $home17/dry.txt
@test "univ values: dry-run lists the pattern with its changed vars" $status -eq 0
string replace -ra '\e(\[[0-9;]*m|\(B)' '' < $home17/merge.log > $home17/merge.txt
grep -qx '      -tide_color\[1\] = old' $home17/merge.txt; and grep -qx '      +tide_color\[1\] = new' $home17/merge.txt
@test "univ values: diff shows live → source" $status -eq 0
test "$_t17_live[1]" = new; and test "$_t17_live[2]" = 'git sbt'
@test "univ values: adopt sets the live universals" $status -eq 0
grep -qx 'set -U tide_color new' $fix17/home/.config/fish/exported-univ-vars.fish
and grep -qx 'set -U tide_items git sbt' $fix17/home/.config/fish/exported-univ-vars.fish
@test "univ values: adopt regenerates the export file" $status -eq 0
string match -q '*univ-var*' (git -C $fix17 log -1 --pretty=%s personal)
@test "univ values: adoption is committed" $status -eq 0
rm -rf $fix17 $home17 $stub17
