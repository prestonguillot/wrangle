function _tide_item_sbt
    set -l root
    for dir in $_tide_parent_dirs[-1..1]
        test -f "$dir/build.sbt"; and set root $dir; and break
    end
    test -n "$root"; or return

    set -l parts

    set -l props_file "$root/project/build.properties"
    if test -f "$props_file"
        set -l sbt_ver (string match -rg 'sbt\.version\s*=\s*(\S+)' < "$props_file")
        test -n "$sbt_ver"; and set -a parts "sbt $sbt_ver"
    end

    set -l build_file "$root/build.sbt"
    set -l scala_ver (string match -rg 'scalaVersion\s*:=\s*"([^"]+)"' < "$build_file")
    test -n "$scala_ver"; and set -a parts "scala $scala_ver"

    if type -q java
        set -l java_ver (java -version 2>&1 | string match -rg '"([^"]+)"')
        test -n "$java_ver"; and set -a parts "jdk $java_ver"
    end

    test (count $parts) -gt 0; or return

    set -q tide_sbt_icon; or set -U tide_sbt_icon λ
    set -q tide_sbt_color; or set -U tide_sbt_color white
    set -q tide_sbt_bg_color; or set -U tide_sbt_bg_color red

    _tide_print_item sbt $tide_sbt_icon' ' (string join ' · ' $parts)
end
