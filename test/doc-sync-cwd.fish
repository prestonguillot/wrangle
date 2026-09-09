# Doc-sync cwd tests — assert the claude doc passes run against the wrangle
# repo, not against whatever directory the user invoked wrangle from.
#
# WHY THIS EXISTS
#
# `wrangle` is runnable from anywhere: it resolves its own repo from its
# script path. The claude doc passes, however, shelled out to `claude` with
# no cwd of their own, so claude inherited the caller's cwd — and with
# `--permission-mode acceptEdits` plus Read/Edit/Write/Grep/Glob it would
# read, reason about, and potentially EDIT .md files in an unrelated repo.
#
# Observed in the wild: a `wrangle sync` run from ~/development/personal/
# <other-project> had the doc pass report that the commits it was given
# "don't exist in this repo" and that there was no `personal` branch —
# because claude was inspecting that other project. The post-pass guard
# (`git status` under $repo) cannot catch this: it inspects the right
# directory while claude edited the wrong one.
#
# These tests stub `claude` with a fake executable that records its own cwd,
# then invoke wrangle from an unrelated directory and assert the recorded
# cwd is the fixture repo.

set -l repo_root (dirname (realpath (status -f)))/..
source $repo_root/test/helpers/fixture.fish

function _docsync_fixture --inherit-variable repo_root
    set -l fix (mktemp -d)
    set -l home_dir (mktemp -d)

    _wrangle_fixture_init_repo $fix "doc-sync-cwd-test" main
    _wrangle_fixture_install_scripts $fix $repo_root
    _wrangle_fixture_seed_files $fix $repo_root real

    echo "# fixture" > $fix/README.md
    git -C $fix add -A
    git -C $fix commit -q -m "fixture seed"
    git -C $fix checkout -q -b personal

    echo $fix
    echo $home_dir
end

# A fake `claude` on PATH that writes its cwd to $CLAUDE_CWD_LOG and exits 0.
# Named `claude` so `command -q claude` finds it and wrangle takes the real
# code path.
function _install_fake_claude --argument-names bindir logfile
    mkdir -p $bindir
    printf '#!/bin/sh\npwd > "%s"\nexit 0\n' $logfile > $bindir/claude
    chmod +x $bindir/claude
end

# ─── review-docs runs claude in the repo, not the caller's cwd ─────────────

set -l f1 (_docsync_fixture)
set -l fix1 $f1[1]; set -l home1 $f1[2]
set -l bin1 (mktemp -d)
set -l log1 (mktemp)
_install_fake_claude $bin1 $log1

# Invoke from an unrelated directory — the bug's trigger condition.
set -l elsewhere1 (mktemp -d)
git -C $elsewhere1 init -q -b main
pushd $elsewhere1 >/dev/null
env HOME=$home1 PATH="$bin1:$PATH" $fix1/scripts/wrangle review-docs >/dev/null 2>&1
popd >/dev/null

set -l recorded1 (cat $log1 2>/dev/null | string trim)
@test "review-docs: claude ran somewhere (fake claude was invoked)" -n "$recorded1"
@test "review-docs: claude cwd is the wrangle repo, not the caller's cwd" (realpath $recorded1) = (realpath $fix1)
@test "review-docs: claude cwd is NOT the unrelated invocation dir" (realpath $recorded1) != (realpath $elsewhere1)

# ─── the invoke helper refuses a missing/empty repo dir ───────────────────
# Guard against a future call site forgetting to pass the repo: better to
# fail loudly than to silently run claude against the inherited cwd.

set -l f2 (_docsync_fixture)
set -l fix2 $f2[1]; set -l home2 $f2[2]
# Sourcing wrangle would execute it, so assert the guard by reading the
# function body instead — the behavioral assertion above already covers the
# happy path, and this keeps the test hermetic.
set -l guard_src (fish -c "
    functions -e _wrangle_invoke_claude
    sed -n '/^function _wrangle_invoke_claude/,/^end/p' $fix2/scripts/wrangle
")
string match -q '*claude_cwd*' -- "$guard_src"
@test "invoke helper takes an explicit cwd argument" $status -eq 0
string match -q '*pushd $claude_cwd*' -- "$guard_src"
@test "invoke helper pushd's into the given repo before running claude" $status -eq 0
string match -q '*not test -d*' -- "$guard_src"
@test "invoke helper validates the repo dir exists" $status -eq 0

# ─── both call sites pass the repo explicitly ─────────────────────────────
set -l call_sites (grep -c '_wrangle_invoke_claude \$repo' $fix2/scripts/wrangle)
@test "both doc passes pass \$repo to the invoke helper" "$call_sites" = 2
set -l bare_sites (grep -c '_wrangle_invoke_claude "\$prompt_text"' $fix2/scripts/wrangle)
@test "no doc pass calls the invoke helper without a repo dir" "$bare_sites" = 0
