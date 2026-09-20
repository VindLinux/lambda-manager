#!/bin/sh

# Lambda shared library, sourced by lambda.sh before the command files:
# paths, configuration, COMP_ATTRS resolution and dependency resolution.
#
# NOTE: every 'local' is initialised on purpose. In dash a bare `local x` keeps the
# caller's value of x, in bash it starts empty.

. /usr/lib/lambda/attrs.sh

LAMBDA_LIB=/usr/lib/lambda
LAMBDA_ETC=/etc/lambda
PKG_DB=/usr/share/lambda/packages
INST_DB=/usr/share/lambda/installed
SYSTEM_FILE="$LAMBDA_ETC/system"
PKG_COMPATTRS="$LAMBDA_ETC/package.compattrs"

NL='
'
RESET='\e[0m'

BOLD='\e[1m'

RED='\e[31m'
GREEN='\e[32m'
YELLOW='\e[33m'
CYAN='\e[36m'
GRAY='\e[90m'

lambda_require_root()
{
    if [ "$(id -u)" -ne 0 ]; then
        echo "lambda: this operation requires root privileges"
        return 1
    fi
}

# loads make.conf (PREFIX, MAKEOPTS, global COMP_ATTRS, ...) and lambda.conf (repositories)
lambda_load_conf()
{
    if [ -f "$LAMBDA_ETC/make.conf" ]; then
        set -a
        . "$LAMBDA_ETC/make.conf"
        set +a
    fi

    # COMP_ATTRS is overwritten per package when building, keep the global one apart
    GLOBAL_COMP_ATTRS="$COMP_ATTRS"

    if [ -f "$LAMBDA_ETC/lambda.conf" ]; then
        . "$LAMBDA_ETC/lambda.conf"
    fi
}

# $1 = repository url, $2 = name of the variable (only for the message)
_check_repo()
{
    case "$1" in
        ""|*example.invalid*)
            echo "lambda: $2 is not configured"
            echo "lambda: edit $LAMBDA_ETC/lambda.conf"
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------

# $1 = item, $2 = newline separated list
in_list()
{
    printf '%s\n' "$2" | grep -qxF -- "$1"
}

reverse_list()
{
    local item="" out=""
    for item in $1; do
        out="$item${out:+$NL$out}"
    done
    printf '%s\n' "$out"
}

# prints the first line of a file, nothing if it doesn't exist
read_first()
{
    local line=""
    if [ -f "$1" ]; then
        read -r line < "$1"
    fi
    printf '%s\n' "$line"
}

# packages listed in the system file, without comments and duplicates
system_packages()
{
    local seen="" package=""
    for package in $(sed 's/#.*//' "$SYSTEM_FILE" 2>/dev/null); do
        if in_list "$package" "$seen"; then
            continue
        fi
        seen="${seen:+$seen$NL}$package"
        echo "$package"
    done
}

installed_packages()
{
    local dir=""
    for dir in "$INST_DB"/*; do
        [ -d "$dir" ] || continue
        echo "${dir##*/}"
    done
}

# explicit (the user asked for it in the system file) or dependency (installed because something needs it)
installed_reason()
{
    read_first "$INST_DB/$1/reason"
}

set_reason()
{
    printf '%s\n' "$2" > "$INST_DB/$1/reason"
}

# ---------------------------------------------------------------------------
# COMP_ATTRS
# ---------------------------------------------------------------------------

# Effective COMP_ATTRS of a package, crossing:
#   global attrs (make.conf) x attrs the package understands (compattrs) x overrides (package.compattrs)
# only attrs declared in the package's compattrs are considered, all default to disabled.
# prints e.g. "-python lua -clipboard"
# $1 = package
resolve_comp_attrs()
{
    local package="$1" override="" name="" rest="" attr="" state="" token="" result="" g="" o=""

    if [ -f "$PKG_COMPATTRS" ]; then
        while read -r name rest; do
            if [ "$name" = "$package" ]; then
                override="${rest%%#*}"
            fi
        done < "$PKG_COMPATTRS"
    fi

    for attr in $(sed 's/#.*//' "$PKG_DB/$package/compattrs" 2>/dev/null); do
        state="off"

        for g in $GLOBAL_COMP_ATTRS; do
            case "$g" in
                "$attr") state="on" ;;
                "-$attr") state="off" ;;
            esac
        done

        # per-package override takes precedence over the global state
        for o in $override; do
            case "$o" in
                "$attr") state="on" ;;
                "-$attr") state="off" ;;
            esac
        done

        if [ "$state" = "on" ]; then
            token="$attr"
        else
            token="-$attr"
        fi

        result="${result:+$result }$token"
    done

    printf '%s\n' "$result"
}

# enabled attrs of a resolved COMP_ATTRS string, sorted. attrs are compared as sets of enabled
# attrs a new attr the package learned but that is disabled changes nothing.
attrs_enabled()
{
    local token=""
    for token in $1; do
        case "$token" in
            -*) ;;
            *) echo "$token" ;;
        esac
    done | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'
    echo
}

# $1 = old resolved attrs, $2 = new resolved attrs. prints e.g. "+lua -python"
attrs_diff()
{
    local old="" new="" token="" out=""
    old=$(attrs_enabled "$1")
    new=$(attrs_enabled "$2")

    for token in $new; do
        case " $old " in
            *" $token "*) ;;
            *) out="${out:+$out }+$token" ;;
        esac
    done
    for token in $old; do
        case " $new " in
            *" $token "*) ;;
            *) out="${out:+$out }-$token" ;;
        esac
    done

    printf '%s\n' "$out"
}

# ---------------------------------------------------------------------------
# dependencies
# ---------------------------------------------------------------------------

