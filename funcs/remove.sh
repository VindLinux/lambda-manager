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
