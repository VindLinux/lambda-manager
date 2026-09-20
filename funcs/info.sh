#!/bin/sh

# info <package>...
# Shows a package's status, compattrs, deps and what needs it (read-only).
# Colors mark state words: green=installed/enabled/up to date, red=not installed/excluded,
# yellow=rebuild/update available. Everything else prints uncolored.

# prints a section label padded to the column width, then its first line of content
_info_row()
{
    printf '%-14s%s\n' "$1" "$2"
}

# a continuation line under a section, aligned with _info_row's label width
_info_cont()
{
    printf '%14s%s\n' "" "$1"
}

# colorizes $2 in $1, resetting after. combine codes ("${BOLD}${GREEN}") for bold+color.
_c()
{
    printf '%b%s%b' "$1" "$2" "${RESET}"
}

# where does the current state of an attribute come from?
# $1 = package, $2 = attribute
_info_attr_source()
{
    local package="$1" attr="$2" name="" rest="" override="" token=""

    if [ -f "$PKG_COMPATTRS" ]; then
        while read -r name rest; do
            if [ "$name" = "$package" ]; then
                override="${rest%%#*}"
            fi
        done < "$PKG_COMPATTRS"
    fi

    for token in $override; do
        if [ "$token" = "$attr" ] || [ "$token" = "-$attr" ]; then
            echo "package.compattrs"
            return 0
        fi
    done

    for token in $GLOBAL_COMP_ATTRS; do
        if [ "$token" = "$attr" ] || [ "$token" = "-$attr" ]; then
            echo "make.conf"
            return 0
        fi
    done

    echo "defaults"
}

# installed packages and wanted packages that have $1 as an effective dependency
# $1 = package, $2 = newline separated candidates
_info_required_by()
{
    local package="$1" candidate=""

    for candidate in $2; do
        if [ "$candidate" = "$package" ] || [ ! -d "$PKG_DB/$candidate" ]; then
            continue
        fi

        if in_list "$package" "$(direct_deps "$candidate")"; then
            echo "$candidate"
        fi
    done
}

# prints the Compattrs section for $1, given its effective attrs $2
_info_compattrs()
{
    local package="$1" now="$2" declared="" attr="" enabled="" excluded="" src="" sources=""

    declared=$(sed 's/#.*//' "$PKG_DB/$package/compattrs" 2>/dev/null)

    for attr in $declared; do
        case " $now " in
            *" $attr "*) enabled="${enabled:+$enabled }$attr" ;;
            *) excluded="${excluded:+$excluded }$attr" ;;
        esac

        src=$(_info_attr_source "$package" "$attr")
        case " $sources " in
            *" $src "*) ;;
            *) sources="${sources:+$sources, }$src" ;;
        esac
    done

    _info_row "Compattrs" "$(_c "${GREEN}" "enabled"): ${enabled:-none}"
    _info_cont "$(_c "${RED}" "excluded"): ${excluded:-none}"
    _info_cont "source: ${sources:-defaults}"
}

# prints the Build section for $1, reading $INST_DB/$1/build (key=value per line). silent if absent.
_info_build()
{
    local package="$1" file="$INST_DB/$1/build" key="" value=""
    local b_date="" b_cc="" b_cxx="" b_cflags="" b_cxxflags=""

    [ -f "$file" ] || return 0

    while IFS='=' read -r key value; do
        case "$key" in
            date) b_date="$value" ;;
            cc) b_cc="$value" ;;
            cxx) b_cxx="$value" ;;
            cflags) b_cflags="$value" ;;
            cxxflags) b_cxxflags="$value" ;;
        esac
    done < "$file"

    printf '\n'
    _info_row "Build" "date: $b_date | cc: $b_cc | cxx: $b_cxx"
    _info_cont "cflags: $b_cflags"
    _info_cont "cxxflags: $b_cxxflags"
}

# prints the Deps section for $1, given its effective attrs $2
_info_deps()
{
    local package="$1" now="$2" entry="" flag="" dep="" active=1
    local dep_installed="" dep_pending="" dep_excluded=""

    for entry in $(sed 's/#.*//' "$PKG_DB/$package/dependencies" 2>/dev/null); do
        flag="" dep="$entry" active=1

        case "$entry" in
            *\?*)
                flag=${entry%%\?*}
                dep=${entry#*\?}
                case " $now " in
                    *" $flag "*) ;;
                    *) active=0 ;;
                esac
                ;;
        esac

        if [ "$active" -eq 0 ]; then
            dep_excluded="${dep_excluded:+$dep_excluded }$dep"
        elif [ -d "$INST_DB/$dep" ]; then
            dep_installed="${dep_installed:+$dep_installed }$dep"
        else
            dep_pending="${dep_pending:+$dep_pending }$dep"
        fi
    done

    _info_row "Deps" "$(_c "${GREEN}" "installed"): ${dep_installed:-none}"
    if [ -n "$dep_pending" ]; then
        _info_cont "$(_c "${RED}" "not installed"): $dep_pending"
    fi
    _info_cont "$(_c "${RED}" "excluded"): ${dep_excluded:-none}"
}

