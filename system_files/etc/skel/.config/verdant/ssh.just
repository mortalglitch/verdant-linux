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
# enablement). enable starts the service first, then opens the port (no
# window where the port is open with nothing listening); disable closes the
# port first, then stops the service. Both are idempotent.

# default: status
default: status

# enable: start sshd and open port 22 (ssh) in the default firewall zone
enable:
    #!/usr/bin/env bash
    set -euo pipefail
    sudo systemctl enable --now sshd.service sshd.socket
    zone="$(sudo firewall-cmd --get-default-zone)"
    if ! sudo firewall-cmd --permanent --zone="$zone" --query-service=ssh; then
      sudo firewall-cmd --permanent --zone="$zone" --add-service=ssh
      sudo firewall-cmd --reload
    fi
    echo "SSH enabled: sshd running, port 22 open in zone '$zone'"

# disable: close port 22 in the default firewall zone, then stop sshd
disable:
    #!/usr/bin/env bash
    set -euo pipefail
    zone="$(sudo firewall-cmd --get-default-zone)"
    if sudo firewall-cmd --permanent --zone="$zone" --query-service=ssh; then
      sudo firewall-cmd --permanent --zone="$zone" --remove-service=ssh
      sudo firewall-cmd --reload
    fi
    sudo systemctl disable --now sshd.service sshd.socket
    echo "SSH disabled: port 22 closed in zone '$zone', sshd stopped"

# status: current SSH state (service + firewall), read-only, no sudo needed
status:
    #!/usr/bin/env bash
    set -uo pipefail
    echo "sshd enabled: $(systemctl is-enabled sshd.service 2>/dev/null || echo unknown)"
    echo "sshd active:  $(systemctl is-active sshd.service 2>/dev/null || echo unknown)"
    zone="$(grep -m1 '^DefaultZone=' /etc/firewalld/firewalld.conf 2>/dev/null | cut -d= -f2)"
    [ -n "$zone" ] || zone=public
    zf="/etc/firewalld/zones/$zone.xml"
    [ -f "$zf" ] || zf="/usr/lib/firewalld/zones/$zone.xml"
    if [ -f "$zf" ] && grep -q '<service name="ssh"/>' "$zf"; then
      echo "firewall:   port 22 (ssh) OPEN in zone '$zone'"
    else
      echo "firewall:   port 22 (ssh) closed in zone '$zone'"
    fi
