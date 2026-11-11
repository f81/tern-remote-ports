# Ports

A Tern plugin that forwards localhost ports to ports on ssh hosts, like
VS Code's Ports view: pick a host, pick one of the ports listening there,
and it is on `localhost`.

## Install

```sh
tern plugin install github.com/f81/tern-remote-ports
```

To work on the plugin itself, link a checkout instead; Tern loads it from
there and reloads it when you save:

```sh
tern plugin link ~/Documents/tern-plugins/ports
```

## Use

| Palette command | Does |
| --- | --- |
| Forward a port from an ssh host… | Picks a host (recent ones, Tern's remote hosts, `~/.ssh/config`, or any `user@host`), lists the TCP ports listening there, forwards the one you pick. **Another port…** takes `8080`, `3000:8080` (local:remote), `db.internal:5432` or `5432:db.internal:5432` (through the host) |
| Show forwarded ports | A panel: the forwards with their state, Open and Stop, and per host the listening ports with a Forward button (a port already forwarded shows a green `localhost:N` button that opens it), Rescan, Disconnect |
| Stop forwarding a port… | Cancels one forward |
| Open a forwarded port in the browser… | Opens `http://localhost:<port>` |
| Disconnect an ssh host from Ports… | Ends the host's ssh connection and its forwards |

Opening a port follows Tern's "Where web links open" setting (`link_target`):
`Browser` uses the system's default browser, `Tern` a Tern browser tab.

The status line shows the forwards (`localhost:3000`, `2 ports`, `… · 1 down`);
clicking it opens the panel.

The local port matches the remote port. Ports below 1024 get 10000 added
(80 → 10080). A local port already in use moves to the next free one.

## How it works

The plugin has only a window half, which runs on this machine. A host half
would run wherever the panes run, and that can be the remote itself.

- **macOS/Linux: one connection per host.** Each host has one OpenSSH control master
  (`ssh -M -f -N`) on a socket in `$XDG_RUNTIME_DIR` or `$TMPDIR`. Forwards
  are added and removed with `ssh -O forward` and `ssh -O cancel` on that
  socket, so no ssh process runs per forward. The master stays up across
  windows, plugin reloads and Tern restarts until you disconnect or the link
  drops.
- **One connection per machine.** A machine often has several names: `gx10`
  and `gx10.tailnet.ts.net`, or an alias from `~/.ssh/config`. Ports treats
  two names as the same machine when `ssh -G` gives them the same user, and
  they also share an address or a server host key in known_hosts. Picking a
  second name reuses the connection the panel already has. A duplicate host
  with no forwards is dropped from the panel, and its connection is closed.
- **Windows: one process per forward.** Windows OpenSSH does not support
  control-socket multiplexing. Ports uses `ssh -N -L` without a control
  socket, reads local listeners with `netstat` and `tasklist`, and stops
  tunnels with `taskkill`. Keys or an ssh agent are required: an interactive
  password login cannot authenticate subsequent forwarding processes.
- **Listening ports.** The command runs over SSH in the remote's login shell:
  - macOS, Linux and BSD: an `sh` script using `ss -ltnpH`, else `lsof`,
    else `netstat`.
  - Windows (OpenSSH Server with cmd or PowerShell): `netstat -ano` for the
    ports and `tasklist` for the program names. It runs when the `sh` script
    gets no answer, and the plugin remembers which one worked for each host.
- **Saved state.** The forwards you asked for, and the reconnect schedule,
  are kept in the plugin's `kv.json`, which every window shares.
- **Checks every 10 s.**
  - On macOS/Linux, `ssh -O check` tells whether each master is up.
  - Local listeners come from `lsof`, or `netstat`/`tasklist` on Windows.
  - A forward whose host is connected but whose port isn't held is added again.
    This happens after a reconnect, or when something cancelled it.
  - A forward whose port another program also holds is marked **Port taken
    here**. ssh binds both 127.0.0.1 and ::1 and reports success if either
    one binds.

## Connecting

Connections run with `BatchMode=yes`, so keys and the ssh agent work without
prompts. When a connection needs a password, a passphrase or a new host key,
the plugin offers **Connect in a terminal**. That opens a local tab running
the same master where ssh can ask, on this machine. If no local terminal
opens, the command goes to the clipboard instead, to paste into one. The
plugin waits for the master (up to 3 minutes), then carries on with what
you were doing.

On Windows, **Connect in a terminal** instead runs a one-time login to accept
the host key. Load your key into the ssh agent before forwarding; passwords
entered in that terminal do not carry over to tunnels. There is no master.

A host carrying forwards reconnects on its own whenever it is down: after
its link drops, or when Tern starts. Ports retries without prompts, waiting
10 s, 30 s, 1 min, 2 min, then 5 min between tries, and the forwards come
back once it is connected. The windows share one schedule, so a host gets
one try at a time however many windows are open. The panel shows the last
error and when the next try is due.

Tries stop when the login needs a prompt: a refused key or password login,
or an unknown or changed host key. Trying again would fail the same way,
and repeated failed logins can get your address banned (fail2ban,
sshguard). The host then waits for **Connect** or **In a terminal**, and
either one starts the tries over. Stopping a host's last forward or
**Forget** ends them. Other connections start only when you ask.

## Versions

The version lives in the `version` key of `plugin.toml`, and the Ports
panel shows it in its head, so a bug report can name the build it came
from. Tern never compares versions: it shows the one you have and leaves
updating to you.

Releases are git tags, `v0.1.0`, `v0.2.0`, …, each with a GitHub release
and its notes. `tern plugin install` clones the tip of the default branch,
so pinning a release means cloning the tag yourself:

```sh
git clone --branch v0.1.0 --depth 1 https://github.com/f81/tern-remote-ports
tern plugin install ./tern-remote-ports
```

To follow the tip instead, install from the repository and update with
`tern plugin install github.com/f81/tern-remote-ports --force`, or
`git pull` in a linked checkout.

Release commits are titled `ports <version>: <what changed>`, and the tag
carries the same version.

## Requirements

- OpenSSH 7.7 or later (for `ssh://` destinations and `-O forward`).
- On macOS/Linux, `lsof` on this machine, which macOS ships. Without it,
  forwards are only checked through the master. Windows uses its built-in
  `netstat`, `tasklist`, and `taskkill` instead.
- On the remote, to list its ports: `ss`, `lsof` or `netstat` on Unix, or
  nothing extra on Windows.