info()
{
    local status=0 package="" system="" wanted="" candidates="" who=""
    local recipe_version="" installed_version="" version_shown="" is_installed=0 reason="" reason_word=""
    local description="" attrs_now="" attrs_built="" upgrade=0 rebuild=0 files=0
    local requirers="" who_list="" state_word="" state_color="" update_word="" update_color=""

    if [ "$#" -eq 0 ]; then
        echo "lambda: info requires an argument."
        return 1
    fi

    lambda_load_conf

    # who could require a package: everything installed, plus everything the system file wants
    system=$(system_packages)
    RESOLVE_ROOT_LABEL="the system file"
    resolve_deps $system
    wanted="$RESOLVED"
    for who in $(installed_packages) $wanted; do
        if ! in_list "$who" "$candidates"; then
            candidates="${candidates:+$candidates$NL}$who"
        fi
    done

    for package in "$@"; do
        if [ ! -d "$PKG_DB/$package" ]; then
            if [ -d "$INST_DB/$package" ]; then
                echo "lambda: package not found: $package (it is installed, but its recipe is gone from the tree)"
            else
                echo "lambda: package not found: $package"
            fi
            status=1
            continue
        fi

        recipe_version=$(read_first "$PKG_DB/$package/version")
        installed_version=$(read_first "$INST_DB/$package/version")
        attrs_now=$(resolve_comp_attrs "$package")
        attrs_built=$(read_first "$INST_DB/$package/compattrs")
        reason=$(installed_reason "$package")
        description=$(cat "$PKG_DB/$package/description" 2>/dev/null)

        is_installed=0
        upgrade=0
        rebuild=0
        [ -d "$INST_DB/$package" ] && is_installed=1

        if [ "$is_installed" -eq 1 ]; then
            version_shown="${installed_version:-$recipe_version}"
            if [ -n "$installed_version" ] && [ "$installed_version" != "$recipe_version" ]; then
                upgrade=1
            fi
            if [ "$(attrs_enabled "$attrs_built")" != "$(attrs_enabled "$attrs_now")" ]; then
                rebuild=1
            fi
            state_word="installed"
            state_color="${GREEN}"
        else
            version_shown="$recipe_version"
            state_word="not installed"
            state_color="${RED}"
        fi

        requirers=$(_info_required_by "$package" "$candidates")
        who_list=""
        for who in $requirers; do
            who_list="${who_list:+$who_list, }$who"
        done

        # title

        printf '\n%s %s\n' "$(_c "${BOLD}" "$package $version_shown")" "$(_c "${BOLD}${state_color}" "[$state_word]")"
        if [ -n "$description" ]; then
            printf '%s\n' "$description"
        fi

        # status

        printf '\n'
        if [ "$is_installed" -eq 1 ]; then
            files=$(grep -c . "$INST_DB/$package/files" 2>/dev/null)
            files="${files:-0}"
            reason_word="${reason:-unknown}"

            _info_row "Status" "version: $version_shown | state: $(_c "$state_color" "$state_word") | reason: $reason_word | files: $files"

            if [ "$upgrade" -eq 1 ]; then
                update_word="available ($recipe_version)"
                update_color="${YELLOW}"
            elif [ "$rebuild" -eq 1 ]; then
                update_word="rebuild"
                update_color="${YELLOW}"
            else
                update_word="up to date"
                update_color="${GREEN}"
            fi
            _info_cont "update: $(_c "$update_color" "$update_word")"
        else
            _info_row "Status" "version: $version_shown | state: $(_c "$state_color" "$state_word")"
        fi

        # compattrs / deps / required by

        printf '\n'
        _info_compattrs "$package" "$attrs_now"

        printf '\n'
        _info_deps "$package" "$attrs_now"

        printf '\n'
        _info_row "Required by" "${who_list:-none}"

        _info_build "$package"
    done

    return $status
}
