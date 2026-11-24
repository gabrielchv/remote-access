# Phone → this machine, from anywhere

Goal: run a terminal on `gazerah`'s Pop!_OS laptop from a phone, on 4G or any
WiFi, without exposing anything to the public internet.

## The recommendation

**Tailscale + SSH (keys only) + tmux + mosh.**

Tailscale is a WireGuard mesh with a coordination server. Your laptop and your
phone each get a stable `100.x.y.z` address and a MagicDNS name, and they talk
end-to-end encrypted. No port forwarding, no public IP, no exposure to scanners.

Why this and not the alternatives:

- **Port-forward + sshd on the router** — technically possible here (public IPv4
  `191.193.232.192`, not CGNAT) but it puts sshd on the open internet, which
  means constant credential-stuffing traffic and one misconfiguration away from
  compromise. Rejected.
- **Cloudflare Tunnel / ngrok** — good for a web app, mediocre for a shell. You
  get an account-bound public hostname and a third party terminating TLS in
  front of your login prompt. More moving parts than a mesh VPN.
- **Self-hosted WireGuard** — excellent crypto, but you need a reachable
  endpoint (VPS or port forward) plus your own key distribution and DNS. That is
  exactly the work Tailscale already did, and `Headscale` exists if you later
  want Tailscale's UX with your own control plane.
- **Tailscale** — NAT traversal works from 4G/CGNAT, hotel and café WiFi;
  identity is device-based (revoke a phone from the admin console instantly);
  ACLs let you say "phone may reach port 22 on this host and nothing else";
  MagicDNS means you never chase a changing home IP.

## Your router is not your laptop

A Tailscale instance on the home router (OpenWrt, or an official router image)
is its own node. It does **not** put your laptop on the tailnet. Two separate
things get confused here:

- **Subnet router** — the router can advertise `192.168.15.0/24` so remote
devices reach *home LAN devices* by LAN IP. Useful for a NAS or printer sitting
at home. It does nothing for a laptop that has left the house, because the
laptop is no longer on that subnet.
- **An agent on the laptop** — makes the laptop its own node with its own stable
  `100.x` address. This is what gives you access from 4G, a café, or a friend's
  house.

So: install the client on the laptop too. That is the piece that answers "can I
reach it from anywhere."

Identity is **device-based, not network-based**. Neither end cares which WiFi it
is on. That, plus the laptop's `100.x` address never changing, is the whole point
of the mesh.

### Watch out: identical LAN subnets

`192.168.15.0/24` is a common Vivo router default. If your home LAN and the LAN
you are visiting are both `192.168.15.0/24`, and the home router advertises that
subnet, `tailscaled` will refuse to install the overlapping route locally (by
design) and log a conflict. Your laptop is still reachable at its `100.x`
address — only the home-LAN-by-IP path degrades while you are on a colliding
subnet. Not a blocker; just don't debug it as "Tailscale is broken."

## Threat model, stated plainly

A terminal on your phone is a **full shell on your laptop**. That means:

- Compromise of the phone = compromise of the laptop, including `~/`, keys,
  Git remotes, and any credentials in this repo tree.
- Therefore the phone itself is part of the security boundary: OS updated,
  screen lock/biometrics on, no sideloaded junk, and Tailscale installed from the
  official store.

Controls that make this defensible:

- **Nothing listens publicly.** sshd is reachable only over the tailnet (and your
  LAN). No router forwards.
- **Keys only.** `PasswordAuthentication no`, `PermitRootLogin no`,
  `AllowUsers gazerah`. There is no password to brute force.
- **Tailnet ACL** decides who may reach what. Replace the default
  "allow everything" with something narrower — see below.
- **Device removal is instant.** Admin console → Machines → remove. Also enable
  key expiry; re-auth after the expiry window is a feature, not a nuisance.
- **2FA on the Tailscale account** (this is the real root of trust: whoever owns
  the account can enroll devices).
- **Never `tailscale funnel`.** Funnel publishes a service to the public
  internet. Serve is tailnet-only; Funnel is not. One word apart, very different.
- **Never run a terminal server with authentication disabled** (`--insecure-no-auth`
  style flags) on anything but loopback.
