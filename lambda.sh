#!/bin/sh

. /usr/lib/lambda/lib.sh
. /usr/lib/lambda/install.sh
. /usr/lib/lambda/remove.sh
. /usr/lib/lambda/mutate.sh
. /usr/lib/lambda/force-remove.sh
. /usr/lib/lambda/deps.sh
. /usr/lib/lambda/orphan.sh
. /usr/lib/lambda/reconcile.sh
. /usr/lib/lambda/sync.sh
. /usr/lib/lambda/update.sh
. /usr/lib/lambda/info.sh

help()
{
    echo "Lambda - package manager for Vind Linux"
    echo
    echo "Usage:"
    echo "    lambda <command> [options] [arguments]"
    echo
    echo "Commands:"
    echo "    mutate append <package>    Add a package to the desired system"
    echo "    mutate purge <package>     Remove a package from the desired system"
		echo "    force-remove <package>     Force-remove installed packages, even if others depend on them"
		echo 
    echo "    deps <package>             Show the dependency tree and the install order"
    echo "    info <package>             Show package information"
    echo
    echo "    reconcile                  Reconcile the installed system with the desired system"
    echo "    orphan                     Find and remove orphaned dependencies"
    echo "    sync [--soft]              Synchronize local package recipes with the repository"
    echo "                               --soft:  only adds recipes that don't exist locally."
    echo ""
    echo "    update                     Update Lambda itself"
    echo
    echo "Options:"
    echo "    -h, --help                 Show this help message"
    echo "    -v, --version              Show Lambda version"
    echo
    echo "Examples:"
    echo "    lambda mutate append vim"
    echo "    lambda mutate purge nano"
    echo
    echo "    lambda deps vim"
    echo "    lambda info vim"
    echo
    echo "    lambda reconcile"
    echo "    lambda orphan"
    echo "    lambda sync"
    echo "    lambda sync --soft"
    echo "    lambda update"
}

if [ "$#" -eq 0 ]; then
    help
    exit 1
fi

case "$1" in
    -h|--help)
        help
        exit 0
        ;;
    -v|--version)
        echo "lambda-manager v1.0"
        exit 0
        ;;
    mutate)
        shift
        mutate "$@"
        exit $?
        ;;
    force-remove)
        shift
        force_remove "$@"
        exit $?
        ;;
		reconcile)
        shift
        reconcile "$@"
        exit $?
        ;;
    orphan)
        shift
        orphan "$@"
        exit $?
        ;;
    deps)
        shift
        deps "$@"
        exit $?
        ;;
    sync)
        shift
        lambda_sync "$@"
        exit $?
        ;;
    update)
        shift
        lambda_update "$@"
        exit $?
        ;;
    info)
        shift
        info "$@"
        exit $?
        ;;
    *)
        help
        exit 1
        ;;
esac
