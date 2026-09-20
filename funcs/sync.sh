#!/bin/sh

# Prints the configured recipe repositories, highest priority first, one per line:
#   <name> <variable> <url>
#
#   OFFICIAL_RECIPES_REPO       always first (RECIPES_REPO is accepted as an alias)
#   COMMUNITY_RECIPES_REPO_<n>  after it, in numeric order (so 3 comes before 10), empty ones skipped
#
# The official line is printed even when empty, so that the caller can complain about it.
_recipe_repos()
{
    local n="" url=""

    echo "official OFFICIAL_RECIPES_REPO ${OFFICIAL_RECIPES_REPO:-${RECIPES_REPO:-}}"

    # n only ever holds digits (see the sed), so the eval below can't run anything else
    for n in $(set | sed -n 's/^COMMUNITY_RECIPES_REPO_\([0-9][0-9]*\)=.*/\1/p' | sort -n); do
        eval "url=\$COMMUNITY_RECIPES_REPO_$n"
        if [ -n "$url" ]; then
            echo "community-$n COMMUNITY_RECIPES_REPO_$n $url"
        fi
    done
}

# sync [--soft]: updates the local recipes from the recipes repositories.
#
# When the same package is provided by more than one repository the one with the highest
# priority wins (official, then community by number). A community repository can therefore add
# packages but never replace an official one. Recipes are code that runs as root: only add
# repositories you trust.
#
#   default: a recipe that exists locally is replaced by the repository one, a recipe that only
#            exists locally is kept, a recipe that only exists in a repository is added.
#   --soft:  only adds recipes that don't exist locally.
#
# Every repository is fetched before anything is touched: if one of them fails, nothing changes.
# Otherwise a broken high priority repository could let a lower priority one take its place.
lambda_sync()
{
    local soft=0 repos="" tmp="" name="" var="" url="" src="" dir="" package="" target="" subdir=""
    local seen="" added=0 updated=0 unchanged=0 skipped=0 ignored=0

    lambda_require_root || return 1
    lambda_load_conf

    case "${1:-}" in
        "") ;;
        --soft) soft=1 ;;
        *)
            echo "lambda: unknown option for sync: $1"
            return 1
            ;;
    esac

    subdir="${RECIPES_SUBDIR:-database}"
    repos=$(_recipe_repos)

    while read -r name var url; do
        _check_repo "$url" "$var" || return 1
    done <<REPOS
$repos
REPOS

    if ! command -v git >/dev/null 2>&1; then
        echo "lambda: git is required to sync the recipes"
        return 1
    fi

    tmp=$(mktemp -d) || {
        echo "lambda: failed to create temporary directory"
        return 1
    }

    # fetch everything

    while read -r name var url; do
        echo "lambda: fetching $name recipes from $url"

        git clone -q --depth 1 "$url" "$tmp/$name" </dev/null || {
            echo "lambda: failed to clone $name ($var), nothing was changed"
            rm -rf "$tmp"
            return 1
        }

        if [ ! -d "$tmp/$name/$subdir" ]; then
            echo "lambda: no '$subdir' directory in $name ($var), nothing was changed"
            rm -rf "$tmp"
            return 1
        fi
    done <<REPOS
$repos
REPOS

    # apply, highest priority first

    while read -r name var url; do
        for dir in "$tmp/$name/$subdir"/*/; do
            dir="${dir%/}"

            # a package is a real directory, never a link to somewhere else
            if [ -L "$dir" ] || [ ! -d "$dir" ]; then
                continue
            fi

            package="${dir##*/}"
            target="$PKG_DB/$package"

            if in_list "$package" "$seen"; then
                echo "lambda: $name also provides $package, ignored"
                ignored=$((ignored + 1))
                continue
            fi
            seen="${seen:+$seen$NL}$package"

            if [ ! -d "$target" ]; then
                cp -R "$dir" "$target" || {
                    echo "lambda: failed to add recipe $package"
                    rm -rf "$tmp"
                    return 1
                }
                printf '  %-8s %-20s (%s)\n' "added" "$package" "$name"
                added=$((added + 1))
            elif [ "$soft" -eq 1 ]; then
                skipped=$((skipped + 1))
            elif diff -rq "$dir" "$target" >/dev/null 2>&1; then
                unchanged=$((unchanged + 1))
            else
                # swap, so an interrupted sync never leaves a half copied recipe behind
                rm -rf "$PKG_DB/.$package.new" "$PKG_DB/.$package.old"
                cp -R "$dir" "$PKG_DB/.$package.new" &&
                    mv "$target" "$PKG_DB/.$package.old" &&
                    mv "$PKG_DB/.$package.new" "$target" &&
                    rm -rf "$PKG_DB/.$package.old" || {
                    echo "lambda: failed to update recipe $package"
                    rm -rf "$tmp"
                    return 1
                }
                printf '  %-8s %-20s (%s)\n' "updated" "$package" "$name"
                updated=$((updated + 1))
            fi
        done
    done <<REPOS
$repos
REPOS

    rm -rf "$tmp"

    echo "lambda: sync complete: $added added, $updated updated, $unchanged unchanged, $skipped skipped, $ignored ignored"
}
