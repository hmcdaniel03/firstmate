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
# It checks three directions:
#   1. A harness firstmate claims to isolate must really resolve ONLY the
#      allowlisted server, observed inside that harness's own session rather than
#      in its help text or in a side subcommand.
#   2. The launch firstmate actually types must start on that harness. A boundary
#      flag that refuses the launch is an availability outage, not a boundary.
#   3. A harness firstmate records as an open gap must not have quietly GAINED a
#      strict-config switch, because that means the gap is closable and
#      docs/configuration.md's coverage table plus fm_mcp_isolation_mode are stale.
#
# The oracle for direction 1 is the session's OWN startup debug log. Claude Code
# resolves MCP configuration before it checks login, so this reads a real
# resolved MCP set with no credentials and with no prompt sent: it consumes no
# model tokens. `claude mcp list` is deliberately NOT used - that subcommand
# ignores the root-level --mcp-config and --strict-mcp-config flags entirely
# (verified on 2.1.282), so it can only ever report the machine's own servers and
# would make this guard pass vacuously.
#
# Every observation runs against a throwaway CLAUDE_CONFIG_DIR planted with
# user-scope, local-scope, and project-scope sentinel servers, and the guard
# first proves those sentinels ARE visible with the flags off. Without that
# control, an empty restricted surface would be indistinguishable from an oracle
# that cannot see anything.
#
# Standard CI has neither harness binaries nor credentials, so the guard is
# opt-in and on-demand. Run it after any harness upgrade and before trusting the
# coverage table in docs/configuration.md.
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

command -v jq >/dev/null 2>&1 || fail \
  "jq is required to plant the sentinel configuration this guard observes against"

TIMEOUT_BIN=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)
[ -n "$TIMEOUT_BIN" ] || fail \
  "neither timeout nor gtimeout is installed, so this guard cannot bound a harness launch; install coreutils"
OBSERVE_TIMEOUT=${FM_MCP_ISOLATION_TIMEOUT:-60}

# One sentinel per configuration scope the boundary has to cut off, plus the one
# server the allowlist actually grants. Distinct names so a leak names its scope.
SENTINEL_ALLOW=fm-mcp-guard-allow-sentinel
SENTINEL_USER=fm-mcp-guard-user-sentinel
SENTINEL_LOCAL=fm-mcp-guard-local-sentinel
SENTINEL_PROJECT=fm-mcp-guard-project-sentinel

mkdir -p "$LAB/store" "$LAB/wt"
LAB_WT=$(cd "$LAB/wt" && pwd -P)
printf '{"mcpServers":{"%s":{"command":"/usr/bin/true"}}}\n' "$SENTINEL_ALLOW" > "$LAB/allow.json"
printf '%s\n' "$FM_MCP_EMPTY_CONFIG" > "$LAB/empty.json"
printf '{"mcpServers":{"%s":{"command":"/usr/bin/true"}}}\n' "$SENTINEL_PROJECT" > "$LAB/wt/.mcp.json"
# User scope and local (per-project) scope both live in the config store's
# .claude.json, which is selected by CLAUDE_CONFIG_DIR rather than by HOME: a
# scratch HOME alone does NOT redirect it, and a guard that only moved HOME would
# read - and could corrupt - the real developer's store.
jq -n --arg wt "$LAB_WT" --arg user "$SENTINEL_USER" --arg localname "$SENTINEL_LOCAL" \
  '{mcpServers: {($user): {command: "/usr/bin/true"}},
    projects: {($wt): {mcpServers: {($localname): {command: "/usr/bin/true"}}}}}' \
  > "$LAB/store/.claude.json" || fail "could not plant the sentinel config store"

# The launch-shape check below fills bin/fm-spawn.sh's own template, which
# encodes this file through the real bin/fm-operational-input.sh, so the argument
# the harness receives is the real brief argument rather than a lookalike.
printf 'guard brief: do nothing\n' > "$LAB/brief.md"

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

joined() {  # <newline-separated list>
  printf '%s' "$1" | tr '\n' ' ' | sed -E 's/ +$//'
}

