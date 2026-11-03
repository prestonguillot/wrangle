# Tests for three-way dotfile merging in `wrangle merge`: the remembered
# base in .merge-base (scripts/_merge_base.fish) and the [m]erge option,
# which hands base / mine / source to the user's git mergetool.
#
# The mergetool is a stub configured in the fake HOME's ~/.gitconfig, the
# same way a user configures kdiff3: it runs `git merge-file`, so a base
# that's right merges non-overlapping edits cleanly and a missing one
# doesn't. STUB_FAIL makes it exit non-zero (an abandoned merge).

set -l repo_root (dirname (realpath (status -f)))/..
source $repo_root/scripts/_merge_base.fish
source $repo_root/test/helpers/fixture.fish

function _mb_strip
    string replace -ra '\e(\[[0-9;]*m|\(B)' '' < $argv[1]
end

# A fake HOME whose git config names the stub as merge.tool.
function _mb_home
    set -l h (mktemp -d)
    printf '%s\n' '#!/bin/sh' \
        '[ -n "$STUB_FAIL" ] && exit 1' \
        'git merge-file -p "$2" "$1" "$3" > "$4"' > $h/stub-tool
    chmod +x $h/stub-tool
    git config -f $h/.gitconfig merge.tool stub
    git config -f $h/.gitconfig mergetool.stub.cmd "$h/stub-tool \"\$BASE\" \"\$LOCAL\" \"\$REMOTE\" \"\$MERGED\""
    git config -f $h/.gitconfig mergetool.stub.trustExitCode true
    echo $h
end

# ─── .merge-base get / set ──────────────────────────────────────────────

set -l d (mktemp -d)
set -l mbf $d/.merge-base
@test "base get: no file → nothing" (count (_wrangle_merge_base_get $mbf work home/x)) -eq 0

_wrangle_merge_base_set $mbf work home/x aaa
@test "base set: new entry returns 0" $status -eq 0
test (_wrangle_merge_base_get $mbf work home/x) = aaa
@test "base get: reads it back" $status -eq 0

_wrangle_merge_base_set $mbf work home/x aaa
@test "base set: same value returns 1 (unchanged)" $status -eq 1

_wrangle_merge_base_set $mbf work home/x bbb
_wrangle_merge_base_set $mbf laptop home/x ccc
test (_wrangle_merge_base_get $mbf work home/x) = bbb; and test (_wrangle_merge_base_get $mbf laptop home/x) = ccc
@test "base set: replaces per source, keeps other sources apart" $status -eq 0
test (grep -c '^work home/x ' $mbf) -eq 1
@test "base set: one line per source and path" $status -eq 0
rm -rf $d

# ─── _wrangle_mergetool: runs the configured tool through git ───────────

set -l h (_mb_home)
set -l d (mktemp -d)
printf 'a\nb\nc\n' > $d/base
printf 'A\nb\nc\n' > $d/mine
printf 'a\nb\nC\n' > $d/theirs
begin
    set -lx HOME $h
    _wrangle_mergetool $d/base $d/mine $d/theirs home/.config/app/conf $d/out >/dev/null 2>&1
end
@test "mergetool: success returns 0" $status -eq 0
test "$(cat $d/out | string collect)" = (printf 'A\nb\nC' | string collect)
@test "mergetool: tool got the base — non-overlapping edits merge" $status -eq 0

rm -f $d/out
begin
    set -lx HOME $h
    set -lx STUB_FAIL 1
    _wrangle_mergetool $d/base $d/mine $d/theirs home/.config/app/conf $d/out >/dev/null 2>&1
end
@test "mergetool: tool failure returns 1" $status -eq 1
not test -e $d/out
@test "mergetool: tool failure writes nothing" $status -eq 0
rm -rf $d $h

# ─── wrangle merge: bases recorded, [m]erge, keep, skip-when-unchanged ──

set -l fix (mktemp -d)
set -l home_dir (_mb_home)
set -l stub (mktemp -d)
printf '#!/bin/sh\nexit 0\n' > $stub/brew
printf '#!/bin/sh\nexit 0\n' > $stub/stow
chmod +x $stub/brew $stub/stow

_wrangle_fixture_init_repo $fix "merge-base-test" main
_wrangle_fixture_install_scripts $fix $repo_root
_wrangle_fixture_seed_files $fix $repo_root empty
mkdir -p $fix/home/.config/app
printf 'a\nb\nc\n' > $fix/home/.config/app/conf
git -C $fix add -A
git -C $fix commit -q -m seed
git -C $fix checkout -q -b personal
git -C $fix branch work

