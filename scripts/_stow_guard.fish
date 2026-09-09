# _stow_guard.fish — pre-flight checks for paths GNU stow cannot manage, one
# owner for the stow invocation itself, and plain-language explanations for
# the failures stow does report. Sourced by scripts/wrangle. Don't run directly.
#
# WHY THIS EXISTS
#
# home/ is a single stow package. GNU stow refuses to stow a package
# containing an absolute symlink at ANY depth (Stow.pm stow_node: "they can't
# be unstowed"), and it collects conflicts during planning, so it aborts
# having changed nothing. Both halves matter:
#
#   - One bad symlink blocks every file in home/, not just its own subtree.
#     A path tracked today can break the re-stow of everything tracked
#     before it, and the breakage persists in the repo across runs.
#   - Because a conflicted stow makes no filesystem changes, a track that
#     fails at the stow step can be rolled back exactly — the only mutation
#     that happened was wrangle's own mv.
#
# So the rule is: find the paths stow can't take BEFORE moving anything, and
# report them instead of touching them. What stow rejects at plan time, this
# file rejects at enumeration time, with the same verdict and a better message.
#
# The absolute-symlink refusal arrived in stow 2.4.0. Older stow (2.3.1 is
# still what Debian and Ubuntu ship) stows one without complaint, which is
# worse rather than better: you get a link in ~ that stow itself will refuse
# to remove later. The checks here are deliberately version-independent —
# these paths do not belong in a stow package on any version.

# ─── Hazard scanning ─────────────────────────────────────────────────────

# Lexically collapse `.` and `..` in an absolute path, without touching the
# filesystem. realpath is not usable here: the target of a broken or
# not-yet-created symlink doesn't resolve, and BSD realpath (macOS) exits 1
# on any path whose components don't all exist.
function _wrangle_lexical_normalize --argument-names path
    set -l out
    for seg in (string split / -- $path)
        switch $seg
            case '' .
                # empty (leading / or doubled //) and no-op segments
            case ..
                # Clamp at / rather than accumulating; these are absolute paths.
                set -q out[1]; and set -e out[-1]
            case '*'
                set -a out $seg
        end
    end
    # An empty command substitution annihilates the whole concatenated word
    # in fish, so `/`(join of nothing) yields nothing rather than "/".
    if test (count $out) -eq 0
        echo /
    else
        echo /(string join / -- $out)
    end
end

# Canonical form of a path that may not fully exist: realpath it if it does,
# otherwise realpath its parent and re-attach the last component. Falls back
# to the lexical form when neither resolves.
#
# Needed because the two sides of the orphan comparison are built from
# different roots — the link is resolved against $HOME, while home/ comes from
# `git rev-parse --show-toplevel` — and either can sit under a symlinked
# ancestor (/var -> /private/var on macOS, or a symlinked home or checkout).
# A purely lexical compare then never matches.
function _wrangle_canonical --argument-names path
    set -l direct (realpath $path 2>/dev/null)
    if test -n "$direct"
        echo $direct
        return 0
    end
    set -l parent (realpath (dirname $path) 2>/dev/null)
    if test -n "$parent"
        echo $parent/(basename $path)
        return 0
    end
    _wrangle_lexical_normalize $path
end

# Does a relative symlink resolve outside the tree being tracked? Compared
# lexically against the root, for the same reason as above.
function _wrangle_symlink_escapes --argument-names root link target
    set -l resolved (_wrangle_lexical_normalize (dirname $link)/$target)
    set -l root_norm (_wrangle_lexical_normalize $root)
    test "$resolved" = "$root_norm"; and return 1
    string match -q "$root_norm/*" -- $resolved; and return 1
    return 0
end

# Name the flavor of non-regular file, for the hazard detail field.
function _wrangle_stow_file_kind --argument-names path
    if test -p $path
        echo "named pipe (fifo)"
    else if test -S $path
        echo socket
    else if test -b $path
        echo "block device"
    else if test -c $path
        echo "character device"
    else
        echo "not a regular file or directory"
    end
end

