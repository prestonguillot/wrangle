# _merge_base.fish — three-way merging for `wrangle merge` dotfiles: the
# remembered merge base, and handing a merge to the user's git mergetool.
# Sourced by scripts/wrangle (and test/merge-base.fish). Don't run directly.
#
# WHY A REMEMBERED BASE
#
# A three-way merge needs the version both sides started from. Git can't
# supply it here: machine-branches only meet at `main`, and personal-layer
# files (config.fish, .gitconfig) don't exist on `main`. And `wrangle merge`
# copies content rather than doing a git merge, so git never learns that
# two branches synced a file.
#
# So wrangle records it. .merge-base (committed on the machine-branch) holds
# one line per source branch and path: the blob of the source's file as it
# was the last time this machine merged it — adopted, merged, or kept. Next
# time:
#   - source unchanged since then  → nothing to merge, no prompt, even if
#                                    this machine's copy differs (its own
#                                    edits, or changes the user declined)
#   - source changed               → the mergetool gets that blob as BASE,
#                                    so only lines both sides changed
#                                    conflict
#
# The blob is referenced by sha, not copied. If git can't find it any more
# (history rewritten), it's treated as having no base.
#
# A file never merged from that source has no recorded base. Then the base
# is the newest version both branches' histories share, if any
# (_wrangle_merge_base_shared) — the last point the two copies matched.
#
# WHY GIT MERGETOOL
#
# The user already has a merge tool configured for git, with whatever
# command, trustExitCode and backup settings they chose. Rather than
# re-implement git's tool launching, _wrangle_mergetool builds a real
# unmerged index entry (stages 1/2/3) in a throwaway repo and runs
# `git mergetool` on it, so git launches the tool exactly as it would in
# any other merge.
#
# FILE FORMAT (.merge-base)
#
#   <source-branch> <path> <blob-sha>
#
# <source-branch> is the name given to `wrangle merge` (e.g. `work`), so
# origin/work and a local work share their bases.
#
# FUNCTIONS
#
#   _wrangle_merge_base_get <file> <source> <path>
#       Prints the recorded blob sha, or nothing.
#
#   _wrangle_merge_base_set <file> <source> <path> <sha>
#       Records (or replaces) the base. Returns 1 if it was already that.
#
#   _wrangle_merge_base_shared <source-ref> <path>
#       No recorded base? The newest version of <path> that appears in both
#       the source's history and HEAD's. Prints its blob sha, or nothing if
#       the branches never had the same version.
#
#   _wrangle_mergetool <base|""> <mine> <theirs> <path> <out>
#       Runs the configured git mergetool on the three versions. On success
#       writes the result to <out> and returns 0; returns 1 if the merge
#       was abandoned or the tool reported failure.

function _wrangle_merge_base_get --argument-names file source path
    test -f $file; or return 0
    awk -v s=$source -v p=$path '$1 == s && $2 == p { print $3; exit }' $file
end

function _wrangle_merge_base_set --argument-names file source path sha
    set -l current (_wrangle_merge_base_get $file $source $path)
    test "$current" = "$sha"; and return 1

    if not test -f $file
        printf '%s\n' \
            '# Merge bases for `wrangle merge` (maintained by wrangle; see' \
            '# scripts/_merge_base.fish). One line per source branch and dotfile:' \
            '# the source'"'"'s version as of the last merge from it.' \
            '#' \
            '#   <source-branch> <path> <blob-sha>' > $file
    end
    set -l tmp (mktemp)
    awk -v s=$source -v p=$path '!($1 == s && $2 == p)' $file > $tmp
    echo "$source $path $sha" >> $tmp
    mv $tmp $file
    return 0
end

# The first merge of a file has no recorded base, but git history often has
# one anyway: a version both branches once held, typically because one
# branch copied the file whole from the other (which is exactly what the
# old whole-file adopt did). That version is the right base — everything
# either side changed after it shows as that side's change. Walks only the
# commits that touched <path>, newest first on the source side.
function _wrangle_merge_base_shared --argument-names source path
    set -l ours
    for c in (git log --format=%H HEAD -- $path 2>/dev/null)
        set -l b (git rev-parse --verify -q "$c:$path" 2>/dev/null); or continue
        contains -- $b $ours; or set -a ours $b
    end
    test (count $ours) -gt 0; or return 0
    for c in (git log --format=%H $source -- $path 2>/dev/null)
        set -l b (git rev-parse --verify -q "$c:$path" 2>/dev/null); or continue
        if contains -- $b $ours
            echo $b
            return 0
        end
    end
end

function _wrangle_mergetool --argument-names base mine theirs path out
    set -l t (mktemp -d)
    # A throwaway repo: no hooks, no signing, an identity that needn't exist.
    set -l g git -C $t -c core.hooksPath=/dev/null -c commit.gpgsign=false \
        -c user.name=wrangle -c user.email=wrangle@localhost
    $g init -q
    $g commit -q --allow-empty -m wrangle-merge

    # Same path as in the repo, so the tool's titles and syntax highlighting
    # match the real file.
    mkdir -p (dirname $t/$path)
    set -l info
    if test -n "$base"
        set -a info "100644 "($g hash-object -w -- $base)" 1	$path"
    end
    set -a info "100644 "($g hash-object -w -- $mine)" 2	$path"
    set -a info "100644 "($g hash-object -w -- $theirs)" 3	$path"
    printf '%s\n' $info | $g update-index --index-info

    # The working copy starts as git leaves it in a real conflict: merged
    # where it can be, conflict markers where it can't. Tools that edit the
    # merged file in place (vimdiff and friends) start from that.
    set -l base_file $base
    if test -z "$base_file"
        set base_file $t/.wrangle-empty-base
        touch $base_file
    end
    git merge-file -p --diff3 -L mine -L base -L source -- $mine $base_file $theirs > $t/$path

    $g mergetool -y -- $path
    set -l rv $status

    # Resolved only if the tool succeeded AND git staged the result. A tool
    # that exits 0 without trustExitCode is confirmed by git's own prompt.
    set -l unmerged ($g ls-files -u -- $path)
    if test $rv -eq 0; and test (count $unmerged) -eq 0
        cp $t/$path $out
        rm -rf $t
        return 0
    end
    rm -rf $t
    return 1
end
