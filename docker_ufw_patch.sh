#!/usr/bin/env bash
set -eu

# Solves the problem with open ports with docker and ufw
# As Docker uses the nat table, the filter table FORWARD chain is used and does not touch ufw-input chains as expected.
# Even for ufw-forward chains it would not work, as DOCKER chains are inserted in front.
# This is a simple fix that worked for me.
# https://github.com/moby/moby/issues/4737#issuecomment-420264979

# Unfortunately this fix stops forwarding users origin ip to host mode configured service
# We hotfix that with cronjob for now: Add CRONFIX=1
# Check yourself if you need that. It only allows 1:1 port mappings

# Usage:
# docker_ufw_setup=https://gist.githubusercontent.com/rubot/418ecbcef49425339528233b24654a7d/raw/docker_ufw_setup.sh
#   DEBUG=1 CRONFIX=1 bash <(curl -SsL $docker_ufw_setup)
#   RESET=1 bash <(curl -SsL $docker_ufw_setup)


INTERFACE_NAME=${INTERFACE_NAME:-eth0}


__bool(){ [[ "$(echo ${1:-0}|tr a-z A-Z)" =~ ^(YES|JA|TRUE|[YJ1])$ ]] || return 1; }

__bool ${DEBUG:-} && DEBUG=1 || DEBUG=
__bool ${RESET:-} && RESET=1 || RESET=
__bool ${CRONFIX:-} && CRONFIX=1 || CRONFIX=


__log(){
    echo
    echo "### $@"
    echo
}

__clean_up(){
    local ret="$?"
    if [[ $ret != 0 ]]; then
        __log Unexpected ending: $ret
        exit $ret
    fi
    __log Finish success
    exit 0
}

__clear(){
    __log clear $1 ${2:-docker_ufw}
    touch $1
    sed -i "/^# ${2:-docker_ufw} start/,/^# ${2:-docker_ufw} end/d" $1
    printf "%s" "$(< $1)" > $1
    echo >> $1
    echo >> $1
}

__cronfix(){
    __log cronfix
    echo "#!/bin/bash
# Hotfix: https://github.com/moby/moby/issues/4737#issuecomment-421321737
iptables -tnat -S DOCKER-FIX|grep 'dport'|sed 's/^-A/-D/'|xargs -r -I{} sh -c 'iptables -tnat {}'
iptables -tnat -S DOCKER|grep -E 'dport ([0-9]+).*:\1$'|sed 's/^-A .* -p tcp//'|xargs -r -I{} sh -c 'iptables -tnat -I DOCKER-FIX -i ${INTERFACE_NAME:-eth0} -p tcp {}'
" > /usr/local/bin/docker_stream_fix.sh
    chmod a+x /usr/local/bin/docker_stream_fix.sh

    echo '
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
COMMENT="Hotfix: https://github.com/moby/moby/issues/4737#issuecomment-421321737"
SHELL="/bin/bash"
* * * * * root docker_stream_fix.sh' > /etc/cron.d/docker_stream_fix
}

__iptables_backup(){
    __log iptables_backup
    echo Dump current iptables rules to /root/
    echo Additionally ufw saves some backups in /etc/ufw if needed.
    iptables-save > /root/`date '+%Y%m%d%H%M%S'`_iptabels.save
}

__ufw_enable(){
    __log ufw_enable
    ufw --force enable
    ufw logging off
    if [[ $DEBUG ]]; then
        ufw status
    fi
}

