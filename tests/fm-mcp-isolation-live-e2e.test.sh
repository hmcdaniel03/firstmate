#!/usr/bin/env bash
# tests/fm-mcp-isolation-live-e2e.test.sh - opt-in guard proving the worker MCP
# allowlist is real against every INSTALLED harness.
#
# Why this file exists: whether a launch flag restricts a worker's MCP surface is
# a fact the harness vendor owns and can change in any release. A stub can only
# confirm the assumption already written into the stub, so the boundary that
# bin/fm-mcp-allowlist-lib.sh claims has to be exercised against the real binary.
# The portable counterpart, tests/fm-spawn-mcp-allowlist.test.sh, pins firstmate's
# own logic in CI; this guard pins the vendor half.
#
# It checks two directions:
#   1. A harness firstmate claims to isolate must really honor the flags, and the
#      restricted surface must really exclude the machine user's own servers.
#   2. A harness firstmate records as an open gap must not have quietly GAINED a
#      strict-config switch, because that means the gap is closable and
#      docs/configuration.md's coverage table plus fm_mcp_isolation_mode are stale.
#
# No prompt is sent to any harness, so this consumes no model tokens. Standard CI
# has neither harness binaries nor credentials, so the guard is opt-in and
# on-demand. Run it after any harness upgrade and before trusting the coverage
# table in docs/configuration.md.
set -u

if [ "${FM_MCP_ISOLATION_GUARD:-0}" != 1 ]; then
  echo "skip: set FM_MCP_ISOLATION_GUARD=1 to run the installed-harness worker MCP isolation guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-mcp-isolation.XXXXXX")
cleanup_all() { [ -n "${LAB:-}" ] && rm -rf "$LAB"; }
trap cleanup_all EXIT

# shellcheck source=bin/fm-mcp-allowlist-lib.sh
. "$ROOT/bin/fm-mcp-allowlist-lib.sh"
# shellcheck source=bin/fm-cursor-lib.sh
. "$ROOT/bin/fm-cursor-lib.sh"

SENTINEL=fm-mcp-guard-sentinel
printf '{"mcpServers":{"%s":{"command":"/usr/bin/true"}}}\n' "$SENTINEL" > "$LAB/allow.json"
printf '%s\n' "$FM_MCP_EMPTY_CONFIG" > "$LAB/empty.json"

# Mirror bin/fm-spawn.sh's own binary resolution so this guard covers the same
# executable firstmate would actually launch.
resolve_harness_binary() {  # <harness>
  local harness=$1 candidate
  candidate=$(command -v "$harness" 2>/dev/null || true)
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  if [ "$harness" = kimi ] && [ -n "${HOME:-}" ] && [ -x "$HOME/.kimi-code/bin/kimi" ]; then
    printf '%s\n' "$HOME/.kimi-code/bin/kimi"
    return 0
  fi
  if [ "$harness" = cursor ]; then
    fm_cursor_resolve_binary 2>/dev/null && return 0
    return 1
  fi
  return 1
}

harness_help() {  # <binary>
  "$1" --help 2>&1 || true
}

advertises_strict_flags() {  # <help text>
  printf '%s\n' "$1" | grep -q -- '--strict-mcp-config' \
    && printf '%s\n' "$1" | grep -q -- '--mcp-config'
}

CHECKED=0
SKIPPED=

for harness in claude codex opencode pi pi-signed grok kimi cursor muse; do
  if ! bin_path=$(resolve_harness_binary "$harness"); then
    SKIPPED="$SKIPPED $harness"
    note "skip: $harness is not installed on this machine, so its MCP isolation is unverified here"
    continue
  fi
  version=$("$bin_path" --version 2>/dev/null | head -1 | tr -d '\r') || version=
  [ -n "$version" ] || version="unknown"
  mode=$(fm_mcp_isolation_mode "$harness")
  help=$(harness_help "$bin_path")

  if [ "$mode" != strict ]; then
    # Direction 2: the recorded gap must still be a real gap.
    if advertises_strict_flags "$help"; then
      fail "MCP ISOLATION DRIFT: $harness $version now advertises --strict-mcp-config and --mcp-config, but firstmate still records it as an open gap. Verify the switch, add $harness to fm_mcp_isolation_mode in bin/fm-mcp-allowlist-lib.sh, and move its row in docs/configuration.md \"Worker MCP allowlist\"."
    fi
    note "$harness $version: no strict-config switch advertised; recorded gap is still accurate"
    CHECKED=$((CHECKED + 1))
    continue
  fi

  # Direction 1, signal A (structural): ask the harness itself to enumerate the
  # servers it would use under the flags. This reads the harness's own resolved
  # configuration rather than a help string, so it is the stronger signal.
  listed=$("$bin_path" mcp list --strict-mcp-config --mcp-config "$LAB/allow.json" 2>&1) || listed=
  unrestricted=$("$bin_path" mcp list 2>&1) || unrestricted=
  signal_a=0
  case "$listed" in
    *"$SENTINEL"*) signal_a=1 ;;
  esac

  # Direction 1, signal B (rendered surface): the flags are advertised. Weaker,
  # and deliberately not load-bearing on its own when signal A is available.
  signal_b=0
  advertises_strict_flags "$help" && signal_b=1

  if [ "$signal_a" -eq 0 ] && [ "$signal_b" -eq 0 ]; then
    fail "MCP ISOLATION BROKEN: $harness $version neither enumerated the allowlisted server under --strict-mcp-config nor advertises the flags, so firstmate's claim that it isolates $harness workers is no longer true. fm-spawn would still pass the flags and the launch would fail or silently widen. Observed 'mcp list' output under the flags: [$listed]. Re-verify the switch and update fm_mcp_isolation_mode plus docs/configuration.md \"Worker MCP allowlist\"."
  fi

  if [ "$signal_a" -eq 1 ]; then
    # The restricted listing must be the allowlist and nothing else. Any name the
    # unrestricted listing has that is not the sentinel is a server the worker
    # must not be able to reach.
    leaked=
    while IFS= read -r line; do
      case "$line" in
        *:*) name=${line%%:*} ;;
        *) continue ;;
      esac
      name=$(printf '%s' "$name" | tr -d '[:space:]')
      [ -n "$name" ] || continue
      [ "$name" = "$SENTINEL" ] && continue
      case "$listed" in
        *"$name"*) leaked="$leaked $name" ;;
      esac
    done <<EOF
$unrestricted
EOF
    [ -z "$leaked" ] || fail \
      "MCP ISOLATION LEAK: $harness $version still resolved these servers under --strict-mcp-config:$leaked. A worker on this harness can reach configuration firstmate believed it had replaced. Observed restricted listing: [$listed]."
    note "$harness $version: strict listing resolved only the allowlisted server (signal: mcp list)"
  else
    note "$harness $version: flags advertised but 'mcp list' did not enumerate under them; verdict rests on the advertised surface alone (observed: [$listed])"
  fi

  pass "worker MCP isolation: $harness $version honors the firstmate-owned allowlist"
  CHECKED=$((CHECKED + 1))
done

[ "$CHECKED" -gt 0 ] || fail \
  "no verified harness is installed here, so this run proved nothing; install at least one harness before trusting a pass"

if [ -n "$SKIPPED" ]; then
  note "unverified on this machine (not installed):$SKIPPED"
fi
note "checked $CHECKED installed harness(es)"

cleanup_all
