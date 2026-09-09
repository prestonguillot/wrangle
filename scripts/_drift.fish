# _drift.fish — drift detection across the four tracked domains: dotfiles,
# fisher plugins, universal variables, and brew. Sourced by scripts/wrangle
# (and by test/*.fish, which source it directly). Don't run directly.
#
# WHY THIS IS A FUNCTION AND NOT INLINE IN scripts/wrangle
#
# `wrangle status` needs drift detection without the rest of the sync
# pipeline. Every other reusable piece of sync was already extracted for
# exactly this reason — _wrangle_update for `wrangle update`,
# _wrangle_do_push for `wrangle push` — but the drift passes never were.
# So status re-exec'd `wrangle sync --dry-run --no-branch-switch` as a
# subprocess and used a user-facing flag as an internal mute switch. That
# leaked sync's Pass 1 header into status output as an empty section, and
# left status read-only only by virtue of scattered $_dry_run gates rather
# than by structure. Extracting the passes removes the subprocess, the
# borrowed flag, and the leak together.
#
# CONTRACT
#
# _wrangle_detect_drift <mode>, following the _wrangle_do_push precedent of
# naming the behavior rather than reading an ambient flag:
#
#   report        detect and print; never prompt, never write.
#                 `wrangle status` and `wrangle sync --dry-run`.
#   interactive   prompt per item and apply what the user chooses.
#                 `wrangle sync`.
#
# The distinction used to ride on the global $_dry_run, which meant two
# different things depending on who was calling: "show me what you'd do"
# for `sync --dry-run`, but "you are not sync, do not mutate" on the status
# path. Naming the mode gives each caller one contract to declare.
#
# Also reads these globals, set by the caller before invocation:
#   $repo $home_subdir $ignore_file $brew_ignore_file   (paths)
#   $_force $_verbose                                    (user flags)
# Appends one line per user-visible change to $_changes, via _log_change.
# Depends on the palette/spinner helpers and the _skiplist / _univ_parse /
# _univ_helpers parsers, all defined in scripts/wrangle before this is
# sourced. Everything else below is local to the function.
#
# Passes 2-4 (yoink, orphan symlinks, re-stow) deliberately stay in
# scripts/wrangle: they are wholly gated on `$_dry_run = no` and print
# nothing in report mode, so keeping them out here means status cannot
# reach them at all — no gate required.