# Walk <root> and report everything stow or git cannot store. Echoes one
# tab-separated <kind>\t<path>\t<detail> line per hazard; no output means the
# path is safe to track. <root> may be a file, a directory, or a symlink.
#
#   abs-symlink       stow refuses the whole package (Stow.pm stow_node)
#   escaping-symlink  survives stow, but resolves relative to the repo after
#                     the move instead of ~, so it silently breaks
#   special           socket / fifo / device — git cannot store it, so the
#                     path would leave ~ and not come back
#
# find does not follow symlinks by default: a symlinked directory is reported
# as a link and not descended into, which is what we want — the link itself is
# the hazard, not whatever is on the far side of it.
#
# `! -type f ! -type d` makes find return ONLY the candidates for a hazard —
# symlinks, sockets, fifos, devices. Everything else is filtered in C before
# it reaches fish. This matters now that top-level dotfiles are in scope: a
# tree like ~/.m2 can hold six figures of regular files, and materializing
# all of them into a fish list to check each one would be needlessly slow.
function _wrangle_stow_hazards --argument-names root
    test -e $root; or test -L $root; or return 0

    for p in (find $root ! -type f ! -type d 2>/dev/null)
        # -L first: -f and -d follow symlinks and would misreport them.
        if test -L $p
            set -l target (readlink $p)
            if string match -q '/*' -- $target
                printf '%s\t%s\t%s\n' abs-symlink $p $target
            else if _wrangle_symlink_escapes $root $p $target
                printf '%s\t%s\t%s\n' escaping-symlink $p $target
            end
        else
            printf '%s\t%s\t%s\n' special $p (_wrangle_stow_file_kind $p)
        end
    end
end

# ─── Hazard reporting ────────────────────────────────────────────────────

# Render a path the way the rest of wrangle refers to it: paths inside the
# repo's package as `home/...`, paths in the user's home as `~/...`. Cosmetic
# only, but these messages are read by someone whose home directory is broken,
# so an absolute path four levels deep is exactly the wrong thing to show them.
function _wrangle_tilde --argument-names path
    if test -n "$home_subdir"; and string match -q "$home_subdir/*" -- $path
        string replace -- "$home_subdir/" 'home/' $path
        return 0
    end
    string replace -- "$HOME/" '~/' $path
end

# Same, for a path as stow printed it. stow reports package paths relative to
# its own working directory ("../repo/home/.config/…"), which is meaningless
# to the reader; the package name is the reliable anchor.
function _wrangle_stow_path --argument-names path
    string replace -r '^.*/home/' 'home/' -- $path
end

# One hazard, rendered as human text at the given indent. Single owner for
# this wording so the sync report, the track failure block, and `wrangle
# repair` all describe the same problem the same way.
function _wrangle_stow_hazard_explain --argument-names kind path detail indent
    set -l shown (_wrangle_tilde $path)
    switch $kind
        case abs-symlink
            echo "$indent"(_name $shown)" is a symlink to an absolute path"
            echo "$indent  $GLYPH_ARROW "(_name $detail)
        case escaping-symlink
            echo "$indent"(_name $shown)" is a symlink pointing outside this path"
            echo "$indent  $GLYPH_ARROW "(_name $detail)
        case special
            echo "$indent"(_name $shown)" is a $detail"
        case '*'
            echo "$indent"(_name $shown)" ($kind)"
    end
end

# Why a given hazard kind blocks tracking. Printed once per kind, after the
# per-path list, so a directory with six bad symlinks explains itself once.
function _wrangle_stow_hazard_why --argument-names kind indent
    switch $kind
        case abs-symlink
            echo "$indent"'stow will not store a symlink to an absolute path, because it could'
            echo "$indent"'never remove it again. One anywhere under home/ blocks every file in'
            echo "$indent"'the package, not just this path.'
        case escaping-symlink
            echo "$indent"'the link points outside the path being tracked, so once the path moves'
            echo "$indent"'into the repo the link would resolve against the repo instead of ~.'
        case special
            echo "$indent"'git cannot store sockets, pipes, or device files. Tracking this would'
            echo "$indent"'move it out of ~ and it would not come back on any other machine.'
    end
end

# A full hazard list, rendered: every offending path, then one explanation
# per distinct kind (so a directory holding six bad symlinks explains itself
# once, not six times). Takes the indent first, then the hazard lines as
# produced by _wrangle_stow_hazards.
function _wrangle_stow_hazard_report --argument-names indent
    set -l hazards $argv[2..-1]
    set -l kinds
    for h in $hazards
        set -l parts (string split \t -- $h)
        _wrangle_stow_hazard_explain $parts[1] $parts[2] $parts[3] $indent
        contains -- $parts[1] $kinds; or set -a kinds $parts[1]
    end
    # Blank line between the list of offending paths and the explanations,
    # and between each explanation — without it the whole block reads as one
    # undifferentiated wall.
    for k in $kinds
        echo ""
        _wrangle_stow_hazard_why $k $indent
    end
end

# ─── Running stow ────────────────────────────────────────────────────────

