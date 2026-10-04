#!/usr/bin/env bash
# vpn-net-tune.sh - two network fixes for busy Xray/VPN servers
# (Ubuntu with systemd; tested on 22.04 / kernel 5.15, single- and multi-queue NICs)
#
#  1) net.ipv4.tcp_mtu_probe_floor = 1024
#     With tcp_mtu_probing=1, a connection that stalls for ~3 s gets its packet size cut to
#     1024 bytes, then halved on every further stall (512, 256, 128, 64), and it crawls
#     afterwards. The floor keeps black-hole detection but never goes below 1024.
#  2) Bigger fq packet queue: limit 50000 (default 10000), flow_limit 200 (default 100),
#     buckets 32768 (default 1024). Applied now and at every boot by fq-tune.service.
#
# Usage:  sudo bash vpn-net-tune.sh           apply both fixes (safe to run again)
#         sudo bash vpn-net-tune.sh --check   show the current state, change nothing
#         sudo bash vpn-net-tune.sh --undo    revert both fixes

set -u

SYSCTL_CONF=${SYSCTL_CONF:-/etc/sysctl.conf}
FQ_SCRIPT=${FQ_SCRIPT:-/usr/local/sbin/fq-tune.sh}
FQ_UNIT=${FQ_UNIT:-/etc/systemd/system/fq-tune.service}
FLOOR_PROC=${FLOOR_PROC:-/proc/sys/net/ipv4/tcp_mtu_probe_floor}
FLOOR=1024
KEY_RE='^[[:space:]]*net\.ipv4\.tcp_mtu_probe_floor[[:space:]]*='
COMMENT_RE='^# Keep TCP black-hole detection from shrinking MSS'
COMMENT='# Keep TCP black-hole detection from shrinking MSS below 1024 after loss bursts'

