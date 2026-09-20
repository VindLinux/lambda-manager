#!/bin/sh

# Prints the dependency tree of $1 below the prefix $2. A package that was already printed is
# marked with (*) and not expanded again.
# globals: TREE_SEEN, TREE_REPEATS
_deps_tree()
{
    local package="$1" prefix="$2" dependencies="" dependency="" count=0 i=0 connector="" child_prefix=""

    dependencies=$(direct_deps "$package")

    for dependency in $dependencies; do
        count=$((count + 1))
    done

    for dependency in $dependencies; do
        i=$((i + 1))

        if [ "$i" -eq "$count" ]; then
            connector="└── "
            child_prefix="$prefix    "
        else
            connector="├── "
            child_prefix="$prefix│   "
        fi

        if in_list "$dependency" "$TREE_SEEN"; then
            TREE_REPEATS=$((TREE_REPEATS + 1))
            printf '%s%s%s (*)\n' "$prefix" "$connector" "$dependency"
        else
            TREE_SEEN="$TREE_SEEN$NL$dependency"
            printf '%s%s%s\n' "$prefix" "$connector" "$dependency"
            _deps_tree "$dependency" "$child_prefix"
        fi
    done
}

# deps <package>: dependency tree + install order (topological), fails on circular dependencies
deps()
{
    local package="$1" count=0

    if [ "$#" -ne 1 ]; then
        echo "lambda: deps requires exactly one package"
        return 1
    fi

    if [ ! -d "$PKG_DB/$package" ]; then
        echo "lambda: package not found: $package"
        return 1
    fi

    lambda_load_conf

    resolve_deps "$package"
    report_resolve_errors || return 1

    echo "[ $package ]"
    echo ""
    echo "Dependency tree:"
    echo "$package"

    TREE_SEEN="$package"
    TREE_REPEATS=0
    _deps_tree "$package" ""

    if [ "$TREE_REPEATS" -gt 0 ]; then
        echo ""
        echo "(*) already listed above"
    fi

    echo ""
    echo "Install order:"
    printf '%s\n' "$RESOLVED" | tr '\n' ' ' | sed 's/ $//'
    echo ""

    set -- $RESOLVED
    count=$(($# - 1))

    echo ""
    printf '%s dependencies\n' "$count"
}
