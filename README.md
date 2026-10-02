---
__cgxx: |
  # vim:set expandtab shiftwidth=2 filetype=markdown foldlevel=3:
  # SPDX-License-Identifier: GPL-3.0-only

  #
  #
  # ~chewygumxx/cloudflare-ddns.git
  # ::: :/README.md
  #
  #

ctime: 2026-08-20
title: cloudflare-ddns
description: "Dynamic DNS implementation for Cloudflare with systemd, jq, curl, and bash."
tags:
  - cloudflare
  - ddns
  - systemd
---

# cloudflare-ddns

> [!NOTE]
> This project is largely superseded by
> [`cloudflared`](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/),
> whose Cloudflare Tunnel reaches a host without a public `A` record to keep in
> sync. The script and units still work, and are kept for hosts that need a
> plain DNS record.

A small dynamic DNS client for Cloudflare: a `bash` + `curl` + `jq` script
that compares your public IPv4 address against an existing Cloudflare `A`
record and `PATCH`es the record only when the two have drifted apart. It
ships as a templated `systemd --user` service and timer, so any number of
records can be kept in sync on independent schedules, with nothing else
running in the background.

## How it works

1. Resolve the machine's public IPv4 address via Cloudflare's own
   `cdn-cgi/trace` endpoint, forced over IPv4 so dual-stack hosts always
   compare against the address that actually matters for an `A` record.
2. Fetch the target record via the [Cloudflare API v4][cf-api], and stop
   with an error if its name isn't `RECORD_NAME`, which catches a
   `RECORD_ID` pointing at the wrong record.
3. Compare its `content`, `ttl` and `proxied` with the public address and
   the configured `TTL` and `PROXIED`. If all three already match, exit
   `0` immediately, no write, no API quota spent.
4. Otherwise, log what differs and `PATCH` those three fields, with a
   `comment` naming the script, so the record's edit history in the
   dashboard shows what last touched it. The configuration is the source
   of truth: a `ttl` or `proxied` changed in the dashboard is put back on
   the next run.
5. curl retries transient failures (timeouts, refused connections, HTTP
   `408`, `429` and `5xx`) itself. If any step still fails (a bad token, a
   stale record ID, a network outage), the script exits non-zero, and the
   service unit's `Restart=on-failure` retries it, starting after 30
   seconds and backing off to 15 minutes, the timer's own interval.

