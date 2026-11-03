# Tests for _wrangle_drift_nested_scan (scripts/_drift.fish): untracked
# files inside directories home/ already tracks — e.g. a hand-written
# ~/.config/fish/functions/foo.fish once ~/.config/fish is tracked. Before
# this, the dotfile pass only looked at top-level ~/.<name> and
# ~/.config/<name>, so such files were never offered and never synced.
#
# The scan reads fisher's _fisher_*_files universals, so it runs in a fish
# subprocess with HOME and XDG_CONFIG_HOME pointed at a fake home: the
# universals it sets live in the fake home's fish_variables, never the
# developer's.

set -l repo_root (dirname (realpath (status -f)))/..
source $repo_root/test/helpers/fixture.fish

set -l h (mktemp -d)
set -l r (mktemp -d)

# home/ tracks .config/fish (config.fish) and .vim (vimrc).
mkdir -p $r/home/.config/fish $r/home/.vim $r/home/.config/folded
echo '# tracked' > $r/home/.config/fish/config.fish
echo 'tracked' > $r/home/.vim/vimrc

# ~ side.
mkdir -p $h/.config/fish/functions $h/.config/fish/completions $h/.config/fish/themes \
    $h/.config/fish/plugdir $h/.vim/after/ftplugin
ln -s $r/home/.config/fish/config.fish $h/.config/fish/config.fish      # stow link
echo 'mine' > $h/.config/fish/functions/mine.fish                         # offer
echo 'fisher' > $h/.config/fish/functions/plug.fish                       # fisher's
echo 'fisher' > $h/.config/fish/completions/plug.fish                     # fisher's, whole dir
echo 'own' > $h/.config/fish/plugdir/own.fish                             # mixed dir: offer file
echo 'fisher' > $h/.config/fish/plugdir/plug2.fish                        # mixed dir: fisher's
echo 'x' > $h/.vim/after/ftplugin/x.vim                                   # new dir: offer whole
ln -s $r/home/.vim/vimrc $h/.vim/vimrc                                    # stow link
ln -s /nonexistent $h/.config/fish/functions/dangling.fish                # symlink: never
# A ~ dir stow folded into a symlink: new files there already land in home/.
ln -s $r/home/.config/folded $h/.config/folded
echo 'n' > $r/home/.config/folded/new

# Not --no-config: under it fish has no universal scope at all, so the
# fisher list below would be invisible. The fake home has no config to load.
set -l out (env HOME=$h XDG_CONFIG_HOME=$h/.config fish -c "
    source $repo_root/scripts/_drift.fish
    set -U _fisher_test_2F_plug_files '~/.config/fish/functions/plug.fish' \
        '~/.config/fish/completions/plug.fish' '~/.config/fish/plugdir/plug2.fish'
    _wrangle_drift_nested_scan $r/home
" | string replace -- $h/ '')

contains -- .config/fish/functions/mine.fish $out
@test "nested: untracked file in a tracked dir's subdir is offered" $status -eq 0
not contains -- .config/fish/functions/plug.fish $out
@test "nested: fisher-installed file is not offered" $status -eq 0
not contains -- .config/fish/completions $out
@test "nested: dir of only fisher files is not offered" $status -eq 0
contains -- .config/fish/plugdir/own.fish $out; and not contains -- .config/fish/plugdir $out
@test "nested: dir with fisher files offers its other files one by one" $status -eq 0
not contains -- .config/fish/plugdir/plug2.fish $out
@test "nested: fisher file in a mixed dir is not offered" $status -eq 0
contains -- .vim/after $out
@test "nested: new dir with no fisher files is offered whole" $status -eq 0
not contains -- .config/fish/themes $out
@test "nested: empty dir is not offered" $status -eq 0
not contains -- .config/fish/fish_variables $out
@test "nested: fish_variables is never offered" $status -eq 0
not string match -q '*dangling*' -- $out; and not string match -q '*config.fish' -- $out
@test "nested: symlinks (stow's or the user's) are not offered" $status -eq 0
not string match -q '*folded*' -- $out
@test "nested: dirs stow folded into a symlink are skipped" $status -eq 0
not contains -- .vim/vimrc $out
@test "nested: tracked files are not offered" $status -eq 0

rm -rf $h $r

# ─── sync end to end: [t]rack a new function, it lands in home/ + links back

set -l fix (mktemp -d)
set -l home_dir (mktemp -d)
set -l stubdir (mktemp -d)
_wrangle_fixture_init_repo $fix "nested-drift-test" main
_wrangle_fixture_install_scripts $fix $repo_root
_wrangle_fixture_seed_files $fix $repo_root real
git -C $fix add -A
git -C $fix commit -q -m "fixture seed"
git -C $fix checkout -q -b personal
mkdir -p $home_dir/.cache/dotfiles $home_dir/.config/fish/functions
touch $home_dir/.cache/dotfiles/last-wrangle
echo "claude_doc_review no" > $home_dir/.cache/dotfiles/wrangle-config
printf '#!/bin/sh\nexit 0\n' > $stubdir/brew
chmod +x $stubdir/brew

# Link what's tracked, as on a real machine, so only the new file is drift.
stow -d $fix -t $home_dir home 2>/dev/null
echo 'function hello; echo hi; end' > $home_dir/.config/fish/functions/hello.fish

begin
    set -lx HOME $home_dir
    set -lx XDG_CONFIG_HOME $home_dir/.config
    set -lx PATH $stubdir $PATH
    printf 't\n' | env WRANGLE_NO_BRANCH_SWITCH=1 WRANGLE_NO_PUSH=1 \
        $fix/scripts/wrangle sync >$home_dir/run.log 2>&1
end

test -f $fix/home/.config/fish/functions/hello.fish
@test "sync [t]rack nested: file moved into home/" $status -eq 0
test -L $home_dir/.config/fish/functions/hello.fish; and test -f $home_dir/.config/fish/functions/hello.fish
@test "sync [t]rack nested: symlinked back into ~ and resolves" $status -eq 0
git -C $fix ls-files --error-unmatch home/.config/fish/functions/hello.fish >/dev/null 2>&1
@test "sync [t]rack nested: committed" $status -eq 0

rm -rf $fix $home_dir $stubdir