function _wrangle_detect_drift --argument-names mode
    # Reject an unknown or missing mode loudly. Every gate below tests for
    # `report`, so an empty or misspelled $mode would fall through to the
    # prompting-and-writing branches — the one failure this unit must never
    # have. Fail closed instead.
    if test "$mode" != report; and test "$mode" != interactive
        echo "$GLYPH_ERR _wrangle_detect_drift: unknown mode '$mode' (expected 'report' or 'interactive')" >&2
        return 2
    end

    # Skiplist + univ-var parsers are sourced from scripts/_*.fish at the top.
    # `--force` bypasses .dotignore entirely (the pre-commit secret-scan is the
    # secondary safety net).

    set -l user_ignores
    if test "$_force" = no
        set user_ignores (_wrangle_load_dotignore $ignore_file)
    end

    function _is_skipped --inherit-variable user_ignores
        _wrangle_is_skipped $argv[1] $user_ignores
    end

    function _is_tracked --inherit-variable home_subdir
        test -e $home_subdir/$argv[1]
    end

    function _show
        set -l rel $argv[1]
        set -l full $HOME/$rel
        echo ""
        # Subheader (2sp indent, light rules) — visually nests this block under
        # its parent section header. Body content sits one more level in (4sp).
        _subheader "~/$rel"
        if test -d $full
            set -l n (find $full -type f 2>/dev/null | count)
            set -l sz (du -sh $full 2>/dev/null | awk '{print $1}')
            echo "    directory $GLYPH_DIM $n file(s) · $sz"
            echo "    tree (depth 2):"
            find $full -maxdepth 2 2>/dev/null | head -15 | sed "s|$HOME/|      ~/|"
        else if test -f $full
            set -l sz (du -h $full 2>/dev/null | awk '{print $1}')
            set -l mt (stat -f '%Sm' $full)
            echo "    file $GLYPH_DIM $sz · $mt"
            echo "    preview:"
            head -8 $full 2>/dev/null | sed 's/^/      /'
        else
            echo "    (special / unreadable)"
        end
        echo ""
    end

    # Move a path into home/ and let stow link it back. Transactional: every
    # check that can refuse runs BEFORE the mv, and a stow failure undoes the
    # mv rather than leaving the path stranded in the repo.
    #
    # Return codes matter to the caller:
    #   0  tracked
    #   1  refused or rolled back — nothing moved, safe to continue
    #   2  moved but NOT restored — the user must intervene
    #
    # The previous version ended both branches of its if/else in `echo`, so it
    # always returned 0. A stow failure was still counted as a track, still
    # logged as a change, and still fed to the changelog and commit passes —
    # which is how a run that broke a home directory reported "4 tracked".
    function _track --inherit-variable home_subdir --inherit-variable repo
        set -l rel $argv[1]
        set -l src $HOME/$rel
        set -l dest $home_subdir/$rel

        # Refuse before mutating. The enumeration already filters these out;
        # this is here because _track has to be safe for any caller, not
        # because the check is expected to fire.
        set -l hazards (_wrangle_stow_hazards $src)
        if test (count $hazards) -gt 0
            echo "      $GLYPH_ERR cannot track "(_name "~/$rel")" — stow cannot manage it:"
            _wrangle_stow_hazard_report "        " $hazards
            return 1
        end

        # mv onto an existing path either clobbers a file or, for a directory,
        # buries the source inside it as home/<rel>/<basename>.
        if test -e $dest; or test -L $dest
            echo "      $GLYPH_ERR cannot track "(_name "~/$rel")" — "(_name "home/$rel")" already exists."
            echo "        Nothing was moved. Resolve that path in the repo, then re-run."
            return 1
        end

        mkdir -p (dirname $dest)
        mv $src $dest
        or begin
            echo "      $GLYPH_ERR mv failed; nothing was moved"
            return 1
        end

        if _wrangle_stow_run "Re-stowing after track…" $repo
            echo "      $GLYPH_OK moved to home/$rel + symlinked back to ~/$rel"
            return 0
        end

        # stow collects conflicts during planning and aborts before touching
        # the filesystem, so the mv above is the only thing to undo.
        set -l stow_err $_wrangle_stow_err
        if not mv $dest $src
            echo ""
            echo "$GLYPH_ERR STOW FAILED AND ROLLBACK FAILED — MANUAL RECOVERY NEEDED:"
            echo "    "(_name "~/$rel")" is now at"
            echo "      "(_name $dest)
            echo "    and is NOT present at "(_name $src)
            echo ""
            echo "  Restore it by hand:"
            echo "    mv '$dest' '$src'"
            return 2
        end

        # The mv is undone. If home/ still won't stow, the package was already
        # broken before this track — a different problem with a different fix,
        # and worth saying so rather than blaming the path the user just picked.
        set -l pre_existing no
        _wrangle_stow_run "Checking home/ after rollback…" $repo
        or set pre_existing yes

        echo ""
        echo "$GLYPH_ERR STOW REFUSED — rolled back, nothing was moved:"
        _wrangle_stow_explain_failure "    " $stow_err
        echo ""
        echo "  "(_name "~/$rel")" is back where it was and is unchanged."
        if test "$pre_existing" = yes
            echo "  home/ still would not stow after the rollback, so something already"
            echo "  tracked is the cause, not "(_name "~/$rel")"."
            echo "  Run "(_name "wrangle repair")" to find and fix it."
        else
            echo "  Add it to .dotignore, or fix the path named above, then re-run."
        end
        return 1
    end

    function _add_ignore --inherit-variable ignore_file
        echo $argv[1] >> $ignore_file
        echo "      $GLYPH_OK added to .dotignore"
    end

    # ─── Pass 5: dotfile drift ───────────────────────────────────────────────
    echo ""
    _header "Dotfile drift"
    # Build the scan list. fish has no bracket globs, so the previous
    # `$HOME/.[A-Za-z0-9]*` matched nothing and top-level dotfiles were never
    # scanned at all — even though .dotignore is written almost entirely
    # around them (.aws, .ssh, .gnupg, .bash_history…). `.*` is the working
    # glob (fish already excludes `.` and `..`); the "second character is
    # alphanumeric" rule the old pattern reached for is applied explicitly.
    set -l scan
    for f in $HOME/.*
        string match -qr '^\.[A-Za-z0-9]' -- (string replace -- $HOME/ "" $f); or continue
        set -a scan $f
    end
    for f in $HOME/.config/*
        set -a scan $f
    end

    set -l candidates
    set -l blocked
    for f in $scan
        test -L $f; and continue
        set -l rel (string replace -- $HOME/ "" $f)
        if _is_skipped $rel
            test "$_verbose" = yes; and echo "  $GLYPH_DIM skipping "(_name $rel)" (matches .dotignore)"
            continue
        end
        _is_tracked $rel; and continue
        # The candidate not being a symlink says nothing about what is inside
        # it. The path that broke a user's home directory was a real directory
        # holding an absolute symlink two levels down, which stow refuses —
        # and one such symlink blocks every file in home/, not just its own.
        if test (count (_wrangle_stow_hazards $f)) -gt 0
            set -a blocked $rel
        else
            set -a candidates $rel
        end
    end

    if test (count $candidates) -eq 0; and test (count $blocked) -eq 0
        echo "  $GLYPH_OK no untracked dotfiles in scope"
    else
        set -l mode_hint
        test "$mode" = report; and set mode_hint " (dry run — no prompts)"
        test "$_force" = yes; and set mode_hint "$mode_hint (--force: ignore list bypassed)"
        if test (count $candidates) -gt 0
            echo "  Found "(_n (count $candidates))" untracked path(s)$mode_hint."
        end
        if test (count $blocked) -gt 0
            echo "  Found "(_n (count $blocked))" path(s) stow cannot manage — reported below, not touched."
        end
    end

    set -l tracked_count 0
    set -l ignored_count 0

    # Paths stow cannot manage: reported, never touched. No mv, no stow, and
    # no [t]rack option — offering a choice that cannot work is the bug.
    # [i]gnore and [s]kip remain, so the user can silence it without wrangle
    # ever moving anything out of ~.
    for rel in $blocked
        _show $rel
        echo "    $GLYPH_ERR can't be tracked — stow cannot manage this path"
        _wrangle_stow_hazard_report "      " (_wrangle_stow_hazards $HOME/$rel)
        if test "$mode" = report
            continue
        end
        while true
            read -P (_keys "    [i]gnore forever / [s]kip / [q]uit > ") choice
            switch $choice
                case i I ignore
                    _add_ignore $rel
                    set ignored_count (math $ignored_count + 1)
                    _log_change "ignored dotfile: $rel"
                    break
                case s S skip ''
                    echo "      $GLYPH_DIM skipped (will ask again next run)"
                    break
                case q Q quit
                    _wrangle_abort quit
                case '*'
                    echo "      ? '$choice' — answer i/s/q"
            end
        end
    end

    set -l stow_broken no
    set -l seen 0
    for rel in $candidates
        set seen (math $seen + 1)
        _show $rel
        if test "$mode" = report
            continue
        end
        # Prompt + responses sit at 4sp to nest visually under the _show subheader.
        while true
            read -P (_keys "    [t]rack / [i]gnore forever / [s]kip / [q]uit > ") choice
            switch $choice
                case t T track
                    _track $rel
                    set -l rv $status
                    if test $rv -eq 0
                        set tracked_count (math $tracked_count + 1)
                        _log_change "tracked dotfile: $rel"
                    else if test $rv -eq 2
                        # A path is in the repo and gone from ~. Anything we do
                        # next writes on top of a broken home directory.
                        exit 1
                    else
                        set stow_broken yes
                    end
                    break
                case i I ignore
                    _add_ignore $rel
                    set ignored_count (math $ignored_count + 1)
                    _log_change "ignored dotfile: $rel"
                    break
                case s S skip ''
                    echo "      $GLYPH_DIM skipped (will ask again next run)"
                    break
                case q Q quit
                    _wrangle_abort quit
                case '*'
                    echo "      ? '$choice' — answer t/i/s/q"
            end
        end

        # home/ is one stow package: if it won't stow now, it won't stow for
        # the next path either, and each attempt moves another directory out
        # of ~ before finding that out. That cascade is what turned one bad
        # symlink into three stranded directories.
        if test "$stow_broken" = yes
            set -l left (math (count $candidates) - $seen)
            echo ""
            echo "  $GLYPH_WARN stopping the dotfile pass — home/ will not stow right now."
            if test $left -gt 0
                echo "    "(_n $left)" remaining path(s) were left untouched in ~."
            end
            break
        end
    end

    # Summary: only print a counts line when work actually happened (or in dry-run);
    # otherwise the "no untracked dotfiles" ok-line above already conveys "all good".
    if test "$mode" = report; and test (count $candidates) -gt 0
        echo "  $GLYPH_DIM dry run — "(_n (count $candidates))" untracked path(s) listed, nothing changed"
    else if test $tracked_count -gt 0; or test $ignored_count -gt 0
        echo "  $GLYPH_OK "(_n $tracked_count)" tracked, "(_n $ignored_count)" newly ignored"
    end

    # Catch hand-edits to already-tracked dotfiles under home/ (the symlink-target
    # is the same file, so an edit to ~/.config/foo IS an edit to home/.config/foo).
    # Files covered by later passes (fish_plugins, Brewfile, .univexport/.univignore)
    # are excluded — those passes report their own external changes.
    set -l home_dirty (git -C $repo diff --name-only -- home/ 2>/dev/null | string match -v 'home/.config/fish/fish_plugins')
    if test (count $home_dirty) -gt 0
        echo ""
        echo "  $GLYPH_LEAD tracked file(s) under home/ with uncommitted changes:"
        for f in $home_dirty
            echo "    "(_name $f)
        end
        git -C $repo diff --stat --color=always -- $home_dirty 2>/dev/null | sed 's/^/    /'
        _log_change (count $home_dirty)" tracked dotfile(s) hand-edited under home/"
    end

    # ─── Pass 6: fisher drift ────────────────────────────────────────────────
    echo ""
    _header "Fisher drift"
    set -l plugin_changed no
    if not command -q fish; or not functions -q fisher
        echo "  fisher not installed; skipping."
    else
        set -l fisher_listed (fisher list 2>/dev/null)
        set -l plugins_file_path $HOME/.config/fish/fish_plugins
        set -l plugins_in_file
        if test -f $plugins_file_path
            set plugins_in_file (cat $plugins_file_path | grep -v '^#' | grep -v '^$')
        end

        # `.fisherignore`: exact plugin identifiers the user has told us never to
        # nag about. Parsed by the shared loader (comment + blank-line stripping
        # is what we need; matching is exact via `contains --`, not glob). `--force`
        # bypasses, same as `.dotignore`.
        set -l fisher_ignore_file $repo/.fisherignore
        set -l fisher_ignores
        if test "$_force" = no
            set fisher_ignores (_wrangle_load_dotignore $fisher_ignore_file)
        end

        set -l plugin_added
        for p in $fisher_listed
            contains -- $p $plugins_in_file; and continue
            if contains -- $p $fisher_ignores
                test "$_verbose" = yes; and echo "  $GLYPH_DIM skipping "(_name $p)" (matches .fisherignore)"
                continue
            end
            set -a plugin_added $p
        end
        set -l plugin_missing
        for p in $plugins_in_file
            contains -- $p $fisher_listed; and continue
            if contains -- $p $fisher_ignores
                test "$_verbose" = yes; and echo "  $GLYPH_DIM skipping "(_name $p)" (matches .fisherignore)"
                continue
            end
            set -a plugin_missing $p
        end

        if test (count $plugin_added) -eq 0; and test (count $plugin_missing) -eq 0
            echo "  $GLYPH_OK fisher list matches fish_plugins."
        end

        set -l fish_tracked 0
        set -l fish_ignored 0
        set -l fish_installed 0
        set -l fish_removed 0

        if test (count $plugin_added) -gt 0
            echo "  Installed but NOT in fish_plugins ("(_n (count $plugin_added))"):"
            for plugin in $plugin_added
                echo ""
                echo "    "(_name $plugin)
                if test "$mode" = report
                    continue
                end
                while true
                    read -P (_keys "    [t]rack (add to fish_plugins) / [i]gnore (never ask again) / [s]kip / [q]uit > ") choice
                    switch $choice
                        case t T track
                            echo $plugin >> $plugins_file_path
                            set plugin_changed yes
                            set fish_tracked (math $fish_tracked + 1)
                            _log_change "tracked fisher plugin: $plugin"
                            echo "      $GLYPH_OK added to fish_plugins"
                            break
                        case i I ignore
                            echo $plugin >> $fisher_ignore_file
                            set fish_ignored (math $fish_ignored + 1)
                            _log_change "ignored fisher plugin (added to .fisherignore): $plugin"
                            echo "      $GLYPH_OK added to .fisherignore"
                            break
                        case s S skip ''
                            echo "      $GLYPH_DIM skipped"
                            break
                        case q Q quit
                            _wrangle_abort quit
                        case '*'
                            echo "      ? '$choice' — answer t/i/s/q"
                    end
                end
            end
        end

        if test (count $plugin_missing) -gt 0
            echo ""
            echo "  In fish_plugins but NOT installed ("(_n (count $plugin_missing))"):"
            for plugin in $plugin_missing
                echo ""
                echo "    "(_name $plugin)
                if test "$mode" = report
                    continue
                end
                while true
                    read -P (_keys "    [i]nstall / [r]emove from fish_plugins / [s]kip / [q]uit > ") choice
                    switch $choice
                        case i I install
                            _with_spinner "fisher install $plugin…" fish -c "fisher install $plugin"
                            set fish_installed (math $fish_installed + 1)
                            _log_change "installed fisher plugin: $plugin"
                            echo "      $GLYPH_OK installed"
                            break
                        case r R remove
                            set -l tmp_p (mktemp)
                            grep -v -F -x -- "$plugin" $plugins_file_path > $tmp_p
                            mv $tmp_p $plugins_file_path
                            set plugin_changed yes
                            set fish_removed (math $fish_removed + 1)
                            _log_change "removed fisher plugin from fish_plugins: $plugin"
                            echo "      $GLYPH_OK removed from fish_plugins"
                            break
                        case s S skip ''
                            break
                        case q Q quit
                            _wrangle_abort quit
                        case '*'
                            echo "      ? '$choice' — answer i/r/s/q"
                    end
                end
            end
        end

        # Catch fish_plugins / .fisherignore modifications that didn't surface
        # through the drift check above — e.g. a `fisher install foo` (in or out
        # of wrangle) added `foo` to the file before this pass ran, so
        # installed-vs-file matches but the file is still dirty relative to its
        # last commit; or the user hand-edited .fisherignore.
        _report_external_changes "fish_plugins / .fisherignore has uncommitted changes" home/.config/fish/fish_plugins .fisherignore

        # Summary: only if any work happened. Otherwise the "fisher list matches
        # fish_plugins" ok-line above is the summary.
        if test (math $fish_tracked + $fish_ignored + $fish_installed + $fish_removed) -gt 0
            echo "  $GLYPH_OK "(_n $fish_tracked)" tracked, "(_n $fish_ignored)" ignored, "(_n $fish_installed)" installed, "(_n $fish_removed)" removed from fish_plugins"
        end
    end

    # ─── Pass 7: univ-var drift ──────────────────────────────────────────────
    # Tracks plugin universal variables (tide config, sponge config, etc.) so
    # they survive `git clone` + bootstrap on a new machine. Necessary evil:
    # fish universals are controversial upstream (#7379) but plugins like tide
    # make them their SOLE persistence mechanism. Scope is intentionally narrow
    # — see .univexport for the allowlist and the doc comments there.
    #
    # Two sub-passes, matching fisher/brew's two-direction shape:
    #
    #  A. IMPORT (repo file → live shell):
    #     - parse home/.config/fish/exported-univ-vars.fish for tracked names+values
    #     - filter by .univexport (only currently-tracked vars) + .univignore
    #     - missing on machine    → silent apply (dotfile-stow precedent)
    #     - same value live       → no-op
    #     - different value live  → prompt [a]pply / [k]eep local / [s]kip / [q]uit
    #
    #  B. CAPTURE (live shell → repo file):
    #     - group installed univs by prefix
    #     - filter by .univexport (already tracked) + .univignore (already ignored)
    #     - prompt [t]rack / [i]gnore forever / [s]kip / [q]uit per remaining group
    #     - on track: append pattern to .univexport, regenerate exported-univ-vars.fish
    #
    # Import runs first so the capture pass sees the post-import live state;
    # this means `[k]eep local` on a conflict naturally resolves itself when
    # capture regenerates the file with your live value.
    echo ""
    _header "Univ-var drift"

    set -l univ_export_file $repo/.univexport
    set -l univ_ignore_file $repo/.univignore
    set -l univ_output_file $repo/home/.config/fish/exported-univ-vars.fish
    set -l univ_changed no

    # `_univ_prefix` lives in scripts/_univ_helpers.fish (sourced at the top of
    # this script). Sister to scripts/_univ_parse.fish (the export-file parser).

    # Helper: regenerate $univ_output_file from current state + .univexport patterns.
    function _univ_regenerate --inherit-variable univ_export_file --inherit-variable univ_output_file
        set -l patterns
        if test -f $univ_export_file
            set patterns (grep -vE '^\s*(#|$)' $univ_export_file)
        end
        if test (count $patterns) -eq 0
            # Nothing tracked — make sure output file doesn't linger from a previous state.
            rm -f $univ_output_file
            return
        end
        mkdir -p (dirname $univ_output_file)
        set -l tmp (mktemp)
        echo "# Auto-generated by wrangle. Edit .univexport (allowlist) and re-run wrangle." > $tmp
        echo "# Restored automatically by `wrangle sync` (import sub-pass of Pass 7)." >> $tmp
        echo "" >> $tmp
        for name in (set -U -L | awk '{print $1}' | sort)
            set -l matched no
            for p in $patterns
                if string match -q $p $name
                    set matched yes
                    break
                end
            end
            test "$matched" = yes; or continue
            # Read the var's values via dereference.
            set -l values $$name
            # Skip empty.
            test (count $values) -eq 0; and continue
            echo "set -U --erase $name" >> $tmp
            printf 'set -U %s' $name >> $tmp
            for v in $values
                printf ' %s' (string escape -- $v) >> $tmp
            end
            printf '\n' >> $tmp
        end
        mv $tmp $univ_output_file
    end

    # Load allowlist / blocklist patterns once — shared by both sub-passes
    # (skip comments + blanks).
    set -l allowed_patterns
    set -l ignored_patterns
    if test -f $univ_export_file
        set allowed_patterns (grep -vE '^\s*(#|$)' $univ_export_file)
    end
    if test -f $univ_ignore_file
        set ignored_patterns (grep -vE '^\s*(#|$)' $univ_ignore_file)
    end

    # ─── Sub-pass A: import (repo file → live shell) ─────────────────────────
    # Read tracked names + values from exported-univ-vars.fish, compare to live.
    # Missing on machine: silent apply (matches dotfile-stow precedent — no
    # conflict, no prompt). Different value: per-var [a/k/s/q] prompt.
    set -l univ_applied 0
    set -l univ_kept_local 0
    set -l univ_conflict_skipped 0

    if test -f $univ_output_file
        set -l import_names (_wrangle_univ_parse_names $univ_output_file)

        set -l conflicts
        set -l missing

        for name in $import_names
            # Only consider currently-tracked vars (filter by .univexport).
            set -l in_allowlist no
            for p in $allowed_patterns
                string match -q $p $name; and set in_allowlist yes; and break
            end
            test "$in_allowlist" = yes; or continue

            # Defense: skip if in .univignore (shouldn't happen for an exported
            # var, but covers hand-edits).
            set -l in_blocklist no
            for p in $ignored_patterns
                string match -q $p $name; and set in_blocklist yes; and break
            end
            test "$in_blocklist" = yes; and continue

            set -l repo_values (_wrangle_univ_parse_values $univ_output_file $name)
            test (count $repo_values) -eq 0; and continue

            if not set -q $name
                set -a missing $name
                continue
            end
            set -l live_values $$name
            # Structural list-equality: join with RS (\x1e), unlikely in values.
            if test "(string join \x1e $live_values)" = "(string join \x1e $repo_values)"
                continue
            end
            set -a conflicts $name
        end

        if test "$mode" = report
            if test (count $missing) -gt 0
                echo "  $GLYPH_DIM import: "(_n (count $missing))" tracked var(s) missing on machine (would silent-apply):"
                for name in $missing
                    echo "    "(_name $name)
                end
            end
            if test (count $conflicts) -gt 0
                echo "  $GLYPH_DIM import: "(_n (count $conflicts))" tracked var(s) with conflicting values (would prompt):"
                for name in $conflicts
                    set -l repo_values (_wrangle_univ_parse_values $univ_output_file $name)
                    set -l live_values $$name
                    echo ""
                    echo "    "(_name $name)" — value differs:"
                    echo "      live: "(_dim)(string join " " $live_values)(_rs)
                    echo "      repo: "(_dim)(string join " " $repo_values)(_rs)
                end
            end
        else
            # Silent apply for missing-on-machine — dotfile-stow precedent.
            for name in $missing
                set -l vals (_wrangle_univ_parse_values $univ_output_file $name)
                set -U --erase $name 2>/dev/null
                set -U $name $vals
                set univ_applied (math $univ_applied + 1)
                _log_change "applied univ-var from repo: $name"
            end

            # Prompt per conflict.
            for name in $conflicts
                set -l repo_values (_wrangle_univ_parse_values $univ_output_file $name)
                set -l live_values $$name
                echo ""
                echo "    "(_name $name)" — value differs:"
                echo "      live: "(_dim)(string join " " $live_values)(_rs)
                echo "      repo: "(_dim)(string join " " $repo_values)(_rs)
                while true
                    read -P (_keys "    [a]pply repo value (overwrite local) / [k]eep local / [s]kip / [q]uit > ") choice
                    switch $choice
                        case a A apply
                            set -U --erase $name
                            set -U $name $repo_values
                            set univ_applied (math $univ_applied + 1)
                            _log_change "applied univ-var from repo (overwrote local): $name"
                            echo "      $GLYPH_OK applied repo value"
                            break
                        case k K keep
                            set univ_kept_local (math $univ_kept_local + 1)
                            _log_change "kept local univ-var value over repo: $name"
                            echo "      $GLYPH_OK kept local (capture pass will regenerate file)"
                            break
                        case s S skip ''
                            set univ_conflict_skipped (math $univ_conflict_skipped + 1)
                            echo "      $GLYPH_DIM skipped (will ask again next run)"
                            break
                        case q Q quit
                            _wrangle_abort quit
                        case '*'
                            echo "      ? '$choice' — answer a/k/s/q"
                    end
                end
            end

            if test (math $univ_applied + $univ_kept_local + $univ_conflict_skipped) -gt 0
                echo "  $GLYPH_OK import: "(_n $univ_applied)" applied, "(_n $univ_kept_local)" kept-local, "(_n $univ_conflict_skipped)" skipped"
            end
        end
    end

    # ─── Sub-pass B: capture (live shell → repo file) ────────────────────────
    # Detection runs unconditionally; mutating actions (prompts + writes +
    # regenerate) are gated on `$mode` below so report mode still surfaces
    # the auto-skipped count + drift summary.

    # Get all current universals, partition into groups by prefix.
    # We need: list of (prefix → [var names]) for untracked + un-ignored vars.
    set -l drift_prefixes
    set -l drift_standalone
    set -l auto_skipped_private 0

    for name in (set -U -L | awk '{print $1}')
        # Skip if matches any allowlist pattern (already tracked) — silent always,
        # this is the "expected" path (tracked vars don't need re-prompting).
        set -l skip no
        for p in $allowed_patterns
            string match -q $p $name; and set skip yes; and break
        end
        test "$skip" = yes; and continue
        # Skip if matches any ignore pattern (already ignored). Surface under --verbose.
        set -l matched_ignore_pat
        for p in $ignored_patterns
            if string match -q $p $name
                set skip yes; set matched_ignore_pat $p; break
            end
        end
        if test "$skip" = yes
            test "$_verbose" = yes; and echo "  $GLYPH_DIM skipping "(_name $name)" (matches .univignore: $matched_ignore_pat)"
            continue
        end
        # Auto-skip fish's private/internal convention: names starting with `_`
        # (fish builtins use `__name`, plugins use `_pluginname_*` for caches).
        # Explicit allowlist matches above still win, so you can opt in by
        # adding an exact name (e.g. `_foo`) to .univexport manually.
        if string match -q '_*' $name
            set auto_skipped_private (math $auto_skipped_private + 1)
            test "$_verbose" = yes; and echo "  $GLYPH_DIM skipping "(_name $name)" (auto-skip: private/internal `_*` convention)"
            continue
        end

        set -l prefix (_univ_prefix $name)
        if test -z "$prefix"
            set -a drift_standalone $name
        else
            contains -- $prefix $drift_prefixes; or set -a drift_prefixes $prefix
        end
    end

    if test $auto_skipped_private -gt 0
        echo "  $GLYPH_DIM auto-skipped "(_n $auto_skipped_private)" private var(s) (leading _ — fish/plugin internals; add exact name to .univexport to opt in)"
    end

    set -l univ_tracked 0
    set -l univ_ignored 0
    set -l drift_total (math (count $drift_prefixes) + (count $drift_standalone))
    if test $drift_total -eq 0
        echo "  $GLYPH_OK no univ-var drift (allowlist + blocklist cover all)"
    else
        if test "$mode" = report
            echo "  $GLYPH_DIM dry run — "(_n $drift_total)" untracked group(s)/var(s) detected, nothing would change:"
        else
            echo "  Found "(_n $drift_total)" untracked group(s)/var(s)"
        end

        # Enumerate per prefix-group. Print members in both dry-run and real
        # mode; only the prompt is gated.
        for prefix in $drift_prefixes
            set -l members
            for name in (set -U -L | awk '{print $1}')
                set -l np (_univ_prefix $name)
                test "$np" = "$prefix"; or continue
                set -a members $name
            end
            set -l count (count $members)
            echo ""
            echo "    prefix "(_name "$prefix*")" — "(_n $count)" var(s):"
            for m in $members
                echo "      "(_name $m)
            end
            if test "$mode" = report
                continue
            end
            while true
                read -P (_keys "    [t]rack pattern / [i]gnore forever / [s]kip / [q]uit > ") choice
                switch $choice
                    case t T track
                        echo "$prefix*" >> $univ_export_file
                        echo "      $GLYPH_OK added `$prefix*` to .univexport"
                        _log_change "tracked univ-var pattern: $prefix*"
                        set univ_changed yes
                        set univ_tracked (math $univ_tracked + 1)
                        break
                    case i I ignore
                        echo "$prefix*" >> $univ_ignore_file
                        echo "      $GLYPH_OK added `$prefix*` to .univignore"
                        echo "      $GLYPH_DIM tip: to capture an individual var from this prefix later,"
                        echo "      $GLYPH_DIM      add its exact name on its own line in .univexport"
                        echo "      $GLYPH_DIM      ($repo/.univexport — exact names match like patterns)"
                        _log_change "ignored univ-var pattern: $prefix*"
                        set univ_ignored (math $univ_ignored + 1)
                        break
                    case s S skip ''
                        echo "      $GLYPH_DIM skipped (will ask again next run)"
                        break
                    case q Q quit
                        _wrangle_abort quit
                    case '*'
                        echo "      ? '$choice' — answer t/i/s/q"
                end
            end
        end

        # Enumerate per standalone (no-underscore) var. Same gating pattern.
        for name in $drift_standalone
            echo ""
            echo "    standalone (no prefix): "(_name $name)" = "(string join " " $$name)
            if test "$mode" = report
                continue
            end
            while true
                read -P (_keys "    [t]rack exact name / [i]gnore forever / [s]kip / [q]uit > ") choice
                switch $choice
                    case t T track
                        echo $name >> $univ_export_file
                        echo "      $GLYPH_OK added `$name` to .univexport"
                        _log_change "tracked univ-var: $name"
                        set univ_changed yes
                        set univ_tracked (math $univ_tracked + 1)
                        break
                    case i I ignore
                        echo $name >> $univ_ignore_file
                        echo "      $GLYPH_OK added `$name` to .univignore"
                        _log_change "ignored univ-var: $name"
                        set univ_ignored (math $univ_ignored + 1)
                        break
                    case s S skip ''
                        echo "      $GLYPH_DIM skipped (will ask again next run)"
                        break
                    case q Q quit
                        _wrangle_abort quit
                    case '*'
                        echo "      ? '$choice' — answer t/i/s/q"
                end
            end
        end
    end   # closes the if/else for drift status

    # Side-effects (file writes, regenerate, dirty-file report) only when NOT in
    # dry-run. Detection above already ran in both modes.
    if test "$mode" = interactive
        # Regenerate exported file if anything was tracked OR if the file's current
        # contents are stale relative to the live var values.
        if test "$univ_changed" = yes; or test -f $univ_output_file
            _univ_regenerate
        end

        # Catch hand-edits to .univexport / .univignore (e.g. user manually added
        # an exact name to opt-in a normally-auto-skipped private var).
        _report_external_changes ".univexport / .univignore has uncommitted changes" .univexport .univignore

        # Summary: only when work happened (the "no univ-var drift" ok-line above
        # already serves as the no-work summary).
        if test (math $univ_tracked + $univ_ignored) -gt 0
            echo "  $GLYPH_OK "(_n $univ_tracked)" tracked, "(_n $univ_ignored)" newly ignored"
        end
    end

    # ─── Pass 8: brew drift ──────────────────────────────────────────────────
    # Brewfile mutations here are INCREMENTAL: each [t]rack appends one entry,
    # each [r]emove deletes one entry. No end-of-pass re-dump, so [s]kip truly
    # means "defer; ask me again next run." dump-brewfile is still used to
    # DETECT drift (read-only comparison), just not to write back changes.
    echo ""
    _header "Brew drift"
    if not command -q brew
        echo "  brew not installed; skipping."
    else
        set -l tmp_dump (mktemp)
        set -l tmp_dump_stderr (mktemp)
        _spinner_start "Scanning installed brew state…"
        set -l dump_args $tmp_dump
        test "$_verbose" = yes; and set dump_args --verbose $dump_args
        $repo/scripts/dump-brewfile $dump_args 2>$tmp_dump_stderr
        _spinner_stop
        if test "$_verbose" = yes; and test -s $tmp_dump_stderr
            # dump-brewfile --verbose emits one "<line>\t(matches .brewignore: <pat>)"
            # line to stderr per filtered entry. Surface each in our own DIM format.
            while read -l ln
                set -l parts (string split -m 1 \t -- $ln)
                test (count $parts) -eq 2; or continue
                echo "  $GLYPH_DIM skipping "(_name $parts[1])" $parts[2]"
            end < $tmp_dump_stderr
        end
        rm -f $tmp_dump_stderr

        set -l brewfile_path $repo/Brewfile
        set -l tracked_entries
        if test -f $brewfile_path
            set tracked_entries (grep -E '^(brew|cask|mas|npm) ' $brewfile_path)
        end
        set -l installed_entries (grep -E '^(brew|cask|mas|npm) ' $tmp_dump)
        # NOTE: tmp_dump stays alive through the loops — [t]rack reads the
        #       description-comment for the entry out of it. Cleaned up after.

        set -l added
        for e in $installed_entries
            contains -- $e $tracked_entries; or set -a added $e
        end
        set -l missing
        for e in $tracked_entries
            contains -- $e $installed_entries; or set -a missing $e
        end

        set -l brew_tracked 0
        set -l brew_ignored 0
        set -l brew_installed 0
        set -l brew_removed 0

        if test (count $added) -eq 0; and test (count $missing) -eq 0
            echo "  $GLYPH_OK Brewfile matches installed state (with .brewignore applied)."
        end

        # Ensure Brewfile exists so we can append to it (fresh machine, no Brewfile yet).
        if test "$mode" = interactive; and not test -f $brewfile_path
            touch $brewfile_path
        end

        if test (count $added) -gt 0
            echo "  Installed locally but NOT in Brewfile ("(count $added)"):"
            for entry in $added
                echo ""
                echo "    $entry"
                if test "$mode" = report
                    continue
                end
                while true
                    read -P (_keys "    [t]rack / [i]gnore forever / [s]kip / [q]uit > ") choice
                    switch $choice
                        case t T track
                            # Look up the description comment from tmp_dump (the
                            # line immediately preceding $entry, if it's a comment).
                            set -l ln_raw (grep -n -F -x -- "$entry" $tmp_dump 2>/dev/null | head -1)
                            set -l desc ""
                            if test -n "$ln_raw"
                                set -l ln (string split ':' -- $ln_raw)[1]
                                if test "$ln" -gt 1
                                    set -l prev_line (sed -n (math $ln - 1)"p" $tmp_dump)
                                    if string match -q '#*' -- "$prev_line"
                                        set desc $prev_line
                                    end
                                end
                            end
                            if test -n "$desc"
                                echo $desc >> $brewfile_path
                            end
                            echo $entry >> $brewfile_path
                            set brew_tracked (math $brew_tracked + 1)
                            _log_change "tracked brew: $entry"
                            echo "      $GLYPH_OK appended to Brewfile"
                            break
                        case i I ignore
                            set -l pat (string match -r '"[^"]+"' -- $entry)[1]
                            if test -z "$pat"
                                set pat $entry
                            end
                            echo $pat >> $brew_ignore_file
                            echo "      $GLYPH_OK added $pat to .brewignore"
                            set brew_ignored (math $brew_ignored + 1)
                            _log_change "brew-ignored: $pat"
                            break
                        case s S skip ''
                            echo "      $GLYPH_DIM skipped (will ask again next run)"
                            break
                        case q Q quit
                            _wrangle_abort quit
                        case '*'
                            echo "      ? '$choice' — answer t/i/s/q"
                    end
                end
            end
        end

        if test (count $missing) -gt 0
            echo ""
            echo "  In Brewfile but NOT installed ("(count $missing)"):"
            for entry in $missing
                echo ""
                echo "    $entry"
                if test "$mode" = report
                    continue
                end
                while true
                    read -P (_keys "    [i]nstall / [r]emove from Brewfile / [s]kip / [q]uit > ") choice
                    switch $choice
                        case i I install
                            set -l type (string split ' ' -- $entry)[1]
                            set -l name (string match -r '"[^"]+"' -- $entry)[1]
                            set -l name_unquoted (string trim --chars='"' -- $name)
                            set -l rv 0
                            switch $type
                                case brew
                                    _with_spinner "brew install $name_unquoted…" brew install $name_unquoted
                                    set rv $status
                                case cask
                                    _with_spinner "brew install --cask $name_unquoted…" brew install --cask $name_unquoted
                                    set rv $status
                                case mas
                                    set -l id (string match -r 'id:\s*(\d+)' -- $entry)[2]
                                    _with_spinner "mas install $name_unquoted ($id)…" mas install $id
                                    set rv $status
                                case npm
                                    _with_spinner "npm install -g $name_unquoted…" npm install -g $name_unquoted
                                    set rv $status
                            end
                            if test $rv -eq 0
                                echo "      $GLYPH_OK installed"
                                set brew_installed (math $brew_installed + 1)
                                _log_change "installed: $entry"
                            else
                                echo "      $GLYPH_WARN install failed (exit $rv)"
                            end
                            break
                        case r R remove
                            # Locate the entry's line in Brewfile, delete it +
                            # preceding description comment if present.
                            set -l ln_raw (grep -n -F -x -- "$entry" $brewfile_path 2>/dev/null | head -1)
                            if test -z "$ln_raw"
                                echo "      $GLYPH_WARN couldn't find that line in Brewfile; nothing removed"
                                break
                            end
                            set -l ln (string split ':' -- $ln_raw)[1]
                            set -l to_delete $ln
                            if test "$ln" -gt 1
                                set -l prev_line (sed -n (math $ln - 1)"p" $brewfile_path)
                                if string match -q '#*' -- "$prev_line"
                                    set to_delete (math $ln - 1)","$ln
                                end
                            end
                            set -l tmp_bf (mktemp)
                            sed "$to_delete""d" $brewfile_path > $tmp_bf
                            mv $tmp_bf $brewfile_path
                            set brew_removed (math $brew_removed + 1)
                            _log_change "removed from Brewfile: $entry"
                            echo "      $GLYPH_OK removed from Brewfile"
                            break
                        case s S skip ''
                            echo "      $GLYPH_DIM skipped (will ask again next run)"
                            break
                        case q Q quit
                            _wrangle_abort quit
                        case '*'
                            echo "      ? '$choice' — answer i/r/s/q"
                    end
                end
            end
        end

        rm -f $tmp_dump

        # Catch Brewfile/.brewignore modifications that didn't surface through
        # drift — file was edited (hand or by dump-brewfile) but is now in sync
        # with the installed state.
        _report_external_changes "Brewfile / .brewignore has uncommitted changes" Brewfile .brewignore

        # Summary: parallel to the other passes — only counts line when work
        # happened; the "Brewfile matches installed state" ok-line above is the
        # no-work summary.
        if test "$mode" = report; and test (math (count $added) + (count $missing)) -gt 0
            echo "  $GLYPH_DIM dry run — "(_n (count $added))" untracked, "(_n (count $missing))" missing, nothing changed"
        else if test (math $brew_tracked + $brew_ignored + $brew_installed + $brew_removed) -gt 0
            echo "  $GLYPH_OK "(_n $brew_tracked)" tracked, "(_n $brew_ignored)" ignored, "(_n $brew_installed)" installed, "(_n $brew_removed)" removed"
        end
    end
end
