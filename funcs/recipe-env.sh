#!/bin/sh

# Sourced by every recipe phase, right before the recipe itself.
# Gives recipes attr_on plus default phases that a recipe may override.

. /usr/lib/lambda/attrs.sh

# nothing to compile (scripts, data, meta packages)
pkg_build()
{
    :
}

# strip ELF files staged in $DESTDIR
pkg_strip()
{
    command -v strip >/dev/null 2>&1 || return 0

    find "$DESTDIR" -type f | while IFS= read -r file; do
        magic=$(head -c4 "$file" 2>/dev/null | od -An -tx1 | tr -d ' \n')
        if [ "$magic" = "7f454c46" ]; then
            strip --strip-unneeded "$file" 2>/dev/null
        fi
    done

    return 0
}
