# wrangle CLI surface tests. Smoke-tests for subcommand dispatch + per-subcommand help.

set -l wrangle (dirname (realpath (status -f)))/../scripts/wrangle

# ─── Top-level help: all of `wrangle`, `wrangle -h`, `wrangle --help`,
#     and `wrangle help` should print the same thing and exit 0.

for invocation in (echo bare) -h --help help
    # `bare` represents calling with no args.
    if test "$invocation" = bare
        $wrangle >/dev/null
    else
        $wrangle $invocation >/dev/null
    end
    @test "wrangle $invocation exits 0" $status -eq 0
end

set -l top_help ($wrangle help)

set -l bare_help ($wrangle)
test "$bare_help" = "$top_help"
@test "bare wrangle prints same output as `wrangle help`" $status -eq 0

set -l dash_h_help ($wrangle -h)
test "$dash_h_help" = "$top_help"
@test "wrangle -h prints same output as `wrangle help`" $status -eq 0

set -l dash_dash_help_help ($wrangle --help)
test "$dash_dash_help_help" = "$top_help"
@test "wrangle --help prints same output as `wrangle help`" $status -eq 0

for subcmd in sync update merge review-docs status
    string match -q "*$subcmd*" -- "$top_help"
    @test "top-level help lists subcommand: $subcmd" $status -eq 0
end

string match -q "*WRANGLE_NO_PUSH_NAG*"     -- "$top_help"; @test "top-level help mentions WRANGLE_NO_PUSH_NAG" $status -eq 0
string match -q "*WRANGLE_NO_PULL_NAG*"     -- "$top_help"; @test "top-level help mentions WRANGLE_NO_PULL_NAG" $status -eq 0
string match -q "*WRANGLE_NO_STALENESS_NAG*" -- "$top_help"; @test "top-level help mentions WRANGLE_NO_STALENESS_NAG" $status -eq 0
string match -q "*WRANGLE_NO_BRANCH_SWITCH*" -- "$top_help"; @test "top-level help mentions WRANGLE_NO_BRANCH_SWITCH" $status -eq 0
string match -q "*WRANGLE_ALLOW_SECRETS*"   -- "$top_help"; @test "top-level help mentions WRANGLE_ALLOW_SECRETS" $status -eq 0
string match -q "*WRANGLE_CLAUDE_MODEL*"    -- "$top_help"; @test "top-level help mentions WRANGLE_CLAUDE_MODEL" $status -eq 0
string match -q "*WRANGLE_CLAUDE_EFFORT*"   -- "$top_help"; @test "top-level help mentions WRANGLE_CLAUDE_EFFORT" $status -eq 0

string match -q "*wrangle.machine-branch*"  -- "$top_help"; @test "top-level help mentions wrangle.machine-branch git config" $status -eq 0

# ─── Per-subcommand --help ──────────────────────────────────────────────

set -l sync_help ($wrangle sync --help)
string match -q "*--dry-run*"          -- "$sync_help"; @test "sync --help mentions --dry-run" $status -eq 0
string match -q "*--force*"            -- "$sync_help"; @test "sync --help mentions --force" $status -eq 0
string match -q "*--with-claude*"      -- "$sync_help"; @test "sync --help mentions --with-claude" $status -eq 0
string match -q "*--suppress-claude*"  -- "$sync_help"; @test "sync --help mentions --suppress-claude" $status -eq 0
string match -q "*--no-branch-switch*" -- "$sync_help"; @test "sync --help mentions --no-branch-switch" $status -eq 0

set -l update_help ($wrangle update --help)
string match -q "*origin/main*" -- "$update_help"; @test "update --help mentions origin/main" $status -eq 0

set -l merge_help ($wrangle merge --help)
string match -q "*<branch>*" -- "$merge_help"; @test "merge --help mentions <branch> arg" $status -eq 0
string match -q "*Add-only*" -- "$merge_help"; @test "merge --help mentions add-only semantics" $status -eq 0

# `wrangle help <subcmd>` works the same as `wrangle <subcmd> --help`.
set -l help_sync ($wrangle help sync)
string match -q "*--dry-run*" -- "$help_sync"; @test "help sync mentions --dry-run" $status -eq 0

set -l help_update ($wrangle help update)
string match -q "*origin/main*" -- "$help_update"; @test "help update mentions origin/main" $status -eq 0

set -l help_merge ($wrangle help merge)
string match -q "*<branch>*" -- "$help_merge"; @test "help merge mentions <branch>" $status -eq 0

# ─── Subcommand dispatch ────────────────────────────────────────────────

# Unknown subcommand exits non-zero with a hint to `wrangle help`.
$wrangle nonexistent-subcmd 2>/dev/null
@test "unknown subcommand exits non-zero" $status -ne 0

set -l unknown_err ($wrangle nonexistent-subcmd 2>&1)
string match -q "*unknown subcommand*" -- "$unknown_err"
@test "unknown subcommand prints 'unknown subcommand'" $status -eq 0

