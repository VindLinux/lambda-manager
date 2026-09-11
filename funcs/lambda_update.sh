#!/bin/sh
# funcs/lambda_update.sh
#
# Updates lambda-manager from the upstream repository.

lambda_update()
{
    if [ "$(id -u)" -ne 0 ]; then
        echo "lambda: this command must be run as root."
        return 1
    fi

    if ! command -v git >/dev/null 2>&1; then
        echo "lambda: git is required to update lambda but was not found."
        return 1
    fi

    printf "Do you want to proceed to update? This will update Lambda and its functions, but will not modify your packages, system.json, make.conf or state.json. [y/N] "

    read -r _lu_answer

    case "$_lu_answer" in
        y|Y|yes|YES)
            echo "lambda: proceeding with update..."
            ;;
        *)
            echo "lambda: update cancelled."
            return 0
            ;;
    esac

    _lu_staging=$(mktemp -d "/tmp/lambda-update-XXXXXX") || {
        echo "lambda: failed to create staging directory."
        return 1
    }

    trap 'rm -rf "$_lu_staging"' INT TERM

    echo "lambda: fetching lambda..."
    if ! git clone --depth 1 https://github.com/VindLinux/lambda-manager "$_lu_staging/lambda-manager" >/dev/null 2>&1; then
        echo "lambda: failed to clone lambda repository."
        rm -rf "$_lu_staging"
        trap - INT TERM
        return 1
    fi

    if [ ! -x "$_lu_staging/lambda-manager/install.sh" ]; then
        echo "lambda: unexpected repository layout, aborting."
        rm -rf "$_lu_staging"
        trap - INT TERM
        return 1
    fi

    "$_lu_staging/lambda-manager/install.sh" || {
        echo "lambda: failed to update lambda"
        rm -rf "$_lu_staging"
        trap - INT TERM
        return 1
    }

    rm -rf "$_lu_staging"
    trap - INT TERM

    echo "lambda: successfully updated lambda."
}