The script only ever _updates_ an existing record; it never creates one,
and it manages a single `A` record per instance (see
[Limitations](#limitations)).

[cf-api]: https://developers.cloudflare.com/api/

## Requirements

- `bash`
- `curl`
- `jq`
- `systemd`

None of these are unusual on a current Linux install; check your
distribution's package manager if any are missing.

## Installation

Install the script and the two unit files into the standard
[XDG][xdg-spec] locations with `make install`, or by hand:

```sh
install -Dm755 cloudflare-ddns \
    "$HOME/.local/bin/cloudflare-ddns"
install -Dm644 cloudflare-ddns@.service \
    "$XDG_CONFIG_HOME/systemd/user/cloudflare-ddns@.service"
install -Dm644 cloudflare-ddns@.timer \
    "$XDG_CONFIG_HOME/systemd/user/cloudflare-ddns@.timer"
```

`make uninstall` removes them again.

[xdg-spec]: https://specifications.freedesktop.org/basedir-spec/latest/

## Configuration

Each systemd instance sources its own environment file, loaded securely
through systemd's [credential mechanism][sd-creds] rather than a plain
`EnvironmentFile=`. For an instance named `<name>`, that file lives at:

```sh
$XDG_CONFIG_HOME/cloudflare-ddns/<name>
```

(typically `~/.config/cloudflare-ddns/<name>`). Create it and restrict its
permissions, since it holds a plaintext API token at rest:

```sh
install -d -m700 "$XDG_CONFIG_HOME/cloudflare-ddns"
$EDITOR "$XDG_CONFIG_HOME/cloudflare-ddns/<name>"
chmod 600 "$XDG_CONFIG_HOME/cloudflare-ddns/<name>"
```

[sd-creds]: https://systemd.io/CREDENTIALS/

It should set the following as plain shell `KEY=value` assignments:

| Variable      | Required | Default | Notes                                                                |
| ------------- | -------- | ------- | -------------------------------------------------------------------- |
| `API_TOKEN`   | yes      | -       | Cloudflare token scoped to `Zone:DNS:Edit` for the zone              |
| `ZONE_ID`     | yes      | -       | Zone ID that owns the record                                         |
| `RECORD_NAME` | yes      | -       | Fully qualified record name, e.g. `home.example.com`                 |
| `RECORD_ID`   | yes      | -       | ID of the _existing_ `A` record to update                            |
| `TTL`         | no       | `300`   | Seconds; forced to `1` ("Automatic") by Cloudflare if `PROXIED=true` |
| `PROXIED`     | no       | `false` | Literal `true`/`false`, parsed as JSON, not a general shell boolean  |
| `DEBUG`       | no       | `0`     | Set to `1` to log when the record is already in sync                 |

### Getting the IDs and token

- Zone ID
  - Shown on the domain's Overview page in the Cloudflare dashboard.
- API Token
  - Create one under _My Profile → API Tokens_, scoped to
    `Zone → DNS → Edit` for just this zone. That's the conventional
    least-privilege approach; a Global API Key can do this too but grants
    far more than the script needs.
- Record ID
  - Not shown anywhere in the dashboard UI. The record has to exist
    already (create it once, manually), then look up its ID:

```sh
curl -sG -H "Authorization: Bearer $API_TOKEN" \
    --data-urlencode "type=A" \
    --data-urlencode "name=home.example.com" \
    "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
    | jq -r '.result[0].id'
```

## Usage

Reload systemd and enable the timer for an instance, using the same
`<name>` as its credential file:

```sh
systemctl --user daemon-reload
systemctl --user enable --now cloudflare-ddns@<name>.timer
```

`make enable NAME=<name>` installs and does both; `make disable NAME=<name>`
stops and disables the timer.

`OnBootSec=2min` is relative to when the _machine_ booted, not to when
you enable the timer. On an ordinary desktop login that point is
already in the past, so the first run fires immediately. From there,
`OnUnitActiveSec=15min` takes over, repeating every 15 minutes (±30s of
jitter) after each run. These are monotonic timers, so time spent asleep
doesn't count toward the 15 minutes, and a reboot starts the schedule
again from `OnBootSec=`.

If this runs on a machine you're not always logged into, enable lingering
so the user manager, and its timers, keep running without an active
session:

```sh
loginctl enable-linger "$USER"
```

### Multiple records

Because the unit is a template, any number of instances can run side by
side, each with its own credential file and its own schedule:

```sh
systemctl --user enable --now cloudflare-ddns@home.timer
systemctl --user enable --now cloudflare-ddns@office.timer
```

### Testing and debugging

Run one instance immediately, without waiting on the timer:

```sh
systemctl --user start cloudflare-ddns@<name>.service
journalctl --user -u cloudflare-ddns@<name>.service -e
```

Because `ENVPATH` is just a path the script sources, it can also be
pointed straight at a credential file to test outside of systemd
entirely, bypassing `LoadCredential=`:

```sh
ENVPATH="$XDG_CONFIG_HOME/cloudflare-ddns/<name>" ./cloudflare-ddns
```

Set `DEBUG=1` in the credential file to also log when a run finds
nothing to do.

## Limitations

- IPv4 exclusive: the public address is resolved over IPv4 and only `A`
  records are written; there's no `AAAA`/IPv6 support.
- Updates a single, pre-existing record per instance; it never creates a
  record, so the record must exist before the first run.
- `PROXIED` must be exactly `true` or `false` and `TTL` a whole number of
  seconds; the script refuses to run otherwise. If `PROXIED` is `true`,
  Cloudflare forces `TTL` to `1` regardless of what's configured, and the
  script expects that.

## CI

`.github/workflows/ci.yaml` calls the shared
[standard workflow](https://github.com/chewygumxx/.github#standard-workflow):
the header sync, generic lint and format checks for workflows, shell scripts,
TOML and `.editorconfig`, and the metadata sync. Its own jobs follow:
`commitlint`, which lints the pushed or pull request commit messages with
committed, and `check`, which runs `mise run check` against the commit the
header sync pushed.

`.github/workflows/release.yaml` runs the same check on a `v*.*.*` tag, then
publishes the script, its units, `Makefile`, `README.md` and `LICENSE` as a
tarball on a GitHub release.

## Development

The toolchain is pinned in `mise.toml` and
`.config/mise/conf.d/cloudflare-ddns.toml`, and `mise install` installs it and
wires the git hooks in `.githooks/`. `systemd-analyze` comes with systemd, not
mise.

- `mise run check` runs the checks CI runs: shellcheck and shfmt on the shell
  scripts, `systemd-analyze verify` on the units, Biome's format and lint
  checks, Markdown lint (rumdl), the YAML checks (yamlfmt, then yamllint),
  `editorconfig-checker` and a check that rejects em dashes.
- `mise run format` applies shfmt's formatting, Biome's, and yamlfmt's to
  YAML, which Biome does not read.
- `mise run commitlint -- <revision>...` lints the commit messages the
  revisions name, as CI does: `origin/main..HEAD`, or `-1 HEAD`.

The pre-commit hook runs the same checks on staged files. The commit-msg hook
runs committed, which holds each message to Conventional Commits with the types
and scopes in `committed.toml`.

This repository follows the `native` template of
[`@chewygumxx/create-repo`](https://github.com/chewygumxx/create-repo).

## License

[GPL-3.0-only](LICENSE), matching the `SPDX-License-Identifier` on every other
file in this repository.
