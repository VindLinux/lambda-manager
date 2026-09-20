#!/bin/sh

_plan_header()
{
    echo "packages to reconcile: "
    echo ""
    printf '%-15s %-12s %-22s %s\n' "PACKAGE" "ACTION" "VERSION" "ATTRS"
}

_printf_action_version()
{
    if [ "$1" = "purge" ]; then
        printf '%b%-12s%b ' "${RED}" "$1" "${RESET}"
    elif [ "$1" = "rebuild" ]; then
        printf '%b%-12s%b ' "${YELLOW}" "$1" "${RESET}"
    else
        printf '%b%-12s%b ' "${GREEN}" "$1" "${RESET}"
    fi

    printf '%b%-22s%b ' "${CYAN}" "$2" "${RESET}"
}

# prints attrs colored: enabled in green, disabled (-attr) in red.
# "-" alone means "no attrs" and is not colored
_printf_attrs()
{
    local attr=""

    if [ -z "$1" ] || [ "$1" = "-" ]; then
        printf '%s' "-"
        return 0
    fi

    for attr in $1; do
        case "$attr" in
            -*) printf '%b ' "${RED}$attr${RESET}" ;;
            *) printf '%b ' "${GREEN}$attr${RESET}" ;;
        esac
    done
}

# after reconcile: tell the user if there is something for `lambda orphan`
_orphan_hint()
{
    local count=0

    orphan_scan >/dev/null 2>&1 || return 0

    if [ -n "$ORPHANS" ]; then
        set -- $ORPHANS
        count=$#
        echo ""
        echo "lambda: $count orphaned package(s), run 'lambda orphan' to review them"
    fi
}