# Effective direct dependencies of a package, one per line.
#
# dependencies file, one entry per line:
#   pkg          unconditional
#   flag?pkg     only if <flag> is enabled in the resolved COMP_ATTRS of the package
# $1 = package
direct_deps()
{
    local package="$1" attrs="" entry="" flag=""
    attrs=$(resolve_comp_attrs "$package")

    for entry in $(sed 's/#.*//' "$PKG_DB/$package/dependencies" 2>/dev/null); do
        case "$entry" in
            *\?*)
                flag=${entry%%\?*}
                # whole tokens only: "-python" (disabled) is not "python"
                case " $attrs " in
                    *" $flag "*) echo "${entry#*\?}" ;;
                esac
                ;;
            *)
                echo "$entry"
                ;;
        esac
    done
}

# Resolves the dependencies of the given packages, recursively.
# Sets (globals):
#   RESOLVED  every package involved, one per line, dependencies BEFORE their dependents
#             (topological order). e.g. A -> X(B,C), Z(L,M)  =>  B C X L M Z A
#   MISSING   "pkg (required by x)" lines for packages that are not in the tree
#   CYCLE     "A -> B -> A" if a circular dependency was found
# $RESOLVE_ROOT_LABEL says who asked for the given packages (only used in MISSING)
resolve_deps()
{
    local package=""
    RESOLVED=""
    MISSING=""
    CYCLE=""

    for package in "$@"; do
        _resolve "$package" "${RESOLVE_ROOT_LABEL:-the system file}" ""
    done
}

# $1 = package, $2 = who requires it, $3 = the chain of packages being resolved (to catch cycles)
_resolve()
{
    local package="$1" required_by="$2" trail="$3" dependency="" p="" found=0

    if [ -n "$CYCLE" ]; then
        return 0
    fi

    if [ ! -d "$PKG_DB/$package" ]; then
        MISSING="${MISSING:+$MISSING$NL}$package (required by $required_by)"
        return 0
    fi

    if in_list "$package" "$RESOLVED"; then
        return 0
    fi

    if in_list "$package" "$trail"; then
        for p in $trail; do
            if [ "$p" = "$package" ]; then
                found=1
            fi
            if [ "$found" -eq 1 ]; then
                CYCLE="$CYCLE$p -> "
            fi
        done
        CYCLE="$CYCLE$package"
        return 0
    fi

    trail="${trail:+$trail$NL}$package"

    for dependency in $(direct_deps "$package"); do
        _resolve "$dependency" "$package" "$trail"
    done

    if [ -n "$CYCLE" ]; then
        return 0
    fi

    RESOLVED="${RESOLVED:+$RESOLVED$NL}$package"
}

# prints what went wrong after resolve_deps, fails if anything did
report_resolve_errors()
{
    if [ -n "$CYCLE" ]; then
        echo "lambda: circular dependency detected:"
        echo "  $CYCLE"
        return 1
    fi

    if [ -n "$MISSING" ]; then
        echo "lambda: packages not found in $PKG_DB:"
        printf '%s\n' "$MISSING" | sed 's/^/ - /'
        return 1
    fi

    return 0
}

# $1 = newline separated list of installed packages that are going to be removed.
# prints them dependents first (reverse topological order).
# recipes that vanished from the tree can't be walked, those go last.
# clobbers RESOLVED/MISSING/CYCLE: call it inside $(...)
removal_order()
{
    local set="$1" package="" out=""

    RESOLVE_ROOT_LABEL="a package being removed"
    resolve_deps $set

    for package in $(reverse_list "$RESOLVED"); do
        if in_list "$package" "$set"; then
            out="${out:+$out$NL}$package"
        fi
    done

    for package in $set; do
        if ! in_list "$package" "$out"; then
            out="${out:+$out$NL}$package"
        fi
    done

    printf '%s\n' "$out"
}

# ---------------------------------------------------------------------------
# files
# ---------------------------------------------------------------------------

# every path listed by the manifests of the installed packages other than $1
owned_by_others()
{
    local dir=""
    for dir in "$INST_DB"/*; do
        [ -d "$dir" ] || continue
        if [ "${dir##*/}" = "$1" ]; then
            continue
        fi
        cat "$dir/files" 2>/dev/null
    done
}

# removes empty parent directories of $1, stops at the first one that isn't empty or is a system directory
_rmdir_parents()
{
    local dir="${1%/*}"

    while [ -n "$dir" ]; do
        case "$dir" in
            /|/bin|/sbin|/lib|/lib64|/usr|/usr/bin|/usr/sbin|/usr/lib|/usr/lib64|/usr/libexec|/usr/share|/usr/include|/usr/local|/etc|/var|/opt|/home|/root|/tmp|/dev|/proc|/sys|/run|/boot|/mnt|/media|/srv)
                return 0
                ;;
        esac

        rmdir "$dir" 2>/dev/null || return 0
        dir="${dir%/*}"
    done
}

# Deletes the given paths, except the ones another installed package also owns, then the
# directories that became empty. Files under /etc are never deleted, they may hold user changes.
# $1 = package losing the files, $2 = newline separated paths
remove_unowned()
{
    local package="$1" list="$2" others="" file=""

    if [ -z "$list" ]; then
        return 0
    fi

    others=$(mktemp) || return 1
    owned_by_others "$package" | grep -v '^$' > "$others"

    printf '%s\n' "$list" | grep -vxFf "$others" | while IFS= read -r file; do
        case "$file" in
            "") continue ;;
            /etc/*)
                echo "lambda: kept $file"
                continue
                ;;
        esac

        rm -f -- "$file"
        _rmdir_parents "$file"
    done

    rm -f "$others"
}