function _mb_merge --inherit-variable fix --inherit-variable home_dir --inherit-variable stub
    set -l input $argv[1]
    set -l args $argv[2..-1]
    begin
        set -lx HOME $home_dir
        set -lx PATH $stub $PATH
        printf $input | $fix/scripts/wrangle merge work $args >$home_dir/run.log 2>&1
    end
    _mb_strip $home_dir/run.log > $home_dir/run.txt
end

# Identical file: no prompt, base recorded and committed.
_mb_merge ''
set -l work_sha (git -C $fix rev-parse work:home/.config/app/conf)
test (_wrangle_merge_base_get $fix/.merge-base work home/.config/app/conf) = $work_sha
@test "merge: identical file records its base" $status -eq 0
git -C $fix log -1 --pretty=%s personal | string match -q '*recorded merge bases*'
@test "merge: base-only change is committed" $status -eq 0

# Both sides edit different lines → [m]erge → tool merges cleanly.
printf 'A\nb\nc\n' > $fix/home/.config/app/conf
git -C $fix commit -q -am 'personal: edit line 1'
git -C $fix checkout -q work
printf 'a\nb\nC\n' > $fix/home/.config/app/conf
git -C $fix commit -q -am 'work: edit line 3'
git -C $fix checkout -q personal

_mb_merge '' --dry-run
grep -q 'home/.config/app/conf (differs from source — changed on both sides since the last merge' $home_dir/run.txt
@test "merge --dry-run: says both sides changed since the last merge" $status -eq 0

_mb_merge 'm\ny\n'
test "$(cat $fix/home/.config/app/conf | string collect)" = (printf 'A\nb\nC' | string collect)
@test "merge [m]erge: result keeps my edit and takes the source's" $status -eq 0
grep -qx '        +C' $home_dir/run.txt
@test "merge [m]erge: shows what the merge changes before writing" $status -eq 0
set work_sha (git -C $fix rev-parse work:home/.config/app/conf)
test (_wrangle_merge_base_get $fix/.merge-base work home/.config/app/conf) = $work_sha
@test "merge [m]erge: base moves to the source's version" $status -eq 0
git -C $fix log -1 --pretty=%s personal | string match -q '*1 merged*'
@test "merge [m]erge: commit message counts it as merged" $status -eq 0

# Source unchanged since: no prompt, even though the files still differ.
_mb_merge ''
grep -q 'skipping home/.config/app/conf (unchanged on source since the last merge)' $home_dir/run.txt
@test "merge: unchanged on source since the last merge → skipped" $status -eq 0

# --force ignores the base and offers it again.
_mb_merge 's\n' --force
grep -q 'home/.config/app/conf (differs from source — first merge of this file)' $home_dir/run.txt
@test "merge --force: ignores recorded bases" $status -eq 0

# [k]eep records the base: the declined change isn't offered again.
git -C $fix checkout -q work
printf 'a\nB\nC\n' > $fix/home/.config/app/conf
git -C $fix commit -q -am 'work: edit line 2'
git -C $fix checkout -q personal
_mb_merge 'k\n'
test "$(cat $fix/home/.config/app/conf | string collect)" = (printf 'A\nb\nC' | string collect)
@test "merge [k]eep: file unchanged" $status -eq 0
_mb_merge ''
grep -q 'unchanged on source since the last merge' $home_dir/run.txt
@test "merge [k]eep: same source change not offered again" $status -eq 0

# Abandoned merge (tool fails): nothing written, re-prompts, base unchanged.
git -C $fix checkout -q work
printf 'a\nB\nC\nd\n' > $fix/home/.config/app/conf
git -C $fix commit -q -am 'work: add line 4'
git -C $fix checkout -q personal
set -l before (cat $fix/home/.config/app/conf | string collect)
set -l base_before (_wrangle_merge_base_get $fix/.merge-base work home/.config/app/conf)
begin
    set -lx STUB_FAIL 1
    _mb_merge 'm\ns\n'
end
test "$(cat $fix/home/.config/app/conf | string collect)" = "$before"
@test "merge [m]erge abandoned: file unchanged" $status -eq 0
grep -q 'merge not finished' $home_dir/run.txt
@test "merge [m]erge abandoned: says so" $status -eq 0
test (_wrangle_merge_base_get $fix/.merge-base work home/.config/app/conf) = $base_before
@test "merge [m]erge abandoned: base not moved" $status -eq 0

# [n]o at the confirmation: nothing written.
_mb_merge 'm\nn\ns\n'
test "$(cat $fix/home/.config/app/conf | string collect)" = "$before"
@test "merge [m]erge then [n]o: file unchanged" $status -eq 0

rm -rf $fix $home_dir $stub
