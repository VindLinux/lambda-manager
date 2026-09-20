#!/bin/sh

# Runs one phase of a recipe on its own shell. Only the recipe environment (attr_on, default
# phases) and exported variables are visible to it, none of Lambda's functions, so a recipe
# can freely call coreutils/busybox install. stdin is closed so a phase can't eat Lambda input.
#
# $1 = package, $2 = phase, $3 = staging dir, $4 = destdir, $5 = resolved COMP_ATTRS, $6 = version
_run_phase()
{
    (
        cd "$3" || exit 1
        exec env "COMP_ATTRS=$5" "DESTDIR=$4" "PKG_NAME=$1" "PKG_VERSION=$6" \
            sh -c '. /usr/lib/lambda/recipe-env.sh
                   . "$1"
                   if ! command -v "$2" >/dev/null 2>&1; then
                       echo "lambda: recipe has no $2" >&2
                       exit 127
                   fi
                   "$2"' sh "$PKG_DB/$1/recipe" "pkg_$2" </dev/null
    )
}

# Files under /etc are not overwritten, if the file already exists (and differs) the
# packaged one, it is shipped as <file>.lambda-new instead, so user changes survive rebuilds.
#
# $1 = destdir
_protect_etc()
{
    local destdir="$1"

    if [ ! -d "$destdir/etc" ]; then
        return 0
    fi

    (cd "$destdir" && find etc \( -type f -o -type l \)) | while IFS= read -r file; do
        if [ ! -e "/$file" ] && [ ! -L "/$file" ]; then
            continue
        fi

        if [ -f "$destdir/$file" ] && [ ! -L "$destdir/$file" ] && cmp -s "$destdir/$file" "/$file"; then
            rm -f "$destdir/$file"
        else
            mv "$destdir/$file" "$destdir/$file.lambda-new"
            echo "lambda: kept existing /$file (new version saved as /$file.lambda-new)"
        fi
    done
}

# Installs (or upgrades/rebuilds, over the old version) a package from its recipe.
#
# $1 = package, $2 = reason: explicit or dependency
lambda_install()
{
    local package="$1" reason="${2:-dependency}"
    local recipe="$PKG_DB/$package/recipe" installed_dir="$INST_DB/$package"
    local staging_dir="" destdir="" comp_attrs="" version="" manifest="" phase="" old_manifest="" stale=""

    if [ ! -f "$recipe" ]; then
        echo "lambda: recipe not found for $package"
        return 1
    fi

    version=$(read_first "$PKG_DB/$package/version")
    comp_attrs=$(resolve_comp_attrs "$package")

    echo "lambda: creating staging directory for $package"

    staging_dir=$(mktemp -d) || {
        echo "lambda: failed to allocate staging directory for $package"
        return 1
    }

    # DESTDIR is where the package gets installed to before going to the real system
    destdir="$staging_dir/destdir"
    mkdir -p "$destdir"

    for phase in download build install strip; do
        echo "lambda: running $phase for $package"

        _run_phase "$package" "$phase" "$staging_dir" "$destdir" "$comp_attrs" "$version" || {
            echo "lambda: failed to $phase $package"
            return 1
        }
    done

    echo "lambda: generating manifest for $package"

    # built from the staged destdir, stripping the destdir prefix from each path
    manifest=$(find "$destdir" \( -type f -o -type l \) | sed "s|^$destdir||" | LC_ALL=C sort)

    # upgrade/rebuild: remember what the old version shipped, to clean up what the new one drops
    if [ -f "$installed_dir/files" ]; then
        old_manifest=$(mktemp) || return 1
        grep -v '^$' "$installed_dir/files" > "$old_manifest"
    fi

    _protect_etc "$destdir"

    echo "lambda: copying $package files to the system"

    # copy the staged tree into the real system, preserving permissions and symlinks
    tar cf "$staging_dir/package.tar" -C "$destdir" . && tar xpf "$staging_dir/package.tar" -C / || {
        echo "lambda: failed to copy $package files to the system"
        return 1
    }

    mkdir -p "$installed_dir"

    if [ -n "$manifest" ]; then
        printf '%s\n' "$manifest" > "$installed_dir/files"
    else
        : > "$installed_dir/files"
    fi
    printf '%s\n' "$comp_attrs" > "$installed_dir/compattrs"
    printf '%s\n' "$version" > "$installed_dir/version"
    printf '%s\n' "$reason" > "$installed_dir/reason"

    # snapshot of what this build actually used, for 'lambda info'
    {
        printf 'date=%s\n' "$(date +%Y-%m-%d)"
        printf 'cc=%s\n' "$CC"
        printf 'cxx=%s\n' "$CXX"
        printf 'cflags=%s\n' "$CFLAGS"
        printf 'cxxflags=%s\n' "$CXXFLAGS"
    } > "$installed_dir/build"

    if [ -n "$old_manifest" ]; then
        stale=$(grep -vxFf "$installed_dir/files" "$old_manifest")
        if [ -n "$stale" ]; then
            echo "lambda: removing files $package no longer ships"
            remove_unowned "$package" "$stale"
        fi
        rm -f "$old_manifest"
    fi

    # staging is only removed after a successful install, so it's left behind for debugging on failure
    rm -rf "$staging_dir"

    echo "lambda: $package installed successfully"
}
