#!/bin/sh

if [ "$(id -u)" -ne 0 ]; then
    echo "installer.sh: this script must be run with root privileges."
    exit 1
fi

updating=0
if [ -d /usr/lib/lambda ]; then
    updating=1
fi

# install_config <file in configs/> <destination> <description>
# configuration files are only installed if missing, so /etc/lambda is never overwritten
install_config()
{
    if [ -f "$2" ]; then
        echo "$3 already exists, not replacing..."
        return 0
    fi

    echo "Installing $3..."
    cp "configs/$1" "$2" ||
        {
            echo "installer.sh: failed to install $3"
            exit 1
        }
}

echo "Creating Lambda directories..."

for dir in /usr/lib/lambda /usr/share/lambda/installed /usr/share/lambda/packages /etc/lambda; do
    mkdir -p "$dir" ||
        {
            echo "installer.sh: failed to create $dir"
            exit 1
        }
done

echo "Installing Lambda and its functions..."

cp funcs/* /usr/lib/lambda/ ||
    {
        echo "installer.sh: failed to install Lambda functions"
        exit 1
    }

# copy + rename: the new file gets a new inode, so a running 'lambda update' keeps reading the old one
cp lambda.sh /usr/bin/.lambda.new && chmod 755 /usr/bin/.lambda.new && mv -f /usr/bin/.lambda.new /usr/bin/lambda ||
    {
        echo "installer.sh: failed to install Lambda"
        exit 1
    }

if [ -f /etc/lambda/system ]; then
    echo "System file already exists, not replacing..."
else
    echo "Creating system file..."
    touch /etc/lambda/system ||
        {
            echo "installer.sh: failed to create system file"
            exit 1
        }
fi

# make.conf holds PREFIX, MAKEOPTS and the global COMP_ATTRS
install_config make.conf /etc/lambda/make.conf "build configuration file"

# lambda.conf holds the repositories
install_config lambda.conf /etc/lambda/lambda.conf "repositories configuration file"

# package.compattrs holds per-package COMP_ATTRS overrides
install_config package.compattrs /etc/lambda/package.compattrs "package overrides file"

if [ "$updating" -eq 1 ]; then
    echo "Successfully updated Lambda."
else
    echo "Downloading packages recipes..."
    /usr/bin/lambda sync ||
        echo "installer.sh: could not sync the recipes now, run 'lambda sync' after configuring /etc/lambda/lambda.conf"

    echo "Successfully installed Lambda."
fi
