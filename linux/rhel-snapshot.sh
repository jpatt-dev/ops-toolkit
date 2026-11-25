#!/usr/bin/env bash
# rhel-snapshot.sh - read-only health snapshot for RHEL 8, 9, and 10.
#
# Prints a short summary to stdout. It does not change configuration,
# restart services, install packages, or contact other hosts.
# Some sections need root; they are skipped with a note when not root.
#
# Usage:
#   ./rhel-snapshot.sh            # full snapshot
#   ./rhel-snapshot.sh --brief    # skip slower sections (journal, processes)
#
# Output can contain hostnames, IP addresses, and user names. Review it
# before attaching it to a ticket. Do not save it in this repository.

set -u
export LC_ALL=C

BRIEF=0
case "${1:-}" in
    --brief) BRIEF=1 ;;
    -h|--help)
        sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    "") ;;
    *)
        echo "Unknown option: $1" >&2
        exit 2
        ;;
esac

IS_ROOT=0
[ "$(id -u)" -eq 0 ] && IS_ROOT=1

have() { command -v "$1" >/dev/null 2>&1; }

section() { printf '\n=== %s ===\n' "$1"; }

# Run a command with a time limit when timeout(1) exists.
run() {
    if have timeout; then
        timeout 15 "$@" 2>&1
    else
        "$@" 2>&1
    fi
}

need_root() {
    if [ "$IS_ROOT" -ne 1 ]; then
        echo "(skipped: needs root)"
        return 1
    fi
    return 0
}

section "Host"
if [ -r /etc/redhat-release ]; then
    cat /etc/redhat-release
elif [ -r /etc/os-release ]; then
    . /etc/os-release && echo "${PRETTY_NAME:-unknown}"
fi
echo "Kernel:   $(uname -r)"
echo "Hostname: $(hostname -f 2>/dev/null || hostname)"
echo "Uptime:   $(uptime)"
have who && echo "Boot:     $(who -b 2>/dev/null | sed 's/^ *//')"

section "Time"
if have timedatectl; then
    run timedatectl | grep -Ei 'time zone|synchronized|NTP service' || true
fi
if have chronyc; then
    run chronyc tracking | grep -Ei 'reference id|system time|leap status' || true
fi

section "CPU and memory"
have nproc && echo "CPUs: $(nproc)"
run free -h

section "Filesystems (usage >= 80% marked with !)"
df -hTP -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | awk 'NR==1 {print "  " $0; next} {u=$6; sub("%","",u); m=(u+0>=80)?"! ":"  "; print m $0}'

section "Inodes (usage >= 80% marked with !)"
df -iP -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | awk 'NR==1 {print "  " $0; next} {u=$5; sub("%","",u); m=(u+0>=80)?"! ":"  "; print m $0}'

section "Failed systemd units"
if have systemctl; then
    out=$(run systemctl --failed --no-legend --plain)
    if [ -n "$out" ]; then echo "$out"; else echo "none"; fi
fi

section "Reboot and service restart status"
if have dnf; then
    if need_root; then
        run dnf -q needs-restarting -r
        echo "needs-restarting exit code: $? (1 = reboot required)"
    fi
else
    echo "dnf not found"
fi
echo "Running kernel:  $(uname -r)"
if have rpm; then
    echo "Newest kernel:   $(rpm -q --last kernel kernel-core 2>/dev/null | grep -v 'not installed' | head -1 | awk '{print $1}')"
fi

section "SELinux"
if have getenforce; then
    echo "Mode: $(getenforce)"
    if have ausearch && need_root; then
        count=$(ausearch -m AVC,USER_AVC -ts today 2>/dev/null | grep -c 'type=AVC\|type=USER_AVC')
        echo "AVC denials today: ${count:-0}"
    fi
else
    echo "getenforce not found"
fi

section "Firewall"
if have firewall-cmd; then
    state=$(run firewall-cmd --state)
    echo "firewalld: $state"
    if [ "$state" = "running" ]; then
        run firewall-cmd --get-active-zones
    fi
else
    echo "firewall-cmd not found"
fi

section "Network"
have ip && run ip -br addr
have ip && echo && run ip route
echo
echo "Nameservers:"
grep -E '^(nameserver|search)' /etc/resolv.conf 2>/dev/null || echo "  /etc/resolv.conf not readable"

section "Listening TCP sockets"
if have ss; then
    if [ "$IS_ROOT" -eq 1 ]; then run ss -ltnp; else run ss -ltn; echo "(process names need root)"; fi
fi

if [ "$BRIEF" -eq 0 ]; then
    section "Top processes by CPU"
    ps -eo pid,user,%cpu,%mem,stat,etime,comm --sort=-%cpu 2>/dev/null | head -11

    section "Top processes by memory"
    ps -eo pid,user,%mem,rss,comm --sort=-rss 2>/dev/null | head -11

    section "Journal: errors this boot (last 25)"
    if have journalctl; then
        run journalctl -b -p err --no-pager -n 25 -q
    fi

    section "Kernel: OOM and I/O errors this boot"
    if have journalctl; then
        run journalctl -k -b --no-pager -q | grep -Ei 'out of memory|oom-kill|killed process|i/o error|blk_update_request' | tail -10
        echo "(end)"
    fi
fi

echo
echo "Snapshot complete. Nothing was changed."
