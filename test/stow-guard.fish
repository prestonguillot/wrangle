# scripts/_stow_guard.fish unit tests — hazard detection, lexical path
# resolution, orphan-symlink detection, and stow failure classification.
#
# These are the checks that stand between a user and a broken home directory,
# so they are tested directly rather than only through a sync run. The tree
# built below mirrors the shape that actually broke: a real directory holding
# an absolute symlink several levels down.

set -l repo_root (dirname (realpath (status -f)))/..

# The guard uses the palette from scripts/wrangle, which isn't sourced here.
# Stub the two pieces it reaches for so output is plain and comparable.
set -g GLYPH_ARROW "->"
function _name; printf '%s' "$argv[1]"; end

source $repo_root/scripts/_stow_guard.fish

# ─── _wrangle_lexical_normalize ──────────────────────────────────────────
# realpath can't be used on paths that don't resolve, so this does the work.

test (_wrangle_lexical_normalize /a/b/../c) = /a/c
@test "normalize collapses .." $status -eq 0

test (_wrangle_lexical_normalize /a/./b) = /a/b
@test "normalize drops ." $status -eq 0

test (_wrangle_lexical_normalize //a///b) = /a/b
@test "normalize collapses repeated slashes" $status -eq 0

test (_wrangle_lexical_normalize /a/b/../../../..) = /
@test "normalize clamps .. at /" $status -eq 0

# ─── _wrangle_stow_hazards ───────────────────────────────────────────────

set -l t (mktemp -d)

# A clean tree: real dir, real file, and a relative symlink that stays inside.
mkdir -p $t/clean/sub
echo hi > $t/clean/sub/file
ln -s sub/file $t/clean/inside-link

test (_wrangle_stow_hazards $t/clean | count) -eq 0
@test "clean tree reports no hazards" $status -eq 0

# The failing case: an absolute symlink nested inside a real directory. This
# is what the enumeration's `test -L` on the candidate itself could not see.
mkdir -p $t/abs/nested
ln -s /var/tmp $t/abs/nested/AppSupport

set -l h (_wrangle_stow_hazards $t/abs)
test (count $h) -eq 1
@test "absolute symlink nested in a directory is found" $status -eq 0

set -l parts (string split \t -- $h[1])
test "$parts[1]" = abs-symlink
@test "nested absolute symlink is classified abs-symlink" $status -eq 0

test "$parts[2]" = "$t/abs/nested/AppSupport"
@test "hazard names the offending path, not the tracked root" $status -eq 0

test "$parts[3]" = /var/tmp
@test "hazard records the symlink target" $status -eq 0

# A relative symlink that escapes the tracked root.
mkdir -p $t/esc/sub
ln -s ../../outside $t/esc/sub/escaper
set -l h2 (_wrangle_stow_hazards $t/esc)
test (string split \t -- $h2[1])[1] = escaping-symlink
@test "relative symlink escaping the root is classified escaping-symlink" $status -eq 0

# A relative symlink that goes up but stays inside is NOT a hazard.
mkdir -p $t/stay/a/b
echo x > $t/stay/target
ln -s ../../target $t/stay/a/b/ok-link
test (_wrangle_stow_hazards $t/stay | count) -eq 0
@test "relative symlink staying inside the root is not a hazard" $status -eq 0

# Special files: git cannot store them.
mkdir -p $t/spec
mkfifo $t/spec/pipe
set -l h3 (_wrangle_stow_hazards $t/spec)
set -l sp (string split \t -- $h3[1])
test "$sp[1]" = special
@test "fifo is classified special" $status -eq 0
string match -q '*pipe*' -- "$sp[3]"
@test "special hazard names the kind of file" $status -eq 0

# The root itself being an absolute symlink is a hazard too.
ln -s /var/tmp $t/root-link
test (string split \t -- (_wrangle_stow_hazards $t/root-link)[1])[1] = abs-symlink
@test "root that is itself an absolute symlink is a hazard" $status -eq 0

# A path that doesn't exist yields nothing rather than erroring.
test (_wrangle_stow_hazards $t/does-not-exist | count) -eq 0
@test "missing path reports no hazards" $status -eq 0

rm -rf $t

# ─── _wrangle_orphan_symlinks ────────────────────────────────────────────
# The regression that mattered: the previous implementation ran realpath on
# links it had already established were broken. BSD realpath exits 1 with no
# output on those, so the pass never matched anything.

set -l oh (mktemp -d)
set -l orepo (mktemp -d)
mkdir -p $orepo/home/.config $oh/.config

# Broken link into the repo's home/ — must be found.
ln -s $orepo/home/.config/gone $oh/.config/orphan

# Broken link pointing somewhere else entirely — must NOT be found.
ln -s /nonexistent/elsewhere $oh/.config/unrelated

# Working link into home/ — must NOT be found.
echo live > $orepo/home/.config/present
ln -s $orepo/home/.config/present $oh/.config/live

set -l orphans
begin
    set -lx HOME $oh
    set orphans (_wrangle_orphan_symlinks $orepo/home)
end

test (count $orphans) -eq 1
@test "orphan scan finds exactly the broken link into home/" $status -eq 0

test "$orphans[1]" = "$oh/.config/orphan"
@test "orphan scan names the dangling link" $status -eq 0

rm -rf $oh $orepo

# ─── _wrangle_stow_explain_failure ───────────────────────────────────────
# Verbatim stow 2.4.1 output from the report that prompted this work.

set -l stow_err \
    "WARNING! stowing home would cause conflicts:" \
    "  * source is an absolute symlink home/.config/iterm2/AppSupport => /Users/x/Library/Application Support/iTerm2" \
    "All operations aborted."

set -l explained (_wrangle_stow_explain_failure "" $stow_err | string join \n)

string match -q '*AppSupport*' -- "$explained"
@test "stow failure explanation names the offending path" $status -eq 0

string match -q '*absolute path*' -- "$explained"
@test "stow failure explanation states the cause in plain language" $status -eq 0

string match -q '*/Users/x/Library/Application Support/iTerm2*' -- "$explained"
@test "stow failure explanation shows the symlink target" $status -eq 0

not string match -q '*All operations aborted*' -- "$explained"
@test "stow failure explanation drops stow's non-conflict noise" $status -eq 0

# A conflict shape we don't have a translation for still reaches the user.
set -l unknown "  * some brand new conflict stow invented"
set -l passthru (_wrangle_stow_explain_failure "" $unknown | string join \n)
string match -q '*brand new conflict*' -- "$passthru"
@test "unrecognized conflict text is passed through, not swallowed" $status -eq 0

# Output with no conflict lines at all (a real error, not a planning conflict)
# must still surface.
set -l raw (_wrangle_stow_explain_failure "" "stow: cannot read directory" | string join \n)
string match -q '*cannot read directory*' -- "$raw"
@test "non-conflict stow error text is not lost" $status -eq 0

# ─── Orphan detection survives symlinked ancestry ────────────────────────
# The two sides of the comparison come from different roots: the link is
# resolved against $HOME, home/ comes from `git rev-parse --show-toplevel`.
# Either can sit under a symlinked ancestor — /var -> /private/var on macOS,
# or a symlinked home or checkout — and a purely lexical compare then never
# matches. Here the link is written through the unresolved path and the repo
# root is given in resolved form, which is exactly that mismatch.

set -l sh2 (mktemp -d)
set -l sbase (mktemp -d)

# Build the symlinked ancestor explicitly rather than relying on the platform.
# macOS mktemp returns /var/... (itself a symlink to /private/var), so this
# shape occurred for free there — but Linux mktemp returns a real /tmp path,
# and the mismatch this test exists to cover never arose.
mkdir -p $sbase/real/home/.config
ln -s $sbase/real $sbase/link
set -l srepo $sbase/link
mkdir -p $sh2/.config

# The link is written through the symlinked path...
ln -s $srepo/home/.config/gone $sh2/.config/orphan
# ...and the repo root is given in resolved form. That is the mismatch.
set -l srepo_real (realpath $srepo)

test "$srepo_real" != "$srepo"
@test "fixture actually exercises a symlinked ancestor" $status -eq 0

set -l found
begin
    set -lx HOME $sh2
    set found (_wrangle_orphan_symlinks $srepo_real/home)
end

test (count $found) -eq 1
@test "orphan scan matches across a symlinked ancestor" $status -eq 0

rm -rf $sh2 $sbase
