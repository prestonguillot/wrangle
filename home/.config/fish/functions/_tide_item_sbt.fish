# Custom tide prompt item for sbt (Scala) projects. Listed in
# tide_right_prompt_items; tide calls _tide_item_<name> for each item, and
# ships no sbt item of its own. Same shape as tide's built-in language items
# (_tide_item_java, _tide_item_rustc).
#
# Shows only inside an sbt project (a build.sbt in this or a parent dir).
# The version comes from project/build.properties rather than `sbt --version`,
# which starts a JVM — far too slow to run on every prompt.
function _tide_item_sbt
    for dir in $_tide_parent_dirs
        test -f $dir/build.sbt; or continue
        set -l v
        if test -f $dir/project/build.properties
            set v (string match -rg '^\s*sbt\.version\s*=\s*(\S+)' < $dir/project/build.properties)
        end
        _tide_print_item sbt $tide_sbt_icon' ' $v
        return
    end
end
