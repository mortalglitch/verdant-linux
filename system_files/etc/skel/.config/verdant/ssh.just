# ssh.just — optional SSH access for Verdant
#
#   just -f ~/.config/verdant/ssh.just enable    # start sshd + open port 22
#   just -f ~/.config/verdant/ssh.just disable   # close port 22 + stop sshd
#   just -f ~/.config/verdant/ssh.just status    # current state (no password needed)
#
# (or via the wrapper in ~/.justfile: `just ssh <enable|disable|status>`)
#
# Verdant ships with a public-style firewall zone (ssh removed) and sshd
# disabled. All changes are persistent (firewall zone file + systemd
# enablement). Both are idempotent.
#
# We use Fedora's socket-activated sshd: sshd.socket owns port 22 and spawns
# sshd.service per connection. The two units must never be started together —
# sshd.socket carries Conflicts=sshd.service, so `systemctl start sshd.service
# sshd.socket` in one transaction fails with "conflicting jobs 'stop' and
# 'start' for sshd.service". enable therefore switches to socket mode (stopping
# the standalone daemon first); disable closes the port, then stops the socket,
# then the daemon.

# default: status
default: status

# enable: switch to socket-activated sshd (socket owns port 22) and open port 22 (ssh) in the default firewall zone
enable:
    #!/usr/bin/env bash
    set -euo pipefail
    # sshd.socket (Conflicts=sshd.service) and the standalone daemon cannot both run
    sudo systemctl disable --now sshd.service
    sudo systemctl enable --now sshd.socket
    zone="$(sudo firewall-cmd --get-default-zone)"
    if ! sudo firewall-cmd --permanent --zone="$zone" --query-service=ssh; then
      sudo firewall-cmd --permanent --zone="$zone" --add-service=ssh
      sudo firewall-cmd --reload
    fi
    echo "SSH enabled: sshd socket-activated, port 22 open in zone '$zone'"

# disable: close port 22 in the default firewall zone, then stop the socket and daemon
disable:
    #!/usr/bin/env bash
    set -euo pipefail
    zone="$(sudo firewall-cmd --get-default-zone)"
    if sudo firewall-cmd --permanent --zone="$zone" --query-service=ssh; then
      sudo firewall-cmd --permanent --zone="$zone" --remove-service=ssh
      sudo firewall-cmd --reload
    fi
    sudo systemctl disable --now sshd.socket
    sudo systemctl disable --now sshd.service
    echo "SSH disabled: port 22 closed in zone '$zone', sshd stopped"

# status: current SSH state (service + firewall), read-only, no sudo needed
status:
    #!/usr/bin/env bash
    set -uo pipefail
    # is-enabled/is-active exit non-zero for disabled/inactive — capture the
    # text first, fall back to "unknown" only when there is no output at all
    q() { local out; out="$(systemctl "$1" "$2" 2>/dev/null)" || true; [ -n "$out" ] && printf '%s' "$out" || printf '%s' "unknown"; }
    echo "sshd.socket enabled: $(q is-enabled sshd.socket)"
    echo "sshd.socket active:  $(q is-active sshd.socket)"
    echo "sshd.service active: $(q is-active sshd.service) (per-connection instances in socket mode)"
    zone="$(grep -m1 '^DefaultZone=' /etc/firewalld/firewalld.conf 2>/dev/null | cut -d= -f2)"
    [ -n "$zone" ] || zone=public
    zf="/etc/firewalld/zones/$zone.xml"
    [ -f "$zf" ] || zf="/usr/lib/firewalld/zones/$zone.xml"
    if [ -f "$zf" ] && grep -q '<service name="ssh"/>' "$zf"; then
      echo "firewall:   port 22 (ssh) OPEN in zone '$zone'"
    else
      echo "firewall:   port 22 (ssh) closed in zone '$zone'"
    fi
