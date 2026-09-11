#!/bin/sh

. /usr/lib/lambda/lambda_reconcile.sh
. /usr/lib/lambda/lambda_mutate.sh
. /usr/lib/lambda/lambda_sync.sh
. /usr/lib/lambda/lambda_update.sh

usage()
{
    echo "Usage: lambda <command> [arguments]..."
    echo "Minimalist declarative package manager"
    echo ""
    echo "Commands:"
    echo "  mutate <append|purge> <package>"
    echo "      Modify the desired system state."
    echo ""
    echo "  sync"
    echo "      Sync local packages from the upstream repository."
    echo ""
    echo "  update"
    echo "      Update lambda from the upstream repository."
    echo ""
    echo "  reconcile"
    echo "      Reconcile the system with the desired state."
    echo ""
    echo "  --help"
    echo "      Display this help message."
}

if [ "$#" -eq 0 ]; then
    usage
    exit 1
fi

if [ "$1" = "--help" ]; then
    usage
    exit 0
elif [ "$1" = "reconcile" ]; then
    lambda_reconcile
    exit $?
elif [ "$1" = "mutate" ]; then
    shift
    lambda_mutate "$@"
    exit $?
elif [ "$1" == "sync" ]; then
    lambda_sync
    exit $?
elif [ "$1" == "update" ]; then
    lambda_update
    exit $?
else
    usage
    exit 0
fi
