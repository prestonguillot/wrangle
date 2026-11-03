# _diff_view.fish — the [d]iff option shared by the merge and sync prompts.
# Sourced by scripts/wrangle (and by test/diff-view.fish). Don't run directly.
#
# WHY THIS EXISTS
#
# Most adopt/track prompts used to show only a name: "home/.config/zed/
# settings.json (new from source)", or "prefix tide_* — 40 var(s)". Nothing
# said what taking the item would actually write, so an accidental or stale
# change on another machine looked exactly like a deliberate one. Only the
# merge content-conflict prompt had a [d]iff, and it printed the diff for
# good, pushing the prompt and its context off the screen.
#
# [d]iff here is a toggle. The first press expands the diff in line, under
# the item; the second press collapses it, erasing the diff so the screen
# reads as it did before. A purely additive change (a new file, a new var)
# shows as all `+` lines, a purely destructive one as all `-` lines — there
# is no case where the diff is skipped for being "obvious".
#
# HOW COLLAPSE WORKS
#
# Collapsing moves the cursor back up over everything the expand printed and
# clears to the end of the screen. That only works while all of it is still
# on screen, so a diff too tall for the terminal opens in `less -R` instead:
# the pager is the expanded state and quitting it is the collapse.
#
# When stdout is not a terminal (piped, captured by tests) nothing can be
# erased, so every press just prints the diff.
#
# FUNCTIONS
#
#   _wrangle_diff_render <old> <new> <display> <old_label> <new_label>
#       Unified diff of two paths (files or directories). Either path may be
#       empty, meaning "nothing there": an empty old shows everything in new
#       as added, an empty new shows everything in old as removed. Paths in
#       the diff headers are shown as <old_label>/<display> and
#       <new_label>/<display> instead of the real (often temp) paths.
#
#   _wrangle_univ_format <file|-> <name>...
#       One `name[i] = value` line per list element, for diffing universal
#       variables. `-` reads the live shell; a file path reads an
#       exported-univ-vars.fish-format file.
#
#   _wrangle_diff_reset
#       Forget any open diff. Call once per item, before its prompt loop.
#
#   _wrangle_diff_toggle <indent> <prompt> <answer> <render-command>...
#       Expand or collapse the diff for the current item. <prompt> and
#       <answer> are the prompt text and what the user typed, needed to know
#       how many terminal rows to erase.

set -g _wrangle_diff_rows 0

function _wrangle_diff_render --argument-names old new display old_label new_label
    set -l tmp (mktemp -d)
    # A missing side becomes /dev/null for a file, or an empty directory for
    # a directory: git diff --no-index can't compare /dev/null to a directory.
    set -l other $new
    test -z "$other"; and set other $old
    if test -z "$old"
        if test -d "$other"
            set old $tmp/empty
            mkdir $old
        else
            set old /dev/null
        end
    end
    if test -z "$new"
        if test -d "$other"
            set new $tmp/empty
            mkdir -p $new
        else
            set new /dev/null
        end
    end

    set -l color never
    test -t 1; and set color always

    # The real paths are temp files and absolute repo paths; swap them for
    # the display name so the headers say what the user is deciding about.
    # /dev/null is left alone — `--- /dev/null` is what "new file" looks like.
    set -l out (git diff --no-index --color=$color \
        --src-prefix="$old_label/" --dst-prefix="$new_label/" -- $old $new 2>&1)
    for p in $old $new
        test "$p" = /dev/null; and continue
        set -l rel (string replace -r '^/' '' -- $p)
        set out (string replace -a -- "$rel" "$display" $out)
    end
    rm -rf $tmp
    # git's own bookkeeping lines say nothing the ---/+++ pair doesn't, and
    # cost rows in an inline view. Match past any leading color code.
    set out (string match -rv '^(\e\[[0-9;]*m)*(diff --git |index [0-9a-f]|(new|deleted) file mode )' -- $out)
    test (count $out) -gt 0; and printf '%s\n' $out
    return 0
end

function _wrangle_univ_format --argument-names src
    for name in $argv[2..-1]
        set -l vals
        if test "$src" = -
            set -q $name; or continue
            set vals $$name
        else
            # Parse names first so an absent var prints nothing, while a
            # present-but-empty one still shows up below.
            contains -- $name (_wrangle_univ_parse_names $src); or continue
            set vals (_wrangle_univ_parse_values $src $name)
        end
        if test (count $vals) -eq 0
            echo "$name = (empty)"
            continue
        end
        set -l i 0
        for v in $vals
            set i (math $i + 1)
            echo "$name"'['$i'] = '(string escape -- $v)
        end
    end
end

function _wrangle_diff_reset
    set -g _wrangle_diff_rows 0
end

# Terminal rows a line takes up once wrapped at <cols>.
function _wrangle_diff_line_rows --argument-names line cols
    set -l w (string length --visible -- "$line")
    test $w -eq 0; and set w 1
    math "ceil($w / $cols)"
end

function _wrangle_diff_toggle --argument-names indent prompt answer
    set -l render $argv[4..-1]

    if not test -t 1
        set -l lines ($render)
        echo ""
        if test (count $lines) -eq 0
            echo "$indent(no differences)"
        else
            printf "$indent%s\n" $lines
        end
        echo ""
        return
    end

    set -l size (stty size </dev/tty 2>/dev/null | string split ' ')
    set -l term_rows 24
    set -l cols 80
    # A pty nobody sized reports `0 0`; keep the defaults rather than divide
    # by zero.
    if test (count $size) -eq 2; and test "$size[1]" -gt 0 2>/dev/null
        and test "$size[2]" -gt 0 2>/dev/null
        set term_rows $size[1]
        set cols $size[2]
    end

    # Rows taken by the prompt line the user just answered.
    set -l answer_rows (_wrangle_diff_line_rows "$prompt$answer" $cols)

    if test $_wrangle_diff_rows -gt 0
        # Collapse: erase the diff, the prompt line that opened it, and the
        # one just answered. The caller's loop re-prompts on a clean screen.
        printf '\e[%dF\e[J' (math $_wrangle_diff_rows + $answer_rows)
        set -g _wrangle_diff_rows 0
        return
    end

    set -l lines ($render)
    if test (count $lines) -eq 0
        set lines (set_color brblack)"(no differences)"(set_color normal)
    end
    set lines "" (string replace -r '^' -- "$indent" $lines) \
        "" "$indent"(set_color brblack)"· [d] again to collapse"(set_color normal)

    set -l body_rows 0
    for l in $lines
        set body_rows (math $body_rows + (_wrangle_diff_line_rows "$l" $cols))
    end

    # Everything printed plus the next prompt has to stay on screen to be
    # erasable. If it won't, page it instead.
    if test (math $answer_rows + $body_rows + $answer_rows + 1) -ge $term_rows
        and command -q less
        printf '%s\n' $lines[2..-3] | less -R
        # Back from the pager: drop the answered prompt line so the re-prompt
        # sits where it was.
        printf '\e[%dF\e[J' $answer_rows
        return
    end

    printf '%s\n' $lines
    set -g _wrangle_diff_rows (math $answer_rows + $body_rows)
end