# Start a claude session in the sentinel lab and print the MCP servers the
# session itself resolved, one per line. No prompt is passed, so even a fully
# authenticated machine spends nothing: the session initializes MCP and is then
# killed by the timeout. Returns 1 when the surface could not be observed at all,
# which the caller must treat as a failure rather than as an empty surface.
claude_resolved_servers() {  # <binary> <label> [flag...]
  local bin=$1 label=$2 log
  shift 2
  log="$LAB/$label.debug.log"
  rm -f "$log"
  (
    cd "$LAB/wt" || exit 1
    CLAUDE_CONFIG_DIR="$LAB/store" "$TIMEOUT_BIN" "$OBSERVE_TIMEOUT" \
      "$bin" --dangerously-skip-permissions "$@" --debug-file "$log" \
      </dev/null >"$LAB/$label.out" 2>"$LAB/$label.err"
  ) || true
  [ -s "$log" ] || return 1
  # This line proves the session actually reached MCP resolution. Without it an
  # empty result would mean "died early", not "resolved nothing".
  grep -q 'Loading MCP configs' "$log" || return 1
  grep -oE 'MCP server "[^"]+"' "$log" | sed -E 's/^MCP server "//; s/"$//' | sort -u
  return 0
}

# Direction 2: the composed launch must actually start. claude's --mcp-config is
# variadic, so an option has to follow the generated path; with the path last the
# encoded brief is read as a second config file and the worker never starts.
#
# The command under test is bin/fm-spawn.sh's own claude template with its
# placeholders filled, not a copy of it, so a template whose argument order would
# refuse to start is caught by the binary here rather than agreeing with a
# hard-coded lookalike. __MODELFLAG__ and __EFFORTFLAG__ are filled with nothing,
# which is exactly what a default crewmate or scout spawn produces and the only
# shape in which the variadic reaches the brief.
claude_launch_shape_is_startable() {  # <label>
  local label=$1 template launch out err combined
  out="$LAB/launch-shape.out"
  err="$LAB/launch-shape.err"
  template=$(sed -n "s/^ *claude) printf '%s' '\(.*\)' ;;\$/\1/p" "$ROOT/bin/fm-spawn.sh")
  [ -n "$template" ] || fail \
    "MCP LAUNCH TEMPLATE UNREADABLE: this guard could not extract the claude launch template from bin/fm-spawn.sh, so it cannot test the command firstmate actually types. Re-read that case arm and update the extraction before trusting a pass."
  launch=${template//__MCPCONFIG__/\'$LAB/empty.json\'}
  launch=${launch//__MODELFLAG__/}
  launch=${launch//__EFFORTFLAG__/}
  launch=${launch//__OPINPUT__/\'$ROOT/bin/fm-operational-input.sh\'}
  launch=${launch//__BRIEF__/\'$LAB/brief.md\'}
  case "$launch" in
    *__*__*) fail "MCP LAUNCH TEMPLATE DRIFT: the claude template now carries a placeholder this guard does not fill, so the command it would run is not the one firstmate types: [$launch]" ;;
  esac
  (
    cd "$LAB/wt" || exit 1
    # A dead API endpoint on top of the empty scratch store: arguments and MCP
    # configuration are resolved long before any request, so this check still
    # works while a credentialed machine cannot spend anything on the brief.
    CLAUDE_CONFIG_DIR="$LAB/store" ANTHROPIC_BASE_URL="http://127.0.0.1:1" \
      "$TIMEOUT_BIN" "$OBSERVE_TIMEOUT" bash -c "$launch" \
      </dev/null >"$out" 2>"$err"
  ) || true
  combined=$(cat "$out" "$err" 2>/dev/null)
  case "$combined" in
    *"Invalid MCP configuration"*|*"MCP config file not found"*)
      fail "MCP LAUNCH REFUSED: $label rejected the launch firstmate composes for a default worker (no --model, no --effort). --mcp-config consumed an argument it should not have, so every crewmate and scout on this harness would fail to start. Composed launch: [$launch]. Observed: [$(printf '%s' "$combined" | head -3 | tr '\n' ' ')]"
      ;;
  esac
  note "$label: bin/fm-spawn.sh's own composed default launch is accepted (no MCP configuration refusal)"
}

# Direction 1: the session's resolved MCP set under the flags must be exactly the
# allowlist, proven against a control run showing the sentinels are visible
# without the flags.
claude_surface_is_the_allowlist() {  # <binary> <label>
  local bin=$1 label=$2 control restricted empty missing leaked name
  control=$(claude_resolved_servers "$bin" control) || fail \
    "MCP ISOLATION UNVERIFIABLE: $label produced no readable startup debug log, so this guard cannot observe which MCP servers a session resolves and must not pass it. Check that --debug-file and --dangerously-skip-permissions are still accepted, then re-run."
  missing=
  for name in "$SENTINEL_USER" "$SENTINEL_LOCAL" "$SENTINEL_PROJECT"; do
    printf '%s\n' "$control" | grep -Fxq "$name" || missing="$missing $name"
  done
  [ -z "$missing" ] || fail \
    "MCP ISOLATION UNVERIFIABLE: with the boundary flags OFF, $label did not resolve these planted sentinel servers:$missing. This guard's oracle cannot see the surface it is meant to police, so a restricted result would prove nothing. Observed unrestricted set: [$(joined "$control")]."

  restricted=$(claude_resolved_servers "$bin" restricted \
    --mcp-config "$LAB/allow.json" --strict-mcp-config) || fail \
    "MCP ISOLATION UNVERIFIABLE: $label produced no readable startup debug log under the boundary flags, so the restricted surface could not be observed."
  printf '%s\n' "$restricted" | grep -Fxq "$SENTINEL_ALLOW" || fail \
    "MCP ISOLATION BROKEN: $label did not resolve the allowlisted server '$SENTINEL_ALLOW' under --mcp-config/--strict-mcp-config, so firstmate's generated allowlist is not the surface the worker gets. Observed: [$(joined "$restricted")]."
  leaked=
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ "$name" = "$SENTINEL_ALLOW" ] && continue
    leaked="$leaked $name"
  done <<EOF
$restricted
EOF
  [ -z "$leaked" ] || fail \
    "MCP ISOLATION LEAK: $label still resolved these servers under --strict-mcp-config:$leaked. A worker on this harness can reach configuration firstmate believed it had replaced."

  empty=$(claude_resolved_servers "$bin" empty \
    --mcp-config "$LAB/empty.json" --strict-mcp-config) || fail \
    "MCP ISOLATION UNVERIFIABLE: $label produced no readable startup debug log under the default empty allowlist."
  [ -z "$empty" ] || fail \
    "MCP ISOLATION LEAK: $label resolved [$(joined "$empty")] under firstmate's DEFAULT empty allowlist, which must give a worker no MCP server at all."

  note "$label: resolved exactly the allowlisted server under the flags, and nothing under the empty default (signal: session debug log)"
  note "$label: control run without the flags resolved [$(joined "$control")], so the oracle can see user, local, and project scope"
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

  if [ "$mode" != strict ]; then
    # Direction 3: the recorded gap must still be a real gap.
    help=$(harness_help "$bin_path")
    if advertises_strict_flags "$help"; then
      fail "MCP ISOLATION DRIFT: $harness $version now advertises --strict-mcp-config and --mcp-config, but firstmate still records it as an open gap. Verify the switch, add $harness to fm_mcp_isolation_mode in bin/fm-mcp-allowlist-lib.sh, and move its row in docs/configuration.md \"Worker MCP allowlist\"."
    fi
    note "$harness $version: no strict-config switch advertised; recorded gap is still accurate"
    CHECKED=$((CHECKED + 1))
    continue
  fi

  # A strict claim needs an oracle that observes the harness's own resolved MCP
  # set. Passing on advertised flags is what let a broken boundary through
  # before, so a strict harness with no oracle here is a failure, not a pass.
  case "$harness" in
    claude)
      claude_launch_shape_is_startable "$harness $version"
      claude_surface_is_the_allowlist "$bin_path" "$harness $version"
      ;;
    *)
      fail "MCP ISOLATION UNVERIFIABLE: fm_mcp_isolation_mode records $harness as strict, but this guard has no surface oracle for it, so its boundary would rest on the flag name alone. Add an oracle that observes a $harness session's own resolved MCP set before trusting that row in docs/configuration.md \"Worker MCP allowlist\"."
      ;;
  esac

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
