# _diff_view.fish — the [tab] diff option shared by the merge and sync prompts.
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
# Tab is a toggle. The first press expands the diff in line, under the
# item; the second collapses it, erasing the diff so the screen reads as it
# did before. Neither needs Enter, and the prompt is redrawn in place rather
# than printed again. (`d` + Enter does the same, and is what piped input
# uses.) A purely additive change (a new file, a new var)
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
#       Forget any open diff. _wrangle_ask calls it per prompt.
#
#   _wrangle_ask <indent> <prompt> <render-command>...
#       Read an answer with Tab bound to expand/collapse the diff that
#       <render-command> prints. Answer lands in $_wrangle_answer.

# Uses _keys (prompt key coloring) from scripts/wrangle.

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
    if set -q _wrangle_diff_color
        set color $_wrangle_diff_color
    else if test -t 1
        set color always
    end

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

# Prompt for an answer, with the item's diff a keystroke away. Sets the
# global $_wrangle_answer (the line typed, without the newline) rather than
# printing it, since the prompt and diff go to stdout too.
#
#   _wrangle_ask <indent> <prompt> <render-command>...
#
# On a terminal: Tab expands or collapses the diff in place, with no Enter
# and no fresh prompt line — the one prompt is redrawn below the diff, with
# whatever was typed so far. `d` + Enter does the same. Other answers are
# typed and confirmed with Enter as before.
#
# Off a terminal (piped input, tests): plain `read`; `d` prints the diff
# and asks again.
function _wrangle_ask --argument-names indent prompt
    set -l render $argv[3..-1]
    set -g _wrangle_answer ''
    _wrangle_diff_reset

    if not test -t 0; or not test -t 1
        while true
            read -P (_keys $prompt) ans; or return 0
            if contains -- "$ans" d D diff
                set -l lines ($render)
                echo ""
                if test (count $lines) -eq 0
                    echo "$indent(no differences)"
                else
                    printf "$indent%s\n" $lines
                end
                echo ""
                continue
            end
            set -g _wrangle_answer $ans
            return 0
        end
    end

    # Raw-ish mode: one byte at a time, no echo. Signals stay on, so Ctrl-C
    # still reaches the SIGINT handler, which restores this via
    # $_wrangle_stty_saved.
    set -g _wrangle_stty_saved (stty -g </dev/tty)
    stty -icanon -echo </dev/tty

    set -l buf ''
    printf '%s' (_keys $prompt)
    while true
        # One byte, exactly: `head -c 1` reads a whole buffer from the tty and
        # keeps the first byte, eating keys typed in quick succession.
        # `string collect` trims the trailing newline, so Enter reads as ''.
        set -l k (dd bs=1 count=1 </dev/tty 2>/dev/null | string collect)
        switch "$k"
            case \t
                _wrangle_diff_tty_toggle $indent $prompt "$buf" $render
            case '' \r
                if contains -- "$buf" d D diff
                    # Same as Tab, and the `d` isn't an answer: unprint it
                    # so the redrawn prompt comes back empty.
                    printf (string repeat -n (string length -- $buf) '\b \b')
                    set buf ''
                    _wrangle_diff_tty_toggle $indent $prompt '' $render
                    continue
                end
                break
            case \x7f \b
                if test -n "$buf"
                    set buf (string sub -e -1 -- $buf)
                    printf '\b \b'
                end
            case \e
                # Swallow arrow / function-key sequences (ESC [ X, ESC O X)
                # so their tail bytes don't land in the answer.
                set -l k2 (dd bs=1 count=1 </dev/tty 2>/dev/null | string collect)
                contains -- "$k2" '[' O; and dd bs=1 count=1 </dev/tty 2>/dev/null >/dev/null
            case '*'
                if string match -qr '^[[:print:]]$' -- "$k"
                    set buf "$buf$k"
                    printf '%s' "$k"
                end
        end
    end

    stty $_wrangle_stty_saved </dev/tty
    set -e _wrangle_stty_saved
    printf '\n'
    set -g _wrangle_answer $buf
end

# Expand or collapse the diff while the prompt is on screen. The cursor is
# at the end of the prompt line (prompt + what's been typed). The prompt is
# cleared, the diff printed or erased above where it sat, and the prompt
# redrawn underneath.
function _wrangle_diff_tty_toggle --argument-names indent prompt buf
    set -l render $argv[4..-1]

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

    # Clear the prompt, which may have wrapped.
    set -l prompt_rows (_wrangle_diff_line_rows "$prompt$buf" $cols)
    printf '\r'
    test $prompt_rows -gt 1; and printf '\e[%dA' (math $prompt_rows - 1)
    printf '\e[J'

    if test $_wrangle_diff_rows -gt 0
        printf '\e[%dF\e[J' $_wrangle_diff_rows
        set -g _wrangle_diff_rows 0
    else
        # Rendered inside a command substitution, where git can't see the
        # terminal — so say outright that color is wanted.
        set -g _wrangle_diff_color always
        set -l lines ($render)
        set -e _wrangle_diff_color
        if test (count $lines) -eq 0
            set lines (set_color brblack)"(no differences)"(set_color normal)
        end

        # Everything has to stay on screen to be erasable on collapse. If it
        # won't fit, page it: quitting the pager is the collapse.
        set -l body_rows 0
        for l in $lines
            set body_rows (math $body_rows + (_wrangle_diff_line_rows "$indent$l" $cols))
        end
        if test (math $body_rows + 3 + $prompt_rows + 1) -ge $term_rows
            and command -q less
            printf '%s\n' $lines | less -R
        else
            set lines "" (string replace -r '^' -- "$indent" $lines) "" \
                "$indent"(set_color brblack)"· tab again to collapse"(set_color normal)
            printf '%s\n' $lines
            set -g _wrangle_diff_rows (math $body_rows + 3)
        end
    end

    printf '%s%s' (_keys $prompt) $buf
end
