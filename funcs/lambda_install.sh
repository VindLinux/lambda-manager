#!/bin/sh
# funcs/lambda_install.sh
#
# Lambda package installer with staged installation.

_lambda_run_section()
{
    _lrs_package_file="$1"
    _lrs_section="$2"
    _lrs_workdir="$3"

    while IFS= read -r _lrs_command; do
        [ -z "$_lrs_command" ] && continue
        echo "lambda: $_lrs_command"
        ( cd "$_lrs_workdir" && sh -c "$_lrs_command" )
        if [ $? -ne 0 ]; then
            return 1
        fi
    done <<EOF
$(jq -r "(.${_lrs_section} // [])[]" "$_lrs_package_file")
EOF

    return 0
}

# Args: $1 = json file, $2 = package name
_lambda_record_package()
{
    _lrp_file="$1"
    _lrp_package="$2"

    if [ ! -f "$_lrp_file" ]; then
        mkdir -p "$(dirname "$_lrp_file")"
        echo '{"packages": []}' > "$_lrp_file"
    fi

    _lrp_tmp=$(mktemp) || {
        echo "lambda: failed to allocate temp file for $_lrp_file"
        return 1
    }

    if ! jq --arg package "$_lrp_package" \
        '.packages += [$package] | .packages |= unique' \
        "$_lrp_file" > "$_lrp_tmp"; then
        echo "lambda: failed to update $_lrp_file"
        rm -f "$_lrp_tmp"
        return 1
    fi

    install -m 644 "$_lrp_tmp" "$_lrp_file"
    rm -f "$_lrp_tmp"
}

lambda_install()
{
    lambda_install_chain "$1" " "
}

