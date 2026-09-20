#!/bin/sh

# attr_on <attr>: succeeds if <attr> is enabled in $COMP_ATTRS.
#
# $COMP_ATTRS looks like "-python lua -clipboard", where "-attr" means disabled.
# Only whole tokens are compared: grep -w would find "python" inside "-python".
attr_on()
{
    case " $COMP_ATTRS " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}
