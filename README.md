# Ports

A Tern plugin that forwards localhost ports to ports on ssh hosts, like
VS Code's Ports view: pick a host, pick one of the ports listening there,
and it is on `localhost`.

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

- **One connection per host.** Each host has one OpenSSH control master
  (`ssh -M -f -N`) on a socket in `$XDG_RUNTIME_DIR` or `$TMPDIR`. Forwards
  are added and removed with `ssh -O forward` and `ssh -O cancel` on that
  socket, so no ssh process runs per forward. The master stays up across
  windows, plugin reloads and Tern restarts until you disconnect or the link
  drops.
- **Listening ports.** These come from `ss -ltnpH` on the remote. Hosts
  without `ss` fall back to `lsof`, then `netstat`. The command runs through
  the master.
- **Saved state.** The forwards you asked for are kept in the plugin's
  `kv.json`, which every window shares.
- **Checks every 10 s.**
  - `ssh -O check` tells whether each master is up.
  - `lsof` lists the ports listening locally.
  - A forward whose master is up but whose port isn't held is added again.
    This happens after a reconnect, or when something cancelled it.
  - A forward whose port another program also holds is marked **Port taken
    here**. ssh binds both 127.0.0.1 and ::1 and reports success if either
    one binds.

## Connecting

Connections run with `BatchMode=yes`, so keys and the ssh agent work without
prompts. When a connection needs a password, a passphrase or a new host key,
the plugin offers **Connect in a terminal**. That opens a local tab running
the same master where ssh can ask. The plugin waits for the master (up to
3 minutes), then carries on with what you were doing.

Masters only start when you ask. When a link drops, the panel shows the host
as disconnected with a **Connect** button, and its forwards come back once
it is connected again.

## Requirements

- OpenSSH 7.7 or later (for `ssh://` destinations and `-O forward`).
- `lsof` on this machine, which macOS ships. Without it, forwards are only
  checked through the master.
- `ss`, `lsof` or `netstat` on the remote, to list its ports.