# Every re-stow in wrangle goes through here, so the flags live in one place
# and every caller gets the failure text instead of losing it.
#
# Captures both streams: stow writes conflicts to stderr, and the generic
# _with_spinner deliberately lets stderr through live (so sudo prompts work),
# which strands stow's multi-line conflict report across the spinner's line.
# stow never prompts, so capturing is safe here.
#
# On failure the raw output is left in $_wrangle_stow_err for
# _wrangle_stow_explain_failure. Returns stow's exit status.
function _wrangle_stow_run --argument-names label repo_path
    set -g _wrangle_stow_err ''
    set -l out (mktemp)
    _spinner_start "$label"
    command stow --no-folding -R -t $HOME -d $repo_path home >$out 2>&1
    set -l rv $status
    _spinner_stop
    set -g _wrangle_stow_err (cat $out)
    rm -f $out
    return $rv
end

# Turn stow's conflict output into a cause the reader can act on. stow lists
# each conflict as "  * <message>"; we translate the messages we recognize and
# pass anything else through verbatim rather than swallowing it.
function _wrangle_stow_explain_failure --argument-names indent
    set -l lines $argv[2..-1]
    set -l found no

    for line in $lines
        set -l l (string trim -- $line)
        string match -q '\**' -- $l; or continue
        set -l msg (string trim -- (string replace -r '^\*+' '' -- $l))
        set found yes

        if set -l m (string match -r '^source is an absolute symlink (.+) => (.+)$' -- $msg)
            echo "$indent"(_name (_wrangle_stow_path $m[2]))" is a symlink to an absolute path"
            echo "$indent  $GLYPH_ARROW "(_name $m[3])
            echo "$indent  stow will not store it, and it blocks every other file in home/."
        else if set -l m (string match -r '^existing target is not owned by stow: (.+)$' -- $msg)
            echo "$indent"(_name "~/$m[2]")" already exists and is a real file, not a symlink."
            echo "$indent  stow will not overwrite it."
        else if set -l m (string match -r '^existing target is stowed to a different package: (.+?) =>' -- $msg)
            echo "$indent"(_name "~/$m[2]")" is a symlink owned by a different stow package."
        else if set -l m (string match -r '^cannot stow (.+) over existing target (.+?) since' -- $msg)
            echo "$indent"(_name "~/$m[3]")" already exists and is neither a symlink nor a directory."
        else if set -l m (string match -r '^cannot stow (?:non-)?directory (.+) over existing (.+?) target (.+)$' -- $msg)
            echo "$indent"(_name "~/$m[4]")" exists with a conflicting type ($m[3])."
        else
            echo "$indent$msg"
        end
    end

    # Anything stow said that wasn't a "* conflict" line (a real error rather
    # than a planning conflict) still has to reach the user.
    if test "$found" = no
        for line in $lines
            test -n (string trim -- $line); and echo "$indent"(string trim -- $line)
        end
    end
end

# ─── Orphan symlinks ─────────────────────────────────────────────────────

# Symlinks in ~ that point into home/ but whose target no longer exists.
# Echoes one path per line.
#
# Detection is lexical on purpose. The previous implementation ran the link
# through realpath to decide whether it pointed into the repo — but it only
# ever examined links it had already established were broken, and BSD realpath
# exits 1 without output on a path that doesn't resolve. $tgt was always
# empty, the prefix match always failed, and the pass matched nothing.
# readlink reads the link text without resolving it, which is what this needs.
function _wrangle_orphan_symlinks --argument-names home_subdir
    # fish has no bracket globs: the old `$HOME/.[A-Za-z0-9]*` matched
    # literally nothing, so top-level dotfiles were never scanned here either.
    set -l scan
    for f in $HOME/.*
        string match -qr '^\.[A-Za-z0-9]' -- (string replace -- $HOME/ "" $f); or continue
        set -a scan $f
    end
    for f in $HOME/.config/* $HOME/.config/fish/conf.d/* $HOME/.config/fish/functions/*
        set -a scan $f
    end

    set -l root_canon (_wrangle_canonical $home_subdir)

    for f in $scan
        test -L $f; or continue
        # Broken? test -e follows the link, so this is false when the target
        # is missing — which is the whole population we care about.
        test -e $f; and continue

        # `set -l` inside an if-branch does not survive the `end` in fish,
        # so declare it in the loop scope first.
        set -l target (readlink $f)
        set -l resolved
        if string match -q '/*' -- $target
            set resolved (_wrangle_lexical_normalize $target)
        else
            set resolved (_wrangle_lexical_normalize (dirname $f)/$target)
        end
        # Compare canonical forms: the link resolves against $HOME while
        # home_subdir comes from git, and either can sit under a symlinked
        # ancestor. Keep the lexical compare too, for the case where neither
        # side resolves at all.
        if not string match -q "$home_subdir/*" -- $resolved
            string match -q "$root_canon/*" -- (_wrangle_canonical $resolved); or continue
        end
        echo $f
    end
end
