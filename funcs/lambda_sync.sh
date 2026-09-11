#!/bin/sh
# funcs/lambda_sync.sh
#
# Sync the default lambda package recipes from the upstream repository.

lambda_sync()
{
    if [ "$(id -u)" -ne 0 ]; then
        echo "lambda: this command must be run as root."
        return 1
    fi

    if ! command -v git >/dev/null 2>&1; then
        echo "lambda: git is required to sync recipes but was not found."
        return 1
    fi

    printf "Do you want to continue to sync? This will overwrite the default repository recipes in /usr/share/lambda/packages (manual patches on your own custom recipes are not touched). Proceed? [y/N] "
    read -r _ls_answer

    case "$_ls_answer" in
        y|Y|yes|YES)
            echo "lambda: proceeding with syncing..."
            ;;
        *)
            echo "lambda: syncing cancelled."
            return 0
            ;;
    esac

    _ls_repo_dir="/usr/share/lambda/packages"

    _ls_staging=$(mktemp -d "/tmp/lambda-sync-XXXXXX") || {
        echo "lambda: failed to create staging directory."
        return 1
    }

    trap 'rm -rf "$_ls_staging"' INT TERM

    echo "lambda: fetching recipes..."
    if ! git clone --depth 1 https://github.com/VindLinux/packages "$_ls_staging/packages" >/dev/null 2>&1; then
        echo "lambda: failed to clone recipes repository."
        rm -rf "$_ls_staging"
        trap - INT TERM
        return 1
    fi

    if [ ! -d "$_ls_staging/packages/packages" ]; then
        echo "lambda: unexpected repository layout, aborting."
        rm -rf "$_ls_staging"
        trap - INT TERM
        return 1
    fi

    mkdir -p "$_ls_repo_dir" || {
        echo "lambda: failed to create $_ls_repo_dir"
        rm -rf "$_ls_staging"
        trap - INT TERM
        return 1
    }

    if ! cp -f "$_ls_staging/packages/packages/"* "$_ls_repo_dir/"; then
        echo "lambda: failed to copy recipes to $_ls_repo_dir"
        rm -rf "$_ls_staging"
        trap - INT TERM
        return 1
    fi

    rm -rf "$_ls_staging"
    trap - INT TERM

    echo "lambda: successfully synced recipes."
}