# Recursively resolve and install a package's dependencies, then install
# the package itself. $2 is the chain of packages currently in progress
# (space-padded), used to detect dependency cycles and to tell whether
# this call is the top-level, user-requested install (chain == " ") or a
# dependency pulled in along the way.
#
# All state for this call is kept in _li_*-prefixed variables. Because
# POSIX sh has no `local`, a naive recursive call would still clobber a
# parent frame's variables through the shared global namespace. To keep
# every recursive invocation's state independent, the recursive call
# below is run inside a subshell ( ... ): the subshell gets its own copy
# of the shell's variables, so nothing it does to _li_package, _li_deps,
# etc. can leak back and corrupt the caller's copy once it returns. The
# only things that need to survive a child call are its exit status and
# whatever it wrote to disk (manifests, state.json, system.json) - both
# of those work fine across a subshell boundary.
lambda_install_chain()
{
    _li_package="$1"
    _li_chain="$2"
    _li_package_file="/usr/share/lambda/packages/$_li_package.json"

    if [ ! -f "$_li_package_file" ]; then
        echo "lambda: package '$_li_package' not found."
        return 1
    fi

    _li_is_top_level=0
    [ "$_li_chain" = " " ] && _li_is_top_level=1

    # Already installed - nothing to build. This package is still part of
    # the desired closure of whatever top-level install pulled it in (or
    # is itself the explicit request), so it always belongs in
    # system.json.
    if [ -f "/usr/share/lambda/installed/$_li_package.json" ]; then
        echo "lambda: $_li_package is already installed, skipping."
        # The install marker already exists, so it belongs in state.json
        # (the actual installed set) regardless of whether it happens to
        # be there yet - and it's part of this closure, so it belongs in
        # system.json too.
        _lambda_record_package /var/lib/lambda/state.json "$_li_package" || return 1
        _lambda_record_package /etc/lambda/system.json "$_li_package" || return 1
        return 0
    fi

    case "$_li_chain" in
        *" $_li_package "*)
            echo "lambda: circular dependency detected involving '$_li_package' (chain:${_li_chain})"
            return 1
            ;;
    esac
    _li_new_chain="${_li_chain}${_li_package} "

    # Read dependencies from this package's own recipe. _li_package_file
    # was computed above from this call's own $1, so this always reflects
    # the package actually being resolved at this level - it cannot be
    # affected by any recursive call, since those run in their own
    # subshells.
    _li_deps=$(jq -r '(.dependencies // [])[]' "$_li_package_file")
    if [ -n "$_li_deps" ]; then
        for _li_dep in $_li_deps; do
            if [ -f "/usr/share/lambda/installed/$_li_dep.json" ]; then
                # Already installed elsewhere. The marker file already
                # exists, so it belongs in state.json (actual installed
                # set), and it's still required by this closure, so it
                # also belongs in system.json.
                _lambda_record_package /var/lib/lambda/state.json "$_li_dep" || return 1
                _lambda_record_package /etc/lambda/system.json "$_li_dep" || return 1
                continue
            fi
            echo "lambda: $_li_package requires $_li_dep, resolving..."
            if ! ( lambda_install_chain "$_li_dep" "$_li_new_chain" ); then
                echo "lambda: failed to install dependency '$_li_dep' (required by $_li_package)."
                return 1
            fi
        done
    fi

    # Load build environment. CXXFLAGS etc. depend on CFLAGS being defined
    # first, so we just source the file in order rather than parsing it.
    if [ -f /etc/lambda/make.conf ]; then
        . /etc/lambda/make.conf
    else
        echo "lambda: /etc/lambda/make.conf not found."
        return 1
    fi

    _li_version=$(jq -r '.version' "$_li_package_file")

    _li_staging=$(mktemp -d "/tmp/lambda-${_li_package}-XXXXXX") || {
        echo "lambda: failed to create staging directory for $_li_package"
        return 1
    }
    _li_workdir="$_li_staging/work"
    _li_destdir="$_li_staging/root"
    mkdir -p "$_li_workdir" "$_li_destdir" || {
        echo "lambda: failed to set up staging directory for $_li_package"
        rm -rf "$_li_staging"
        return 1
    }

    # DESTDIR is what package recipes install into (e.g. `make DESTDIR="$DESTDIR" install`).
    # PREFIX still represents the final install location; recipes combine
    # DESTDIR + PREFIX themselves, same as before.
    DESTDIR="$_li_destdir"
    export DESTDIR CC CXX CFLAGS CXXFLAGS LDFLAGS PREFIX MAKEOPTS XORG_PREFIX XORG_CONFIG

    # Best-effort cleanup if we get interrupted mid-install.
    trap 'rm -rf "$_li_staging"' INT TERM

    echo "lambda: installing $_li_package..."

    echo "lambda: downloading $_li_package..."
    if ! _lambda_run_section "$_li_package_file" download "$_li_workdir"; then
        echo "lambda: download failed for $_li_package, aborting."
        rm -rf "$_li_staging"
        trap - INT TERM
        return 1
    fi

    echo "lambda: building $_li_package..."
    if ! _lambda_run_section "$_li_package_file" build "$_li_workdir"; then
        echo "lambda: build failed for $_li_package, aborting."
        rm -rf "$_li_staging"
        trap - INT TERM
        return 1
    fi

    echo "lambda: installing $_li_package..."
    if ! _lambda_run_section "$_li_package_file" install "$_li_workdir"; then
        echo "lambda: install failed for $_li_package, aborting."
        rm -rf "$_li_staging"
        trap - INT TERM
        return 1
    fi

    echo "lambda: stripping $_li_package..."
    if ! _lambda_run_section "$_li_package_file" strip "$_li_workdir"; then
        echo "lambda: strip failed for $_li_package, aborting."
        rm -rf "$_li_staging"
        trap - INT TERM
        return 1
    fi

    # Everything succeeded - commit the staged tree onto the real filesystem.
    echo "lambda: committing $_li_package to filesystem..."

    _li_filelist=$(mktemp) || {
        echo "lambda: failed to allocate file list for $_li_package"
        rm -rf "$_li_staging"
        trap - INT TERM
        return 1
    }

    ( cd "$_li_destdir" && find . -mindepth 1 \( -type f -o -type l \) ) \
        | sed 's|^\.||' > "$_li_filelist"

    if [ ! -s "$_li_filelist" ]; then
        echo "lambda: warning: $_li_package staged no files"
    fi

    # Use tar to copy staged files onto / so permissions, ownership (where
    # possible) and symlinks are preserved, rather than plain cp -r.
    if ! ( cd "$_li_destdir" && tar -cf - . ) | ( cd / && tar -xpf - ); then
        echo "lambda: failed to commit staged files for $_li_package"
        rm -rf "$_li_staging" "$_li_filelist"
        trap - INT TERM
        return 1
    fi

    # Write the package manifest from what was actually staged, not from
    # the recipe. The file list is read straight from $_li_filelist on
    # disk via --rawfile instead of being expanded into a shell variable
    # and passed as a --argjson command-line argument - for packages with
    # very many files that argument would blow past the system's argument
    # size limit ("Argument list too long").
    mkdir -p /usr/share/lambda/installed || {
        echo "lambda: failed to create manifest directory"
        rm -rf "$_li_staging" "$_li_filelist"
        trap - INT TERM
        return 1
    }

    _li_manifest="/usr/share/lambda/installed/${_li_package}.json"
    if ! jq -n \
        --arg name "$_li_package" \
        --arg version "$_li_version" \
        --rawfile filedata "$_li_filelist" \
        '{name: $name, version: $version,
          files: ($filedata | split("\n") | map(select(length > 0)))}' \
        > "$_li_manifest"; then
        echo "lambda: failed to generate manifest for $_li_package, aborting."
        rm -f "$_li_manifest"
        rm -rf "$_li_staging" "$_li_filelist"
        trap - INT TERM
        return 1
    fi

    # Record every install (explicit or dependency) in state.json - this
    # tracks what is actually installed on disk.
    if ! _lambda_record_package /var/lib/lambda/state.json "$_li_package"; then
        rm -rf "$_li_staging" "$_li_filelist"
        trap - INT TERM
        return 1
    fi

    # system.json represents the desired package *closure*: an explicit,
    # top-level install and every dependency it pulls in, transitively,
    # all belong to the desired state - not just the package named on the
    # command line. Otherwise reconcile would see perl's dependencies as
    # orphans and remove them. So every package that gets installed here,
    # top-level or not, is recorded into system.json (dependencies that
    # were already installed are recorded above, in the dependency loop).
    if ! _lambda_record_package /etc/lambda/system.json "$_li_package"; then
        rm -rf "$_li_staging" "$_li_filelist"
        trap - INT TERM
        return 1
    fi

    rm -rf "$_li_staging" "$_li_filelist"
    trap - INT TERM

    echo "lambda: successfully installed $_li_package!"
}
