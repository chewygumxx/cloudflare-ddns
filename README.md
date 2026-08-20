# cloudflare-ddns

A small, systemd-native dynamic DNS updater for Cloudflare. It watches your
public IPv4 address and keeps a single Cloudflare `A` record in sync with
it, only calling the Cloudflare API when the address has actually changed.

## How it works

`cloudflare-ddns-update <profile>` does the following on every invocation:

1. Loads `$XDG_CONFIG_HOME/cloudflare-ddns/<profile>.env` (falling back to
    `~/.config`, per the
    [XDG Base Directory Specification](https://specifications.freedesktop.org/basedir-spec/latest/)).
2. Resolves the Cloudflare API token via
    [Proton Pass CLI](https://protonpass.github.io/pass-cli/)
    (`pass-cli item view "$API_TOKEN_URI"`), so the token itself is never
    written to disk in the env file.
3. Fetches the current public IPv4 from Cloudflare's own `/cdn-cgi/trace`
    endpoint.
4. Reads the DNS record's current `content` via the Cloudflare API.
5. Exits `0` immediately if the two already match — no API write, no noise.
6. Otherwise `PATCH`es the record with the new address, leaving the
    script's own name as the record's `comment`.

## Features

- **Self-referential IP source** — asks Cloudflare what it sees your
    address as, rather than depending on a third-party "what's my IP"
    service.
- **No-op by default** — a GET-then-compare step means a scheduled run
    that finds nothing changed makes zero write calls.
- **Multi-profile** — one script, many independently configured
    records/zones, selected by a profile name.
- **Secrets stay out of the env file** — `API_TOKEN_URI` is a
    `pass://vault/item/field` reference, not a token; the token only ever
    exists in memory for the current invocation.
- **Strict by default** — `set -euo pipefail`, a validated profile-name
    argument (`[[:alnum:]_.-]` only), and an IPv4-shape check on the
    fetched address before it's ever sent onward.
- **Templated systemd units** — `cloudflare-ddns@.service` /
    `cloudflare-ddns@.timer` give every profile its own independently
    enable-able, schedulable instance.

## Requirements

- Bash — the script relies on Bash-specific syntax (`[[ ]]`,
    `${BASH_SOURCE[0]}`); POSIX `sh` won't run it.
- `curl`
- `jq`
- `awk` (`gawk` on Arch) — parses the plain-text response from
    Cloudflare's trace endpoint.
- [Proton Pass CLI](https://protonpass.github.io/pass-cli/) (`pass-cli`),
    logged in (`pass-cli login`) with access to the vault/item holding your
    Cloudflare API token.
- A Cloudflare API token scoped to `Zone → DNS → Edit` for the target
    zone.
- `systemd --user`, only if you use the provided service/timer units
    rather than your own scheduler.

On Arch Linux, everything but `pass-cli` is covered by:

```bash
pacman -S bash curl jq gawk
```

`pass-cli` isn't currently packaged for Arch; install it via the
[official install script](https://protonpass.github.io/pass-cli/get-started/installation/)
or build it from [source](https://github.com/protonpass/pass-cli).

## Installation

1. Clone the repository and install the script onto the path the
    service unit expects:

    ```bash
    git clone https://github.com/chewygumxx/cloudflare-ddns.git
    install -Dm755 cloudflare-ddns/cloudflare-ddns-update ~/.local/bin/cloudflare-ddns-update
    ```

    `ExecStart=` in the service unit hard-codes `%h/.local/bin/cloudflare-ddns-update`
    (`%h` is systemd's specifier for the invoking user's home directory),
    so this exact path isn't optional if you're using the unit as-is. If
    you invoke the script manually, make sure `~/.local/bin` is on your
    `$PATH`.

2. Install the templated unit files into your user unit search path:

    ```bash
    install -Dm644 cloudflare-ddns/cloudflare-ddns@.service "$XDG_CONFIG_HOME/systemd/user/cloudflare-ddns@.service"
    install -Dm644 cloudflare-ddns/cloudflare-ddns@.timer   "$XDG_CONFIG_HOME/systemd/user/cloudflare-ddns@.timer"
    systemctl --user daemon-reload
    ```

## Configuration

Each profile is an env file at
`$XDG_CONFIG_HOME/cloudflare-ddns/<profile>.env`
(e.g. `~/.config/cloudflare-ddns/home.env`):

```bash
# ~/.config/cloudflare-ddns/home.env
API_TOKEN_URI="pass://Work/Cloudflare DDNS/password"
ZONE_ID="0123456789abcdef0123456789abcdef"
RECORD_ID="fedcba9876543210fedcba9876543210"
RECORD_NAME="home.example.com"
# TTL=1200
# PROXIED=false
```

| Variable | Required | Default | Description |
| --- | --- | --- | --- |
| `API_TOKEN_URI` | yes | — | Proton Pass [secret reference](https://protonpass.github.io/pass-cli/commands/contents/secret-references/) (`pass://vault/item/field`) that resolves to the Cloudflare API token. |
| `ZONE_ID` | yes | — | Cloudflare Zone ID that owns the record. |
| `RECORD_ID` | yes | — | ID of the existing `A` record to keep updated. |
| `RECORD_NAME` | yes | — | The record's hostname, sent as `name` on every update. |
| `TTL` | no | `1200` | TTL in seconds (`1` = Cloudflare's "Automatic", applied automatically to proxied records). |
| `PROXIED` | no | `false` | Whether the record is proxied (orange-clouded) through Cloudflare. |

`ZONE_ID` and `RECORD_ID` are both visible in the Cloudflare dashboard's
DNS record editor, or via `GET /zones` and
`GET /zones/:zone_id/dns_records` against the
[Cloudflare API](https://developers.cloudflare.com/api/).

The file itself holds no secret, but it does identify your zone and
record, so it's still worth restricting:

```bash
chmod 600 "$XDG_CONFIG_HOME/cloudflare-ddns/home.env"
```

## Usage

```bash
cloudflare-ddns-update home
```

Set `DEBUG=1` for a line confirming a no-op run:

```bash
DEBUG=1 cloudflare-ddns-update home
```

The script takes exactly one argument, the profile name, and exits `2`
with a usage message if it's missing or if it contains anything outside
`[A-Za-z0-9_.-]`.

## Scheduling with systemd

Enable and start the timer instance for a profile — the part after `@`
becomes the systemd "instance" name (`%i`), which is what gets passed to
the script as its profile argument:

```bash
systemctl --user enable --now cloudflare-ddns@home.timer
```

The shipped timer runs 2 minutes after the user session starts, then
every 15 minutes (± up to 30s of jitter), and is `Persistent=true` — a
run missed while the machine was off or asleep fires as soon as the
session is active again. The service itself sets `NoNewPrivileges=true`
as a light sandboxing default, and retries automatically after 30s
(`Restart=on-failure`) if a run fails.

`systemd --user` units normally stop at logout. If this machine doesn't
stay logged in, enable lingering so the timer keeps running regardless:

```bash
loginctl enable-linger "$USER"
```

Multiple profiles run independently — enabling
`cloudflare-ddns@work.timer` alongside `cloudflare-ddns@home.timer` is
fine.

## License

[GPL-3.0-or-later](LICENSE), per the [SPDX](https://spdx.dev/) identifier
in each source file.