string match -q "*wrangle help*" -- "$unknown_err"
@test "unknown subcommand suggests `wrangle help`" $status -eq 0

# Leading flag (no subcommand) is rejected, NOT defaulted to sync.
$wrangle --dry-run 2>/dev/null
@test "wrangle --dry-run (no subcommand) exits non-zero" $status -ne 0

set -l flag_err ($wrangle --dry-run 2>&1)
string match -q "*flag, not a subcommand*" -- "$flag_err"
@test "wrangle --dry-run prints 'flag, not a subcommand'" $status -eq 0

# ─── Backtick rendering: help text + error text must NOT contain literal
#     backslash-backticks (`\``). Fish doesn't need backticks escaped in
#     double-quoted strings; if any `echo "\`...\`"` slipped through, this
#     test catches it.
set -l top_help_str ($wrangle help | string join \n)
not string match -q '*\\`*' -- "$top_help_str"
@test "top-level help has no literal backslash-backticks" $status -eq 0

set -l sync_help_str ($wrangle sync --help | string join \n)
not string match -q '*\\`*' -- "$sync_help_str"
@test "sync help has no literal backslash-backticks" $status -eq 0

set -l update_help_str ($wrangle update --help | string join \n)
not string match -q '*\\`*' -- "$update_help_str"
@test "update help has no literal backslash-backticks" $status -eq 0

set -l merge_help_str ($wrangle merge --help | string join \n)
not string match -q '*\\`*' -- "$merge_help_str"
@test "merge help has no literal backslash-backticks" $status -eq 0

# ─── sync-specific: mutually-exclusive flags ────────────────────────────

set -l conflict_out ($wrangle sync --with-claude --suppress-claude 2>&1)
@test "sync --with-claude + --suppress-claude exits non-zero" $status -ne 0

string match -q "*mutually exclusive*" -- "$conflict_out"
@test "sync --with-claude + --suppress-claude prints 'mutually exclusive'" $status -eq 0

# Non-sync subcommands don't accept --with-claude (argparse rejects it).
$wrangle update --with-claude 2>/dev/null
@test "update rejects --with-claude (sync-only flag)" $status -ne 0

# ─── merge positional validation ────────────────────────────────────────

set -l merge_out ($wrangle merge 2>&1)
@test "merge with no args exits non-zero" $status -ne 0

string match -q "*expects exactly one argument*" -- "$merge_out"
@test "merge with no args prints usage" $status -eq 0

# ─── push subcommand surface ────────────────────────────────────────────

string match -q "*push*" -- "$top_help"
@test "top-level help lists push subcommand" $status -eq 0

set -l push_help ($wrangle push --help)
string match -q "*Push the current branch to origin*" -- "$push_help"
@test "push --help describes what push does" $status -eq 0

# push doesn't take any flags besides --help.
$wrangle push --dry-run 2>/dev/null
@test "push rejects --dry-run (sync-only flag)" $status -ne 0

# Backtick-rendering test for push help.
set -l push_help_str ($wrangle push --help | string join \n)
not string match -q '*\\`*' -- "$push_help_str"
@test "push help has no literal backslash-backticks" $status -eq 0

# ─── status subcommand surface ──────────────────────────────────────────

string match -q "*status*" -- "$top_help"
@test "top-level help lists status subcommand" $status -eq 0

set -l status_help ($wrangle status --help)
string match -q "*Read-only summary*" -- "$status_help"
@test "status --help describes what status does" $status -eq 0

# status doesn't take any flags besides --help.
$wrangle status --dry-run 2>/dev/null
@test "status rejects --dry-run (sync-only flag)" $status -ne 0
$wrangle status --force 2>/dev/null
@test "status rejects --force (sync-only flag)" $status -ne 0

# Backtick-rendering test for status help.
set -l status_help_str ($wrangle status --help | string join \n)
not string match -q '*\\`*' -- "$status_help_str"
@test "status help has no literal backslash-backticks" $status -eq 0

# ─── repair subcommand surface ──────────────────────────────────────────

string match -q "*repair*" -- "$top_help"
@test "top-level help lists repair subcommand" $status -eq 0

set -l repair_help ($wrangle repair --help)
string match -q "*will not stow*" -- "$repair_help"
@test "repair --help describes what repair does" $status -eq 0

string match -q "*--dry-run*" -- "$repair_help"
@test "repair --help documents --dry-run" $status -eq 0

# repair takes --dry-run and nothing else.
$wrangle repair --force 2>/dev/null
@test "repair rejects --force (sync-only flag)" $status -ne 0
$wrangle repair --verbose 2>/dev/null
@test "repair rejects --verbose (sync-only flag)" $status -ne 0
$wrangle repair --no-branch-switch 2>/dev/null
@test "repair rejects --no-branch-switch (sync-only flag)" $status -ne 0

# Backtick-rendering test for repair help.
set -l repair_help_str ($wrangle repair --help | string join \n)
not string match -q '*\\`*' -- "$repair_help_str"
@test "repair help has no literal backslash-backticks" $status -eq 0
