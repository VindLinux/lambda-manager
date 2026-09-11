#!/bin/sh

lambda_installer()
{
    echo "Creating /etc/lambda/ ..."
    mkdir -pv /etc/lambda/ || return 1

    if [ ! -e /etc/lambda/system.json ]; then
        echo "Installing config/system.json to /etc/lambda/ ..."
        install -m 644 config/system.json /etc/lambda/system.json || return 1
    else
        echo "Keeping existing /etc/lambda/system.json"
    fi

    if [ ! -e /etc/lambda/make.conf ]; then
        echo "Installing config/make.conf to /etc/lambda/ ..."
        install -m 644 config/make.conf /etc/lambda/make.conf || return 1
    else
        echo "Keeping existing /etc/lambda/make.conf"
    fi

    echo "Creating /var/lib/lambda/ ..."
    mkdir -pv /var/lib/lambda/ || return 1

    if [ ! -e /var/lib/lambda/state.json ]; then
        echo "Installing config/state.json to /var/lib/lambda/ ..."
        install -m 644 config/state.json /var/lib/lambda/state.json || return 1
    else
        echo "Keeping existing /var/lib/lambda/state.json"
    fi

    echo "Creating /usr/lib/lambda/ ..."
    mkdir -pv /usr/lib/lambda/ || return 1

    echo "Installing lambda functions..."
    for func in funcs/lambda_*.sh; do
        install -m 644 "$func" /usr/lib/lambda/ || return 1
    done

    echo "Creating /usr/share/lambda/installed/ ..."
    mkdir -pv /usr/share/lambda/installed/ || return 1

    echo "Creating /usr/share/lambda/packages/ ..."
    mkdir -pv /usr/share/lambda/packages/ || return 1

    echo "Installing package repository..."
    cp -r packages/. /usr/share/lambda/packages/ || return 1

    echo "Installing lambda..."
    install -m 755 lambda.sh /usr/bin/lambda || return 1

    echo "Successfully installed lambda!"
}

if [ "$(id -u)" -ne 0 ]; then
    echo "install.sh: this script must be run as root."
    exit 1
fi

lambda_installer || exit 1
