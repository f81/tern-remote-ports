---
name: release
description: >-
  Release procedure for the Ports Tern plugin: bump the version in plugin.toml, commit it as
  "ports <version>: <what changed>", tag v<version>, publish the GitHub release, and verify the
  running plugin shows the version. Use when cutting a release, bumping the version, tagging or
  publishing a build of this plugin, or when a user asks for the latest version.
---

# Releasing Ports

Tern never compares plugin versions. The `version` key in `plugin.toml` is free-form text that
Tern only shows (`tern plugin list`, Preferences, the install output); there is no update command
and no dependency resolution. So a release is three things that must agree:

| Piece | What it is |
| --- | --- |
| `plugin.toml` `version` | What Tern displays. The single source of truth. |
| git tag `v<version>` | What a user pins. Annotated, on the release commit. |
| GitHub release | The notes for that tag. |

`schema = 1` in the manifest is the manifest format, not the plugin version: never touch it.

## Procedure

1. **Bump `plugin.toml`.** `version = "0.1.0"` → the new version. Semver-ish: `0.x.y` while the
   plugin is young; `1.0.0` when its behaviour is stable. Every release gets a new version, even
   a small fix, so a bug report can name the build it came from.
2. **Check the tree.** `git status` and `git log --oneline -5`. Work in this repo can be in flight
   from another session: do not sweep unrelated changes into a release commit without asking.
   `tern.d.luau` is generated and gitignored; leave it.
3. **Commit.** `git commit -m "ports <version>: <what changed>"` — the plugin name, the version,
   then the change in one line. That title is the release's summary.
4. **Tag.** `git tag -a v<version> -m "ports <version>: <summary>"` — annotated, same wording.
   One tag per release; never move a published tag.
5. **Push.** `git push origin main` and `git push origin v<version>`.
6. **Publish.** `gh release create v<version> --title "ports <version>" --notes "<notes>"`. The
   notes are for users: what the release does, and the install command
   (`tern plugin install github.com/f81/tern-remote-ports`). Keep the repo's `tern-plugin` topic
   and its description; they are what makes the plugin findable.
7. **Verify** (below), then report the release URL.

## Verify

```sh
tern plugin reload
tern plugin list          # ports <version> Ports — window ready
```

`ready` means the half loaded without raising. The Ports panel shows the version in its head
(`· ports 0.1.0`); the window half reads it out of `plugin.toml` at load, so a reload is enough
to see a new version. To check the running app, drive it:

```sh
printf 'plugins run plugin.ports.show\nwait 2000\n' > /tmp/ports-check.txt
tern ctl --file /tmp/ports-check.txt
tern ctl tree | grep -o 'ports [0-9.]*'
```

## Rules

- **Never hardcode the version in Lua.** `window.luau` reads `plugin.toml` (`manifest_version`);
  the manifest is the only place a version lives.
- **Never bump the version without releasing it**, and never tag a commit whose `plugin.toml`
  version differs from the tag: `v0.2.0` must sit on a commit whose manifest says `0.2.0`.
- **`main` stays installable.** `tern plugin install` clones the tip of the default branch, so
  the branch must always work.
- **Pinning needs a manual clone.** `tern plugin install` takes no tag; a user who wants
  `v0.1.0` clones it (`git clone --branch v0.1.0 --depth 1 …`) and installs that folder. The
  README's *Versions* section says so.

## Installs and updates

- Install: `tern plugin install github.com/f81/tern-remote-ports` (copies the package).
- Update: install again with `--force`, or `git pull` in a linked checkout.
- Develop: `tern plugin link <dir>` loads the folder in place and reloads it on save.

The plugin's data (`kv.json`, the saved forwards) lives in Tern's plugin-data folder, not in the
package, so an update keeps the user's forwards.