__ufw_reset(){
    __log ufw_reset

    __iptables_backup

    ufw --force disable
    ufw --force reset

    # purge ufw relicts rules and chains in iptables input table
    iptables -S | grep 'ufw-' | sed -e 's/^-A/-D/g' -e 's/-N/-X/g' | sort | xargs -r -I{} sh -c 'iptables {}'

    # flush docker user chain
    iptables -F DOCKER-USER || true
    iptables -A DOCKER-USER -j RETURN || true

    # reset docker-fix
    iptables -tnat -F DOCKER-FIX || true
    iptables -tnat -D PREROUTING -j DOCKER-FIX || true
    iptables -tnat -X DOCKER-FIX || true

    # remove custom configuration block main ufw config
    __clear /etc/ufw/ufw.conf
    __clear /etc/ufw/after.rules
    __clear /etc/ufw/before.init initstart
    __clear /etc/ufw/before.init initstop

    # reset cronfix
    rm -f /etc/cron.d/docker_stream_fix
    rm -f /usr/local/bin/docker_stream_fix.sh

    ufw allow 22/tcp
    echo "You might need to restart docker to recreate docker iptables rules."
}

__ufw_configure(){
    __log ufw_configure
    echo Manpages ufw:
    echo http://manpages.ubuntu.com/manpages/artful/man8/ufw.8.html

    # Backup and reset
    __ufw_reset

    # set some defaults
    # Preventing followin error:
    # ERROR: initcaps
    # [Errno 2] modprobe: ERROR: could not insert 'ip6_tables': Unknown symbol in module, or unknown parameter (see dmesg)
    # ip6tables v1.6.0: can't initialize ip6tables table `filter': Table does not exist (do you need to insmod?)
    # Perhaps ip6tables or your kernel needs to be upgraded.
    echo "# docker_ufw start
MANAGE_BUILTINS=no
IPV6=no
#DEFAULT_FORWARD_POLICY=ACCEPT
# docker_ufw end" >> /etc/ufw/ufw.conf

    # before.init start
    # Prevent flushing those chains when creating them via iptables-restore
    sed -i'' '/start)/a # initstart start\niptables -tnat -N DOCKER 2>/dev/null || true\niptables -tnat -N DOCKER-INGRESS 2>/dev/null || true\n# initstart end' /etc/ufw/before.init
    # before.init stop
    # Ensure DOCKER-USER flush to delete all references to ufw-user-input
    sed -i'' '/stop)/a # initstop start\niptables -F DOCKER-USER || true\niptables -A DOCKER-USER -j RETURN || true\niptables -X ufw-user-input || true\n# initstop end' /etc/ufw/before.init
    chmod a+x /etc/ufw/before.init

    # after.rules
    # Handle docker user rules specifically, otherwise we would face docker services publicly open!
    echo "# docker_ufw start
# Quickfix: https://github.com/moby/moby/issues/4737#issuecomment-420258957
*nat
:PREROUTING - [0:0]
#:DOCKER - [0:0]  # Would be flushed otherwise. Creating it in before.init/start
:DOCKER-FIX - [0:0]
#:DOCKER-INGRESS - [0:0]  # Would be flushed otherwise. Creating it in before.init/start

-F PREROUTING
-A PREROUTING -m addrtype --dst-type LOCAL -j DOCKER-INGRESS
-A PREROUTING -j DOCKER-FIX
-A PREROUTING -m addrtype --dst-type LOCAL -j DOCKER

# original docker rules
# -A PREROUTING -m addrtype --dst-type LOCAL -j DOCKER-INGRESS
# -A PREROUTING -m addrtype --dst-type LOCAL -j DOCKER

-F DOCKER-FIX
-A DOCKER-FIX -m addrtype --dst-type LOCAL -j ACCEPT

COMMIT


*filter
:DOCKER-USER - [0:0]
:ufw-user-input - [0:0]

-F DOCKER-USER
-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A DOCKER-USER -m conntrack --ctstate INVALID -j DROP
-A DOCKER-USER -i $INTERFACE_NAME -j ufw-user-input
-A DOCKER-USER -i $INTERFACE_NAME -j DROP

COMMIT
# docker_ufw end" >> /etc/ufw/after.rules

    # Enable firewall
    __ufw_enable
}


trap __clean_up INT TERM EXIT

[[ "$DEBUG" ]] && set -x

if [[ "$RESET" ]]; then
    __ufw_reset
    __ufw_enable
    exit $?
fi

__ufw_configure

[[ "$CRONFIX" ]] && __cronfix

exit 0
