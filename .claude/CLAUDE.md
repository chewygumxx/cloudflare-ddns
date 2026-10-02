---
__cgxx: |
  # vim:set expandtab shiftwidth=2 filetype=markdown foldlevel=3:
  # SPDX-License-Identifier: GPL-3.0-only

  #
  #
  # ~chewygumxx/cloudflare-ddns.git
  # ::: :/.claude/CLAUDE.md
  #
  #

ctime: 2026-10-02
title: CLAUDE.md
description: "Repository instructions"
tags:
  - claude
  - llm
---

# CLAUDE.md

Continuously granularly commit as you work. Compose single-line commit messages
whenever appropriate. If the granular commit does indeed warrant further
context, include such within the commit message body.

When appropriate and worthwhile to compact, append the following
newline-delimited items to your response:

- A `/compact <summary>`
- Appraisal rating scaled 1-100
- Risk assessment rating scaled 1-100
- Terse single-sentence justification.

## Repository Information

A small dynamic DNS client for Cloudflare, now superseded by `cloudflared`: a
single `bash` + `curl` + `jq` script (`cloudflare-ddns`) that keeps one
Cloudflare `A` record in sync with the host's public IPv4 address. It ships as
a templated `systemd --user` service and timer, so any number of records can be
kept in sync on independent schedules. There is no build step; the script is
the shipped artifact.

The repository follows the `native` template of
[`@chewygumxx/create-repo`](https://github.com/chewygumxx/create-repo): mise pins
every tool, there is no `package.json`, and `mise install` points
`core.hooksPath` at `.githooks/`.

## Commands

- `mise run check` runs what CI runs: Biome, rumdl, yamlfmt and yamllint, the em
  dash check, `editorconfig-checker`, shellcheck and shfmt (`lint:shell`), and
  `systemd-analyze verify` on the units (`lint:systemd`).
- `mise run format` applies Biome, yamlfmt and shfmt. shfmt takes its style
  from `.editorconfig`.
- `mise run commitlint -- <revision>...` lints commit messages with committed,
  against the types and scopes in `committed.toml`.
- The script's own tasks and tools live in
  `.config/mise/conf.d/cloudflare-ddns.toml`; the shared ones in `mise.toml`.
- Run the script without systemd: `ENVPATH=<env-file> ./cloudflare-ddns`, which
  is how the service invokes it. `DEBUG=1` in the env file also logs a run that
  finds nothing to do.
- `make install`, `make enable NAME=<name>`, `make disable NAME=<name>` and
  `make uninstall` install into `$HOME/.local/bin` and
  `$XDG_CONFIG_HOME/systemd/user`.

## Architecture

- `__curl` wraps `curl` with fixed retry and error flags. `__api_call` calls
  the Cloudflare v4 record endpoint (`zones/$ZONE_ID/dns_records/$RECORD_ID`)
  and pipes the response through one `jq` filter that extracts
  `.result<filter>` on success or raises the API's own error message. The main
  flow sources `$ENVPATH`, validates the required variables, resolves the public
  IP from `cloudflare.com/cdn-cgi/trace` over `--ipv4`, compares it with the
  record's `.content`, exits 0 on a match, and otherwise `PATCH`es a body built
  with `jq -n`. It only updates an existing record, one `A` record per
  instance.
- `cloudflare-ddns@.service` and `cloudflare-ddns@.timer` are templates keyed
  by `%i`. The service loads `%E/cloudflare-ddns/%i` with `LoadCredential=` and
  passes its path as `Environment=ENVPATH=%d/env`; the script has no systemd
  awareness beyond sourcing `$ENVPATH`.
- The service is heavily sandboxed (`ProtectSystem=strict`,
  `ProtectHome=read-only`, restricted address families and syscalls). A change
  to what the script touches on disk, on the network or via syscalls likely
  needs a matching change there.
- `.github/workflows/ci.yaml` calls the shared standard workflow (header sync,
  generic lint and format, metadata sync), then lints commits and runs
  `mise run check`. `.github/workflows/release.yaml` tars the script, units,
  `Makefile`, `README.md` and `LICENSE` into a GitHub release on a `v*.*.*`
  tag.
- The `~chewygumxx/cloudflare-ddns.git` / `::: :/<path>` header on each file is
  maintained by the header sync on push to `main`; a new file needs only a
  header of the same shape.
