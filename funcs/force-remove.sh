#!/bin/sh

# Removes an installed package: its files (except the ones another installed package also owns
# and everything under /etc), the directories left empty, and its record in installed/.
# $1 = package
lambda_remove()
{
    local package="$1" installed_dir="$INST_DB/$1" list=""

    if [ ! -d "$installed_dir" ]; then
        echo "lambda: $package is not installed"
        return 1
    fi

    echo "lambda: removing $package"

    list=$(grep -v '^$' "$installed_dir/files" 2>/dev/null)
    remove_unowned "$package" "$list"

    rm -rf "$installed_dir"

    echo "lambda: $package removed"
}

# force_remove <package>...
# Forces the removal of installed packages, whatever the reason they are installed for (dependencies
# included). Unlike 'mutate purge' it does not touch the system file, and unlike 'reconcile'/'orphan'
# it does not care whether the package is still wanted. It warns about what depends on it.
force_remove()
{
    local assume_yes=0 package="" set="" installed="" candidate="" dependents="" answer=""
    local status=0 warn_deps=0 warn_system=0 ordered="" system=""

    lambda_require_root || return 1

    if [ "$#" -eq 0 ]; then
        echo "lambda: remove requires a package"
        return 1
    fi

    lambda_load_conf

    for package in "$@"; do
        case "$package" in
            -y|--yes)
                assume_yes=1
                continue
                ;;
            -*)
                echo "lambda: unknown option for remove: $package"
                return 1
                ;;
        esac

        if [ ! -d "$INST_DB/$package" ]; then
            echo "lambda: $package is not installed"
            status=1
            continue
        fi

        if ! in_list "$package" "$set"; then
            set="${set:+$set$NL}$package"
        fi
    done

    if [ -z "$set" ]; then
        return 1
    fi

    installed=$(installed_packages)
    system=$(system_packages)

    echo "Packages to remove:"

    for package in $set; do
        dependents=""

        # installed packages (that are not being removed too) that depend on it
        for candidate in $installed; do
            if [ "$candidate" = "$package" ] || in_list "$candidate" "$set"; then
                continue
            fi
            if in_list "$package" "$(direct_deps "$candidate")"; then
                dependents="${dependents:+$dependents, }$candidate"
            fi
        done

        printf '  %-15s' "$package"
        if [ -n "$dependents" ]; then
            printf '%b(required by: %s)%b' "${YELLOW}" "$dependents" "${RESET}"
            warn_deps=1
        fi
        if in_list "$package" "$system"; then
            printf '%b [in the system file]%b' "${YELLOW}" "${RESET}"
            warn_system=1
        fi
        printf '\n'
    done

    if [ "$warn_deps" -eq 1 ]; then
        echo ""
        echo "lambda: warning: other installed packages need these, they may stop working,"
        echo "lambda: and the next 'lambda reconcile' will install them again."
    fi
    if [ "$warn_system" -eq 1 ]; then
        echo ""
        echo "lambda: warning: some are in the system file, use 'lambda mutate purge' to drop them for good."
    fi

    if [ "$assume_yes" -ne 1 ]; then
        printf '\nForce removal? [y/N] '
        read -r answer
        case "$answer" in
            y|Y|yes|YES) ;;
            *) return 0 ;;
        esac
    fi

    # dependents first
    ordered=$(removal_order "$set")

    for package in $ordered; do
        lambda_remove "$package" || status=1
    done

    return $status
}
