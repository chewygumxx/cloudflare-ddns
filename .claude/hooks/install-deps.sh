#!/usr/bin/env sh
# vim:set expandtab shiftwidth=4 filetype=sh:
# SPDX-License-Identifier: GPL-3.0-only

#
#
# ~chewygumxx/cloudflare-ddns.git
# ::: :/.claude/hooks/install-deps.sh
#
#

# SessionStart. Installs this repository's mise tools, which wires its git
# hooks, before anything else in the session runs.

set -u

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0

root=${CLAUDE_PROJECT_DIR:-}
[ -n "$root" ] || root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$root" ] || exit 0

[ -f "$root/mise.toml" ] || exit 0
command -v mise >/dev/null 2>&1 || exit 0

cd "$root" || exit 0
mise trust --quiet >/dev/null
mise install --quiet >/dev/null