- **Tailscale SSH** (`tailscale up --ssh`) authenticates via tailnet identity
  instead of keys — convenient from a phone, but it moves the trust decision
  entirely into the ACL and your Tailscale account. Re-auth prompts appear
  periodically (12h `check` mode by default); set `"action": "accept"` in the
  `ssh` ACL rule to disable them.

### Suggested tailnet ACL

Tailscale admin → Access controls. Keep your own devices unrestricted-ish, and
pin the phone down:

```jsonc
{
  "tagOwners": { "tag:phone": ["autogroup:admin"] },
  "acls": [
    // admin devices: full access to admin devices
    { "action": "accept", "src": ["autogroup:admin"], "dst": ["autogroup:admin:*"] },
    // the phone may only open ssh (and mosh's UDP range) on this host
    { "action": "accept", "src": ["tag:phone"], "dst": ["gazerah:22,60000-61000"] }
  ],
  "ssh": [
    { "action": "accept", "src": ["tag:phone"], "dst": ["gazerah"], "users": ["gazerah"] }
  ]
}
```

Tag the phone in the admin console after enrolling it (`tag:phone`), or the
`src` selector will never match.

## Phone clients

**Android** — Termux (F-Droid or Play). Real `ssh`, real `mosh`, real keys:

```
pkg update && pkg install openssh mosh tmux
ssh-keygen -t ed25519 -C phone
```

Add `~/.shortcuts/` script or use Termux:Widget for a one-tap "connect".

**iOS** — Blink Shell (paid, best keyboard, mosh + ssh + Files integration) or
Termius (free tier, mosh on paid). Both handle ed25519 keys in the keychain.

Extra keyboard: any compact Bluetooth keyboard turns the phone into a usable
terminal. On-glass typing for a full-screen TUI is painful, not impossible.

## Using it

`~/remote-access/setup.sh` does the install side. Then:

```bash
# on the laptop, once per boot (or systemd user unit)
tmux new -As main htop    # or whatever you keep open

# from the phone
mosh gazerah@gazerah        # or: ssh gazerah@gazerah
tmux attach -t cw
```

tmux is what makes this feel good: close the app, switch WiFi→4G, lose signal in
a tunnel, reconnect and your session is exactly where you left it.
mosh is what makes it feel *reliable*: it survives IP changes and dropped
packets, and does local echo so typing doesn't lag over a bad link.

Detach: `Ctrl-b d`. List: `tmux ls`. Kill: `tmux kill-session -t cw`.

### Full-screen apps over the phone

- Long-running TUIs survive a dropped link because tmux holds the session; the
  client only reattaches. That is the whole trick — nothing special about the
  program itself.
- Resize is the usual annoyance: after rotating the phone, `Ctrl-b` then
  `Shift-d` detaches and reattaches at the new size.
- If an app insists on binding to loopback only (many do, for good reasons),
  keep the SSH session and run it there; do not open it to the tailnet.

## Operational gotchas

- **Suspend kills access.** A closed lid means no shell. On AC power, set
  Settings → Power → Automatic Suspend → Off (or keep the machine on AC when you
  expect to need it). `systemd-inhibit --what=sleep --why="remote session"
  --mode=block sleep infinity` holds it awake for a window.
- **Docker bypasses ufw.** Anything a container publishes on `0.0.0.0` is
  reachable from your LAN regardless of ufw rules, because Docker writes its own
  nftables chains. Check `docker ps --format '{{.Names}} {{.Ports}}'` for
  `0.0.0.0:` publishes. Not a tailnet risk, but it is a LAN risk.
- **CAPTIVE PORTALS.** On café/hotel WiFi, complete the portal in the browser
  first, then turn Tailscale on.
- **Battery.** Tailscale's idle cost is small (WireGuard keepalives). The phone's
  radio while actively in a mosh session is the real draw.
- **If it stops working**, in order: `tailscale status` on both devices →
  `sudo systemctl status ssh` → `ss -tlnp | grep :22` →
  `sudo journalctl -u ssh -n 50`.

## If you don't want a third-party control plane

`Headscale` (self-hosted Tailscale-compatible control server) gives the same
client apps and the same WireGuard data plane, with you owning coordination. Cost:
a VPS, DNS, TLS, and backups. Only worth it if Tailscale's coordination server is
a dealbreaker for you.
