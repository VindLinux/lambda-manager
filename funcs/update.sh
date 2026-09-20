#!/bin/sh

# update: reinstalls Lambda itself from its repository. /etc/lambda is never overwritten
# (installer.sh only creates configuration files that are missing).
lambda_update()
{
    local tmp=""

    lambda_require_root || return 1
    lambda_load_conf

    _check_repo "$LAMBDA_REPO" "LAMBDA_REPO" || return 1

    if ! command -v git >/dev/null 2>&1; then
        echo "lambda: git is required to update Lambda"
        return 1
    fi

    tmp=$(mktemp -d) || {
        echo "lambda: failed to create temporary directory"
        return 1
    }

    echo "lambda: fetching Lambda from $LAMBDA_REPO"

    git clone -q --depth 1 "$LAMBDA_REPO" "$tmp/lambda" || {
        echo "lambda: failed to clone the Lambda repository"
        rm -rf "$tmp"
        return 1
    }

    if [ ! -f "$tmp/lambda/installer.sh" ]; then
        echo "lambda: no installer.sh in the Lambda repository"
        rm -rf "$tmp"
        return 1
    fi

    (cd "$tmp/lambda" && sh ./installer.sh) || {
        echo "lambda: update failed"
        rm -rf "$tmp"
        return 1
    }

    rm -rf "$tmp"
}
