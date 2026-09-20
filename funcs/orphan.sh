#!/bin/sh

# Finds the orphaned packages: installed only as a dependency (reason != explicit) and not
# needed, directly or not, by anything that is wanted. Wanted means:
#   - the system file, and
#   - packages installed explicitly, even if already purged from the system file: they only
#     leave with the next reconcile, and their dependencies must survive until then.
# Sets ORPHANS (newline separated, in removal order: dependents first).
orphan_scan()
{
    local roots="" installed="" package=""
    ORPHANS=""

    installed=$(installed_packages)
    roots=$(system_packages)

    for package in $installed; do
        if [ "$(installed_reason "$package")" = "explicit" ] && ! in_list "$package" "$roots"; then
            roots="${roots:+$roots$NL}$package"
        fi
    done

    RESOLVE_ROOT_LABEL="the system file or an explicitly installed package"
    resolve_deps $roots
    report_resolve_errors || return 1

    for package in $installed; do
        if ! in_list "$package" "$RESOLVED"; then
            ORPHANS="${ORPHANS:+$ORPHANS$NL}$package"
        fi
    done

    if [ -n "$ORPHANS" ]; then
        ORPHANS=$(removal_order "$ORPHANS")
    fi

    return 0
}

orphan()
{
    local package="" answer=""

    lambda_require_root || return 1
    lambda_load_conf

    orphan_scan || return 1

    if [ -z "$ORPHANS" ]; then
        echo "lambda: no orphaned packages"
        return 0
    fi

    echo "Orphaned packages:"
    for package in $ORPHANS; do
        echo "  $package"
    done

    printf '\nRemove all orphaned packages? [y/N] '
    read -r answer
    case "$answer" in
        y|Y|yes|YES) ;;
        *) return 0 ;;
    esac

    for package in $ORPHANS; do
        lambda_remove "$package" || return $?
    done
}
