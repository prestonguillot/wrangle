# dump-brewfile filter behavior tests. Run via `scripts/run-tests` (fishtape).
#
# Uses --input + --ignore-file so we test the filter logic against fixtures
# rather than the user's actual brew install state.

set -l dump (dirname (realpath (status -f)))/../scripts/dump-brewfile

# Fixture brewfile content used across multiple tests.
set -l fixture_input (mktemp)
string join \n -- \
    '# Modern CLI replacement for cat' \
    'brew "bat"' \
    '# Static site generator' \
    'brew "hugo"' \
    '# Apple App Store CLI' \
    'brew "mas"' \
    '# Terminal emulator' \
    'cask "ghostty"' \
    'mas "Fantastical", id: 975937182' \
    > $fixture_input

# ─── Empty / missing ignore file ──────────────────────────────────────────

set -l ignore_empty (mktemp); echo "" > $ignore_empty
set -l target (mktemp)
$dump --input $fixture_input --ignore-file $ignore_empty $target
cmp -s $fixture_input $target
@test "empty .brewignore → output matches input byte-for-byte" $status -eq 0

set -l ignore_missing /tmp/definitely-does-not-exist-(random)
set target (mktemp)
$dump --input $fixture_input --ignore-file $ignore_missing $target
cmp -s $fixture_input $target
@test "missing .brewignore → output matches input" $status -eq 0

set -l ignore_comments (mktemp); printf '# just comments\n# nothing else\n' > $ignore_comments
set target (mktemp)
$dump --input $fixture_input --ignore-file $ignore_comments $target
cmp -s $fixture_input $target
@test "ignore file containing only comments behaves as empty" $status -eq 0

# ─── Single-pattern filter ────────────────────────────────────────────────

set -l ignore_hugo (mktemp); echo 'hugo' > $ignore_hugo
set target (mktemp)
$dump --input $fixture_input --ignore-file $ignore_hugo $target

grep -q 'brew "hugo"' $target
@test "ignoring 'hugo' strips the brew line" $status -ne 0

grep -q 'Static site generator' $target
@test "ignoring 'hugo' strips the preceding description comment" $status -ne 0

grep -q 'brew "bat"' $target
@test "ignoring 'hugo' leaves 'brew \"bat\"' intact" $status -eq 0

# ─── mas-pattern filter ───────────────────────────────────────────────────

set -l ignore_fantastical (mktemp); echo '"Fantastical"' > $ignore_fantastical
set target (mktemp)
$dump --input $fixture_input --ignore-file $ignore_fantastical $target
grep -q 'Fantastical' $target
@test "ignoring '\"Fantastical\"' strips the mas line" $status -ne 0

# ─── Substring scoping ────────────────────────────────────────────────────

set -l ignore_mas (mktemp); echo 'mas' > $ignore_mas
set target (mktemp)
$dump --input $fixture_input --ignore-file $ignore_mas $target

grep -q 'brew "mas"' $target
@test "ignoring 'mas' strips brew \"mas\"" $status -ne 0

grep -q 'brew "bat"' $target
@test "ignoring 'mas' (substring) leaves brew \"bat\" intact" $status -eq 0

# ─── Multi-pattern ────────────────────────────────────────────────────────

set -l ignore_multi (mktemp); printf 'hugo\nFantastical\n' > $ignore_multi
set target (mktemp)
$dump --input $fixture_input --ignore-file $ignore_multi $target

grep -q 'hugo' $target
@test "multi-pattern: 'hugo' stripped" $status -ne 0

grep -q 'Fantastical' $target
@test "multi-pattern: 'Fantastical' stripped" $status -ne 0

grep -q 'bat' $target
@test "multi-pattern: unrelated entry 'bat' retained" $status -eq 0

# ─── No-match patterns ────────────────────────────────────────────────────

set -l ignore_nomatch (mktemp); echo 'completely-unmatched-pattern' > $ignore_nomatch
set target (mktemp)
$dump --input $fixture_input --ignore-file $ignore_nomatch $target
cmp -s $fixture_input $target
@test "pattern matching nothing leaves output identical" $status -eq 0

# ─── Error handling ───────────────────────────────────────────────────────

set target (mktemp)
$dump --input /nonexistent-file-foobar (random) $target 2>/dev/null
@test "--input pointing at nonexistent file exits non-zero" $status -ne 0

# Don't stub `brew` by prepending to PATH here: dump-brewfile's
# `#!/usr/bin/env fish` shebang re-runs config.fish, whose `brew shellenv`
# prepends /opt/homebrew/bin and outranks the stub, so the test silently
# exercises real brew instead.
