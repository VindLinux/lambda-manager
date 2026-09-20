#!/bin/sh

# mutate append|purge <package>...
# only edits the system file (the desired state), reconcile applies it
mutate()
{
    local action="" package="" status=0 remaining=""

    lambda_require_root || return 1

    if [ "$#" -eq 0 ]; then
        echo "lambda: mutate requires an argument"
        return 1
    fi

    if [ "$1" = "append" ]; then
        action="append"
    elif [ "$1" = "purge" ]; then
        action="purge"
    else
        echo "lambda: invalid mutate operation"
        return 1
    fi

    shift

    if [ "$#" -eq 0 ]; then
        echo "lambda: mutate $action requires a package"
        return 1
    fi

    if [ ! -f "$SYSTEM_FILE" ]; then
        touch "$SYSTEM_FILE" || return 1
    fi

    for package in "$@"; do
        if [ "$action" = "append" ]; then
            if [ ! -d "$PKG_DB/$package" ]; then
                echo "lambda: package not found: $package"
                status=1
                continue
            fi

            if grep -qxF -- "$package" "$SYSTEM_FILE"; then
                echo "lambda: $package is already at system file"
                continue
            fi

            echo "lambda: appending $package to the system file"
            echo "$package" >> "$SYSTEM_FILE"
        else
            # purge only needs the name: the recipe may be gone from the tree
            if ! grep -qxF -- "$package" "$SYSTEM_FILE"; then
                echo "lambda: $package is not at system file"
                continue
            fi

            echo "lambda: purging $package from the system file"
            remaining=$(grep -vxF -- "$package" "$SYSTEM_FILE")
            if [ -n "$remaining" ]; then
                printf '%s\n' "$remaining" > "$SYSTEM_FILE"
            else
                : > "$SYSTEM_FILE"
            fi
        fi
    done

    return $status
}
