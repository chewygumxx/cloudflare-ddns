<!-- vim:set expandtab shiftwidth=4 textwidth=80 filetype=markdown: -->

<!--
   -
   - ~chewygumxx/cloudflare-ddns.git
   - ::: :/README.md
   -
   -->

# cloudflare-ddns

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
2. Fetch the `content` currently set on the target record via the
   [Cloudflare API v4][cf-api].
3. If the two addresses already match, exit `0` immediately — no write,
   no API quota spent.
4. Otherwise, `PATCH` the record with the new `content`, the configured
   `ttl` and `proxied` state, and a `comment` naming the script, so the
   record's edit history in the dashboard shows what last touched it.
5. If any step fails outright — a bad token, a stale record ID, a
   network hiccup — the script exits non-zero. The service unit's
   `Restart=on-failure` / `RestartSec=30` retries automatically rather
   than waiting for the next scheduled tick.

The script only ever *updates* an existing record; it never creates one,
and it manages a single `A` record per instance (see
[Limitations](#limitations)).

[cf-api]: https://developers.cloudflare.com/api/

## Requirements

- `bash`
- `curl` ≥ 7.76.0 — for `--fail-with-body`, added in that release
- `jq` ≥ 1.6 — for `--indent`
- a `systemd --user` manager recent enough to support `LoadCredential=`
  in user units

None of these are unusual on a current Linux install; check your
distribution's package manager if any are missing.

## Installation

### Manually

Install the script and the two unit files into the standard
[XDG][xdg-spec] locations:

```
install -Dm755 cloudflare-ddns \
    "$HOME/.local/bin/cloudflare-ddns"
install -Dm644 cloudflare-ddns@.service \
    "$XDG_CONFIG_HOME/systemd/user/cloudflare-ddns@.service"
install -Dm644 cloudflare-ddns@.timer \
    "$XDG_CONFIG_HOME/systemd/user/cloudflare-ddns@.timer"
```

[xdg-spec]: https://specifications.freedesktop.org/basedir-spec/latest/

### Via chezmoi

`cloudflare-ddns.chezmoiexternal.jsonc` documents the equivalent
[`.chezmoiexternal`][chezmoi-ext-user] entries for these three files and can be
dropped into the [`.chezmoiexternals/`][chezmoi-ext-dir] directory of the
conventional chezmoi root. Otherwise, the contents of which may be merged into
the [`chezmoiexternal.jsonc`][chezmoi-ext-file] file also of the conventional
chezmoi root.

[chezmoi-ext-user]: https://www.chezmoi.io/user-guide/include-files-from-elsewhere/
[chezmoi-ext-dir]: https://www.chezmoi.io/reference/special-files/chezmoiexternal-format/
[chezmoi-ext-file]: https://www.chezmoi.io/reference/special-files/chezmoiexternal-format/

## Configuration

Each systemd instance sources its own environment file, loaded securely
through systemd's [credential mechanism][sd-creds] rather than a plain
`EnvironmentFile=`. For an instance named `<name>`, that file lives at:

```
$XDG_CONFIG_HOME/cloudflare-ddns/<name>
```

(typically `~/.config/cloudflare-ddns/<name>`). Create it and restrict its
permissions, since it holds a plaintext API token at rest:

```
install -d -m700 "$XDG_CONFIG_HOME/cloudflare-ddns"
$EDITOR "$XDG_CONFIG_HOME/cloudflare-ddns/<name>"
chmod 600 "$XDG_CONFIG_HOME/cloudflare-ddns/<name>"
```

[sd-creds]: https://systemd.io/CREDENTIALS/

It should set the following as plain shell `KEY=value` assignments:

| Variable      | Required | Default | Notes                                                                |
|---------------|----------|---------|----------------------------------------------------------------------|
| `API_TOKEN`   | yes      | —       | Cloudflare token scoped to `Zone:DNS:Edit` for the zone              |
| `ZONE_ID`     | yes      | —       | Zone ID that owns the record                                         |
| `RECORD_NAME` | yes      | —       | Fully qualified record name, e.g. `home.example.com`                 |
| `RECORD_ID`   | yes      | —       | ID of the *existing* `A` record to update                            |
| `TTL`         | no       | `300`   | Seconds; forced to `1` ("Automatic") by Cloudflare if `PROXIED=true` |
| `PROXIED`     | no       | `false` | Literal `true`/`false` — parsed as JSON, not a general shell boolean |
| `DEBUG`       | no       | `0`     | Set to `1` to log when the IP already matches                        |

### Getting the IDs and token

- **Zone ID** — shown on the domain's Overview page in the Cloudflare
  dashboard.
- **API token** — create one under *My Profile → API Tokens*, scoped to
  `Zone → DNS → Edit` for just this zone. That's the conventional
  least-privilege approach; a Global API Key can do this too but grants
  far more than the script needs.
- **Record ID** — not shown anywhere in the dashboard UI. The record has
  to exist already (create it once, manually), then look up its ID:

  ```
  curl -sG -H "Authorization: Bearer $API_TOKEN" \
      --data-urlencode "type=A" \
      --data-urlencode "name=home.example.com" \
      "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
      | jq -r '.result[0].id'
  ```

## Usage

Reload systemd and enable the timer for an instance, using the same
`<name>` as its credential file:

```
systemctl --user daemon-reload
systemctl --user enable --now cloudflare-ddns@<name>.timer
```

`OnBootSec=2min` is relative to when the *machine* booted, not to when
you enable the timer — on an ordinary desktop login that point is
already in the past, so the first run fires immediately. From there,
`OnUnitActiveSec=15min` takes over, repeating every 15 minutes (±30s of
jitter) after each run, and `Persistent=true` means a run missed while
the machine was off or asleep fires once at the next opportunity.

If this runs on a machine you're not always logged into, enable lingering
so the user manager — and its timers — keep running without an active
session:

```
loginctl enable-linger "$USER"
```

### Multiple records

Because the unit is a template, any number of instances can run side by
side, each with its own credential file and its own schedule:

```
systemctl --user enable --now cloudflare-ddns@home.timer
systemctl --user enable --now cloudflare-ddns@office.timer
```

### Testing and debugging

Run one instance immediately, without waiting on the timer:

```
systemctl --user start cloudflare-ddns@<name>.service
journalctl --user -u cloudflare-ddns@<name>.service -e
```

Because `ENVPATH` is just a path the script sources, it can also be
pointed straight at a credential file to test outside of systemd
entirely, bypassing `LoadCredential=`:

```
ENVPATH="$XDG_CONFIG_HOME/cloudflare-ddns/<name>" ./cloudflare-ddns
```

Set `DEBUG=1` in the credential file to also log when a run finds
nothing to do.

## Limitations

- IPv4 only — the public address is resolved over IPv4 and only `A`
  records are written; there's no `AAAA`/IPv6 support.
- Updates a single, pre-existing record per instance; it never creates a
  record, so the record must exist before the first run.
- `PROXIED` and `TTL` are passed straight through to the API as JSON, so
  `PROXIED` must be exactly `true` or `false`, and if it's `true`,
  Cloudflare forces `TTL` to `1` regardless of what's configured.

## License

[GPL-3.0-or-later](LICENSE), matching the `SPDX-License-Identifier` on
every other file in this repository.
