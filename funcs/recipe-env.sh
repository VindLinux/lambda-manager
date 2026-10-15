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

# Downloads the package source into $1, trying every link in the package's
# sources file, in order, until one works.
#
# $1 = output file
fetch_source()
{
    local out="$1" url="" list=""

    if [ -z "$out" ]; then
        echo "lambda: fetch_source needs an output file" >&2
        return 1
    fi

    if [ ! -f "$PKG_SOURCES" ]; then
        echo "lambda: $PKG_NAME has no sources file" >&2
        return 1
    fi

    # drop comment lines and blank lines, expand ${PKG_VERSION}
    list=$(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' \
               -e "s|\${PKG_VERSION}|$PKG_VERSION|g" "$PKG_SOURCES")

    while read -r url; do
        echo "lambda: downloading $url"

        if curl -fL --connect-timeout 15 --retry 3 --retry-delay 2 -o "$out" "$url"; then
            return 0
        fi

        echo "lambda: failed, trying next source" >&2
        rm -f "$out"
    done <<EOF
$list
EOF

    echo "lambda: all sources failed for $PKG_NAME" >&2
    return 1
}