# Brings the installed system to the desired state (the system file):
#   install   packages that are wanted (system file + their dependencies) and not installed
#   upgrade   installed, but the recipe has another version
#   rebuild   installed, but the enabled COMP_ATTRS are not the ones it was built with
#   remove    packages purged from the system file (installed explicitly, no longer wanted by anyone)
# Orphaned dependencies are NOT removed here, that is what `lambda orphan` is for.
reconcile()
{
    local system="" installed="" wanted="" plan="" purge="" shown=0 deps_only=""
    local package="" action="" reason="" old_version="" new_version="" new_attrs="" version="" attrs=""
    local plan_packages="" dep_count=0 count=0 dep="" answer="" trigger=""

    lambda_require_root || return 1
    lambda_load_conf

    system=$(system_packages)
    installed=$(installed_packages)

    # everything the system file needs, directly or not: dependencies first
    RESOLVE_ROOT_LABEL="the system file"
    resolve_deps $system
    report_resolve_errors || return 1
    wanted="$RESOLVED"

    # Bookkeeping of why each package is installed (installed/<pkg>/reason)
    for package in $installed; do
        reason=$(installed_reason "$package")

        if in_list "$package" "$system"; then
            if [ "$reason" != "explicit" ]; then
                set_reason "$package" "explicit"
            fi
        elif [ -z "$reason" ]; then
            # installed by an older Lambda: not asked for, so it is a dependency
            set_reason "$package" "dependency"
        elif [ "$reason" = "explicit" ] && in_list "$package" "$wanted"; then
            # purged from the system file but something else needs it: it stays as a dependency
            set_reason "$package" "dependency"
        fi

        # installed by an older Lambda: assume it matches the current recipe
        if [ ! -f "$INST_DB/$package/version" ] && [ -f "$PKG_DB/$package/version" ]; then
            cp "$PKG_DB/$package/version" "$INST_DB/$package/version"
        fi
    done

    # What to install/upgrade/rebuild, dependencies first
    for package in $wanted; do
        if ! in_list "$package" "$installed"; then
            plan="${plan:+$plan$NL}$package install"
            continue
        fi

        old_version=$(read_first "$INST_DB/$package/version")
        new_version=$(read_first "$PKG_DB/$package/version")
        new_attrs=$(resolve_comp_attrs "$package")

        if [ "$old_version" != "$new_version" ]; then
            action="upgrade"
        elif [ "$(attrs_enabled "$(read_first "$INST_DB/$package/compattrs")")" != "$(attrs_enabled "$new_attrs")" ]; then
            action="rebuild"
        else
            continue
        fi

        plan="${plan:+$plan$NL}$package $action"
    done

    # What to remove: installed explicitly, not in the system file (and not needed by anyone,
    # otherwise the bookkeeping above turned it into a dependency)
    for package in $installed; do
        if [ "$(installed_reason "$package")" = "explicit" ] && ! in_list "$package" "$system"; then
            purge="${purge:+$purge$NL}$package"
        fi
    done

    if [ -z "$plan" ] && [ -z "$purge" ]; then
        echo "lambda: nothing to reconcile"
        _orphan_hint
        return 0
    fi

    # Shows what is going to happen. Packages that are only installed because something else
    # needs them are listed apart, below.

    while read -r package action; do
        [ -n "$package" ] || continue

        if [ "$action" = "install" ] && ! in_list "$package" "$system"; then
            continue
        fi

        new_version=$(read_first "$PKG_DB/$package/version")
        new_attrs=$(resolve_comp_attrs "$package")
        version="${new_version:--}"
        attrs="${new_attrs:--}"
        trigger=""

        if [ "$action" = "upgrade" ]; then
            old_version=$(read_first "$INST_DB/$package/version")
            version="${old_version:--} -> ${new_version:--}"
        elif [ "$action" = "rebuild" ]; then
            trigger=$(attrs_diff "$(read_first "$INST_DB/$package/compattrs")" "$new_attrs")
        fi

        if [ "$shown" -eq 0 ]; then
            _plan_header
            shown=1
        fi

        printf '%-15s ' "$package"
        _printf_action_version "$action" "$version"
        _printf_attrs "$attrs"

        # what made the rebuild necessary, in a single color
        if [ "$action" = "rebuild" ] && [ -n "$trigger" ]; then
            printf '%b[ trigger: %s ]%b' "${YELLOW}" "$trigger" "${RESET}"
        fi
        printf '\n'
    done <<PLAN
$plan
PLAN

    # removal: dependents first
    if [ -n "$purge" ]; then
        purge=$(removal_order "$purge")
    fi

    for package in $purge; do
        old_version=$(read_first "$INST_DB/$package/version")
        attrs=$(read_first "$INST_DB/$package/compattrs")

        if [ "$shown" -eq 0 ]; then
            _plan_header
            shown=1
        fi

        printf '%-15s ' "$package"
        _printf_action_version "purge" "${old_version:--}"
        _printf_attrs "$attrs"
        printf '\n'
    done

    while read -r package action; do
        [ "$action" = "install" ] || continue
        if ! in_list "$package" "$system"; then
            deps_only="${deps_only:+$deps_only$NL}$package"
        fi
    done <<PLAN
$plan
PLAN

    if [ -n "$deps_only" ]; then
        set -- $deps_only
        dep_count=$#
        echo ""
        printf 'Additional dependencies (%s)\n' "$dep_count"
        echo ""
        count=0
        printf '%s' '-> '
        for dep in $deps_only; do
            printf '%b ' "${YELLOW}$dep${RESET}"
            count=$((count + 1))
            if [ "$count" -eq 8 ]; then
                printf '\n%s' '-> '
                count=0
            fi
        done
        echo ""
    fi

    printf "\nDo you want continue to reconcile? [N/y] "
    read -r answer
    case "$answer" in
        y|Y|yes|YES)
            echo "lambda: starting reconcile..."
            ;;
        *)
            return 0
            ;;
    esac

    # install/upgrade/rebuild first, so a failure leaves the old packages untouched
    plan_packages=$(printf '%s\n' "$plan" | cut -d' ' -f1)

    for package in $plan_packages; do
        if in_list "$package" "$system"; then
            reason="explicit"
        else
            reason=$(installed_reason "$package")
            reason="${reason:-dependency}"
        fi

        lambda_install "$package" "$reason" || return $?
    done

    for package in $purge; do
        lambda_remove "$package" || return $?
    done

    _orphan_hint
}
