#!/usr/bin/env bash
# Phone access to this machine: Tailscale (private mesh) + OpenSSH (keys only) + mosh + tmux.
#
# Run from your own terminal, not from inside a tmux session:
#     sudo bash ~/remote-access/setup.sh
#     sudo bash ~/remote-access/setup.sh --firewall   # also enable ufw, tailnet-only
#
# Idempotent: safe to re-run.
set -euo pipefail

TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo gazerah)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
ENABLE_FIREWALL=0
[[ "${1:-}" == "--firewall" ]] && ENABLE_FIREWALL=1

log() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run this with sudo, from your own terminal"
[[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]] || die "could not resolve home for '$TARGET_USER'"

# ---------------------------------------------------------------- 1. packages
log "Installing tailscale, openssh-server, mosh"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl openssh-server mosh

if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi
command -v tailscale >/dev/null || die "tailscale install failed"
systemctl enable --now tailscaled
systemctl enable --now ssh

# ---------------------------------------------------------------- 2. sshd
log "Hardening sshd (key-only, no root, no passwords)"
install -d -m 0755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-remote-hardening.conf <<EOF
# Managed by ~/remote-access/setup.sh
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PermitEmptyPasswords no
X11Forwarding no
AllowUsers $TARGET_USER
MaxAuthTries 3
ClientAliveInterval 60
ClientAliveCountMax 3
EOF
sshd -t || die "sshd config invalid; inspect /etc/ssh/sshd_config.d/10-remote-hardening.conf"
systemctl restart ssh

# ---------------------------------------------------------------- 3. keys
log "Preparing $TARGET_USER's authorized_keys"
install -d -m 0700 -o "$TARGET_USER" -g "$TARGET_USER" "$TARGET_HOME/.ssh"
AUTH="$TARGET_HOME/.ssh/authorized_keys"
touch "$AUTH"
if ! grep -qE '^[^#].*(ssh-ed25519|ssh-rsa|ecdsa-sha2)' "$AUTH"; then
  if [[ -s "$TARGET_HOME/.ssh/id_ed25519.pub" ]]; then
    cat "$TARGET_HOME/.ssh/id_ed25519.pub" >> "$AUTH"
    echo "  seeded with this machine's own id_ed25519.pub"
  else
    echo "  WARNING: authorized_keys is empty — add your phone's public key (next steps below)"
  fi
fi
chown "$TARGET_USER:$TARGET_USER" "$AUTH"
chmod 0600 "$AUTH"

# ---------------------------------------------------------------- 4. optional firewall
if [[ $ENABLE_FIREWALL -eq 1 ]]; then
  log "Restricting inbound to the tailnet only (ufw)"
  ufw --force default deny incoming
  ufw allow in on tailscale0 to any port 22 proto tcp comment 'ssh over tailnet'
  ufw allow in on tailscale0 to any port 60000:61000 proto udp comment 'mosh over tailnet'
  ufw --force enable
  echo "  NOTE: default-deny also blocks LAN mDNS. If Spotify Connect on your"
  echo "        phone/LAN speakers stops working, re-allow with:"
  echo "        sudo ufw allow in on wlp0s20f3 to any port 5353 proto udp"
else
  echo
  echo "  Skipped ufw (pass --firewall to enable). sshd is reachable on the LAN"
  echo "  and tailnet; do NOT port-forward 22 on the router."
fi

# ---------------------------------------------------------------- 5. status
log "Done. Current tap addresses"
ip -brief addr show tailscale0 2>/dev/null || echo "  tailscale0 not up yet — run 'sudo tailscale up' (see next steps)"

cat <<EOF

$(printf '\033[1mNext steps\033[0m')

1) Join the tailnet (prints a login URL; open it on this machine):
     sudo tailscale up --hostname=$(hostname -s)

   Optional: add --ssh to authenticate with your tailnet identity instead of
   SSH keys (no key copying from the phone; needs an SSH rule in the ACL):
     sudo tailscale up --hostname=$(hostname -s) --ssh

2) Install Tailscale on the phone and log in with the SAME account.
   Turn the VPN toggle on. Reboot-proof it in the app settings.

3) Get the phone's public key onto this machine. Easiest: from the phone,
     ssh-keygen -t ed25519 -C phone        # Termux / Blink
   then send the .pub line to yourself and append it to $AUTH
   (or run:  ssh-copy-id -i phone_key.pub $TARGET_USER@<tailscale-ip>)

4) From the phone:
     ssh $TARGET_USER@$(hostname -s)          # MagicDNS resolves the hostname
     mosh $TARGET_USER@$(hostname -s)         # better: survives WiFi <-> 4G

5) Keep your session in tmux so it survives disconnects:
     tmux new -As main htop

EOF