say()  { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
have_systemd() { command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; }

usage() {
    cat <<'EOF'
Usage: sudo bash vpn-net-tune.sh [--check | --undo]
  (no option)  apply both fixes (safe to run again)
  --check      show the current state, change nothing
  --undo       revert both fixes
EOF
}

default_dev() {
    local d
    d=$(ip -o route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [ -n "$d" ] || d=$(ip -6 -o route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    printf '%s' "$d"
}

fq_script_body() {
    cat <<'EOF'
#!/bin/sh
# Raise fq packet limits on the default-route interface (or the interface given as $1).
# Single-queue NIC: one fq at root. Multi-queue NIC: mq at root, one fq per TX queue.
DEV=${1:-$(ip -o route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')}
[ -n "$DEV" ] || DEV=$(ip -6 -o route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
[ -n "$DEV" ] || { echo "fq-tune: no default-route interface found" >&2; exit 1; }
LIMIT=50000; FLOW_LIMIT=200; BUCKETS=32768
NQ=$(ls -d /sys/class/net/"$DEV"/queues/tx-* 2>/dev/null | wc -l)
if [ "$NQ" -gt 1 ]; then
    L=$((LIMIT / NQ)); [ "$L" -lt 10000 ] && L=10000
    tc qdisc show dev "$DEV" | grep -q '^qdisc mq 1: root' || tc qdisc replace dev "$DEV" root handle 1: mq || exit 1
    i=1
    while [ "$i" -le "$NQ" ]; do
        tc qdisc replace dev "$DEV" parent 1:"$(printf %x "$i")" fq limit "$L" flow_limit "$FLOW_LIMIT" buckets "$BUCKETS" || exit 1
        i=$((i + 1))
    done
else
    tc qdisc replace dev "$DEV" root fq limit "$LIMIT" flow_limit "$FLOW_LIMIT" buckets "$BUCKETS" || exit 1
fi
tc qdisc show dev "$DEV"
EOF
}

fq_unit_body() {
    cat <<EOF
[Unit]
Description=Raise fq qdisc packet limits
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$FQ_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

fq_enabled() { have_systemd && systemctl is-enabled fq-tune.service >/dev/null 2>&1; }

show_status() {
    local dev nq probing floor small cc
    dev=$(default_dev)
    nq=$(ls -d /sys/class/net/"$dev"/queues/tx-* 2>/dev/null | wc -l)
    probing=$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || echo '?')
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')
    if [ -e "$FLOOR_PROC" ]; then floor=$(cat "$FLOOR_PROC"); else floor='n/a (kernel older than 5.4)'; fi
    small=$(ss -Htin state established 2>/dev/null | grep -oE '\bmss:[0-9]+' | awk -F: '$2<=512' | wc -l)
    say "  kernel / congestion : $(uname -r) / $cc"
    say "  interface           : ${dev:-not found} ($nq TX queue(s))"
    say "  tcp_mtu_probing     : $probing"
    say "  tcp_mtu_probe_floor : $floor"
    say "  conns with MSS<=512 : $small"
    if [ -n "$dev" ]; then
        tc -s qdisc show dev "$dev" 2>/dev/null | awk '
            /^qdisc/ { n++; lim = fl = bk = "-"
                       for (i = 1; i <= NF; i++) { if ($i == "limit") lim = $(i+1); if ($i == "flow_limit") fl = $(i+1); if ($i == "buckets") bk = $(i+1) }
                       where = ($4 == "root") ? "root" : $4 " " $5
                       if (n <= 3) printf "  queue               : %s %s %s, limit %s, flow_limit %s, buckets %s\n", $2, $3, where, lim, fl, bk }
            /Sent/ && n == 1 { for (i = 1; i <= NF; i++) if ($i == "(dropped") { d = $(i+1); sub(",", "", d) }
                               printf "  queue drops         : %s since the queue was created\n", d }
            END { if (n > 3) printf "  queue               : ... and %d more\n", n - 3 }'
    fi
    if fq_enabled; then say "  fq-tune.service     : enabled"; else say "  fq-tune.service     : not installed"; fi
}

verdict() {
    if [ ! -e "$FLOOR_PROC" ]; then
        say "  fix 1: not possible on this kernel (needs 5.4+)"
    elif [ "$(cat "$FLOOR_PROC")" -ge "$FLOOR" ]; then
        say "  fix 1: done"
    elif [ "$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null)" = 0 ]; then
        say "  fix 1: not needed (tcp_mtu_probing is off), harmless to apply"
    else
        say "  fix 1: NEEDED (tcp_mtu_probing is on and the floor is $(cat "$FLOOR_PROC"))"
    fi
    if fq_enabled; then say "  fix 2: done"; else say "  fix 2: NEEDED (fq queue limit not raised, or not kept across reboots)"; fi
}

apply_floor() {
    local self f seen=" "
    if [ ! -e "$FLOOR_PROC" ]; then
        warn "kernel $(uname -r) has no tcp_mtu_probe_floor (needs 5.4+): fix 1 skipped"
        return 0
    fi
    # Another sysctl file setting the same key could override ours at boot.
    self=$(readlink -f "$SYSCTL_CONF")
    for f in /etc/sysctl.d/*.conf /run/sysctl.d/*.conf /usr/local/lib/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf /lib/sysctl.d/*.conf; do
        [ -f "$f" ] || continue
        f=$(readlink -f "$f")
        case "$seen" in *" $f "*) continue ;; esac
        seen="$seen$f "
        [ "$f" = "$self" ] && continue
        grep -qE "$KEY_RE" "$f" && warn "$f also sets tcp_mtu_probe_floor - make sure it does not override $SYSCTL_CONF"
    done
    if [ "$(grep -cE "$KEY_RE" "$SYSCTL_CONF" 2>/dev/null)" = 1 ] \
       && grep -qxF "net.ipv4.tcp_mtu_probe_floor = $FLOOR" "$SYSCTL_CONF" \
       && [ "$(cat "$FLOOR_PROC")" = "$FLOOR" ]; then
        say "  fix 1: already in place"
        return 0
    fi
    if [ -f "$SYSCTL_CONF" ]; then
        cp -a "$SYSCTL_CONF" "$SYSCTL_CONF.bak-$(date +%Y%m%d-%H%M%S)" || die "cannot back up $SYSCTL_CONF"
        sed -i -E "/$KEY_RE/d; /$COMMENT_RE/d" "$SYSCTL_CONF" || die "cannot edit $SYSCTL_CONF"
        # Make sure the last line ends with a newline before appending.
        if [ -s "$SYSCTL_CONF" ] && [ -n "$(tail -c1 "$SYSCTL_CONF")" ]; then printf '\n' >> "$SYSCTL_CONF"; fi
    fi
    printf '%s\n%s\n' "$COMMENT" "net.ipv4.tcp_mtu_probe_floor = $FLOOR" >> "$SYSCTL_CONF" || die "cannot write $SYSCTL_CONF"
    sysctl -q -w net.ipv4.tcp_mtu_probe_floor="$FLOOR" || die "sysctl -w net.ipv4.tcp_mtu_probe_floor=$FLOOR failed"
    say "  fix 1: net.ipv4.tcp_mtu_probe_floor = $FLOOR (live, and saved in $SYSCTL_CONF)"
}

apply_fq() {
    local dev cur tmp changed=0
    command -v tc >/dev/null 2>&1 || die "tc not found (install the iproute2 package)"
    dev=$(default_dev)
    [ -n "$dev" ] || die "no default-route interface found"
    cur=$(tc qdisc show dev "$dev" 2>/dev/null | awk '$4 == "root" {print $2; exit}')
    case "$cur" in fq|mq) ;; *) say "  note: $dev uses '${cur:-none}' at the root; switching it to fq" ;; esac
    tmp=$(mktemp) || die "mktemp failed"
    fq_script_body > "$tmp"
    if ! cmp -s "$tmp" "$FQ_SCRIPT"; then
        install -m 755 "$tmp" "$FQ_SCRIPT" || { rm -f "$tmp"; die "cannot write $FQ_SCRIPT"; }
        changed=1
    fi
    fq_unit_body > "$tmp"
    if ! cmp -s "$tmp" "$FQ_UNIT"; then
        install -m 644 "$tmp" "$FQ_UNIT" || { rm -f "$tmp"; die "cannot write $FQ_UNIT"; }
        changed=1
    fi
    rm -f "$tmp"
    if have_systemd; then
        if [ "$changed" = 1 ]; then systemctl daemon-reload; fi
        systemctl enable -q fq-tune.service || die "could not enable fq-tune.service"
        systemctl restart fq-tune.service || die "fq-tune.service failed; see: journalctl -u fq-tune.service"
        say "  fix 2: fq queue raised on $dev; fq-tune.service re-applies it at every boot"
    else
        "$FQ_SCRIPT" >/dev/null || die "$FQ_SCRIPT failed"
        warn "systemd is not running: fix 2 is applied now but will NOT survive a reboot"
    fi
}

undo_all() {
    local dev had_fq=0 did1=0
    if grep -qE "$KEY_RE|$COMMENT_RE" "$SYSCTL_CONF" 2>/dev/null; then
        cp -a "$SYSCTL_CONF" "$SYSCTL_CONF.bak-$(date +%Y%m%d-%H%M%S)" || die "cannot back up $SYSCTL_CONF"
        sed -i -E "/$KEY_RE/d; /$COMMENT_RE/d" "$SYSCTL_CONF" || die "cannot edit $SYSCTL_CONF"
        did1=1
    fi
    if [ -e "$FLOOR_PROC" ] && [ "$(cat "$FLOOR_PROC")" = "$FLOOR" ]; then
        sysctl -q -w net.ipv4.tcp_mtu_probe_floor=48 || warn "could not reset tcp_mtu_probe_floor"
        did1=1
    fi
    if [ "$did1" = 1 ]; then
        say "  fix 1: reverted (tcp_mtu_probe_floor back to the kernel default 48)"
    else
        say "  fix 1: nothing to revert"
    fi
    [ -f "$FQ_UNIT" ] && had_fq=1
    if [ "$had_fq" = 1 ] && have_systemd; then systemctl disable -q --now fq-tune.service 2>/dev/null; fi
    rm -f "$FQ_UNIT" "$FQ_SCRIPT"
    if [ "$had_fq" = 1 ] && have_systemd; then systemctl daemon-reload; fi
    dev=$(default_dev)
    if [ "$had_fq" = 1 ] && [ -n "$dev" ]; then
        tc qdisc del dev "$dev" root 2>/dev/null
        say "  fix 2: reverted ($dev is back on its default queue)"
    else
        say "  fix 2: nothing to revert (fq-tune.service was not installed)"
    fi
}

main() {
    local mode=apply
    case "${1:-}" in
        "") ;;
        --check|check) mode=check ;;
        --undo|undo) mode=undo ;;
        -h|--help|help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    [ "$(id -u)" -eq 0 ] || die "run as root, e.g.: sudo bash $0 ${1:-}"
    command -v ip >/dev/null 2>&1 || die "ip not found (install the iproute2 package)"
    case "$mode" in
        check)
            say "Current state on $(hostname):"; show_status; say ""; verdict ;;
        apply)
            say "Before ($(hostname)):"; show_status; say ""
            say "Applying:"; apply_floor; apply_fq; say ""
            say "After:"; show_status; say ""; verdict
            say ""
            say "Connections that were already shrunk recover over the next few minutes;"
            say "run 'sudo bash $0 --check' later to watch 'conns with MSS<=512' drop." ;;
        undo)
            say "Reverting on $(hostname):"; undo_all; say ""
            say "After:"; show_status ;;
    esac
}

main "$@"
