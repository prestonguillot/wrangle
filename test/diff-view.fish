# Tests for scripts/_diff_view.fish — the [d]iff renderer and toggle shared
# by the merge and sync prompts — plus one end-to-end check that sync's
# dotfile prompt offers it.
#
# The toggle's expand/collapse cursor movement only runs on a terminal;
# under fishtape stdout is captured, so these pin the non-terminal path
# (print every time) and the renderer itself, which is where the content
# the user decides on comes from.

set -l repo_root (dirname (realpath (status -f)))/..
source $repo_root/scripts/_univ_parse.fish
source $repo_root/scripts/_diff_view.fish
source $repo_root/test/helpers/fixture.fish

set -l d (mktemp -d)
printf 'a\n' > $d/old
printf 'a\nb\n' > $d/new
mkdir -p $d/dir/sub
printf 'x\n' > $d/dir/sub/f

# ─── modified file: labels replace the real paths ───────────────────────

set -l out (_wrangle_diff_render $d/old $d/new home/.config/x mine source)
contains -- '+++ source/home/.config/x' $out
@test "render: new side labeled <new_label>/<display>" $status -eq 0
contains -- '--- mine/home/.config/x' $out
@test "render: old side labeled <old_label>/<display>" $status -eq 0
contains -- '+b' $out
@test "render: added line shown" $status -eq 0
string match -q "*$d*" -- $out
@test "render: real temp paths never appear in the output" $status -ne 0

# ─── purely additive: missing old side → everything added ───────────────

set -l out (_wrangle_diff_render "" $d/new home/.config/x mine source)
contains -- '--- /dev/null' $out
@test "render: empty old side diffs against /dev/null" $status -eq 0
test (string match -r '^\+[^+]' -- $out | count) -eq 2
@test "render: every line of a new file shows as added" $status -eq 0

# ─── purely destructive: missing new side → everything removed ──────────

set -l out (_wrangle_diff_render $d/new "" home/.config/x mine source)
test (string match -r '^-[^-]' -- $out | count) -eq 2
@test "render: every line shows as removed when the new side is missing" $status -eq 0

# ─── a directory with nothing on the other side ─────────────────────────

set -l out (_wrangle_diff_render "" $d/dir .config/dir repo/home "~")
contains -- '+++ ~/.config/dir/sub/f' $out
@test "render: directory contents diff per file under the display path" $status -eq 0
contains -- '+x' $out
@test "render: directory file contents shown as added" $status -eq 0

# ─── identical → no output, success ─────────────────────────────────────

set -l out (_wrangle_diff_render $d/old $d/old x a b)
set -l rv $status
@test "render: identical inputs print nothing" (count $out) -eq 0
@test "render: identical inputs return 0" $rv -eq 0

# ─── univ-var formatting ────────────────────────────────────────────────

printf '%s\n' 'set -U --erase tide_a' "set -U tide_a x 'y z'" > $d/univ
set -l out (_wrangle_univ_format $d/univ tide_a tide_missing)
test "$out[1]" = 'tide_a[1] = x'; and test "$out[2]" = "tide_a[2] = 'y z'"
@test "univ format (file): one escaped line per list element" $status -eq 0
@test "univ format (file): vars absent from the file print nothing" (count $out) -eq 2

# A global, not a universal: `-` reads whatever $name resolves to, and the
# test must not write to the developer's real fish_variables.
set -g __wrangle_test_live one two
set -l out (_wrangle_univ_format - __wrangle_test_live __wrangle_test_unset)
test "$out[2]" = '__wrangle_test_live[2] = two'
@test "univ format (live): reads values from the shell" $status -eq 0
@test "univ format (live): unset vars print nothing" (count $out) -eq 2
set -e __wrangle_test_live

# ─── toggle, not on a terminal: prints the diff every press ─────────────

_wrangle_diff_reset
set -l out (_wrangle_diff_toggle "  " "> " d _wrangle_diff_render "" $d/new f a b)
contains -- '  +b' $out
@test "toggle (no tty): prints the indented diff" $status -eq 0

set -l out (_wrangle_diff_toggle "  " "> " d _wrangle_diff_render $d/old $d/old f a b)
contains -- '  (no differences)' $out
@test "toggle (no tty): says so when there is nothing to show" $status -eq 0

rm -rf $d

# ─── sync: [d]iff on an untracked dotfile shows its full contents ───────

set -l fix (mktemp -d)
set -l home_dir (mktemp -d)
set -l stubdir (mktemp -d)
_wrangle_fixture_init_repo $fix "diff-view-test" main
_wrangle_fixture_install_scripts $fix $repo_root
_wrangle_fixture_seed_files $fix $repo_root real
git -C $fix add -A
git -C $fix commit -q -m "fixture seed"
git -C $fix checkout -q -b personal
mkdir -p $home_dir/.cache/dotfiles $home_dir/.config/newapp
touch $home_dir/.cache/dotfiles/last-wrangle
echo "claude_doc_review no" > $home_dir/.cache/dotfiles/wrangle-config
printf 'line one\nline two\n' > $home_dir/.config/newapp/conf
for cmd in brew stow
    printf '#!/bin/sh\nexit 0\n' > $stubdir/$cmd
    chmod +x $stubdir/$cmd
end

begin
    set -lx HOME $home_dir
    set -lx XDG_CONFIG_HOME $home_dir/.config
    set -lx PATH $stubdir $PATH
    printf 'd\ns\n' | env WRANGLE_NO_BRANCH_SWITCH=1 WRANGLE_NO_COMMIT=1 WRANGLE_NO_PUSH=1 \
        $fix/scripts/wrangle sync >$home_dir/run.log 2>&1
end
string replace -ra '\e\[[0-9;]*m' '' < $home_dir/run.log > $home_dir/run.txt

grep -qx '      +++ ~/.config/newapp/conf' $home_dir/run.txt
@test "sync [d]iff: labels the file by its ~ path" $status -eq 0
grep -qx '      +line two' $home_dir/run.txt
@test "sync [d]iff: shows the whole file as added (past the preview)" $status -eq 0
test -f $home_dir/.config/newapp/conf; and not test -e $fix/home/.config/newapp
@test "sync [d]iff then [s]kip: nothing moved" $status -eq 0

rm -rf $fix $home_dir $stubdir
