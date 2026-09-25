#!/usr/bin/env bash
# Firstmate-owned MCP allowlist for spawned workers.
#
# A firstmate worker runs with permissions skipped and reads untrusted repository
# content (issue text, README, fixtures, dependency docs), so any MCP server it
# can reach is reachable by an indirect prompt injection with no human in the
# path. Workers therefore do NOT inherit the machine user's MCP configuration.
# They launch against a firstmate-generated config whose default content is
# {"mcpServers":{}} and whose only other content is a server the caller opted
# into for that exact task.
#
# This file is the single owner of:
#   - the config/crew-mcp.json schema and its validation,
#   - allowlist name resolution (a name resolves ONLY against a firstmate-owned
#     definition in that file, never by copying an entry out of the harness's own
#     user-scope config, which would carry that entry's secret along),
#   - the generated per-task config file's content and permissions,
#   - which harnesses firstmate can prove it isolates.
# docs/configuration.md "Worker MCP allowlist" is the operator-facing owner, and
# bin/fm-spawn.sh owns the launch flags that consume the generated file.
#
# Isolation support is deliberately a closed allowlist of harnesses whose
# strict-config switch firstmate has verified, not a guess from a flag name. An
# unlisted harness reports `unverified`, which fm-spawn discloses loudly rather
# than claiming a boundary it cannot enforce.

# Default content for a worker with no opted-in server. This exact string is the
# secure default: no user-scope server, no project-scope server, nothing.
FM_MCP_EMPTY_CONFIG='{"mcpServers":{}}'

# Harnesses whose worker MCP surface firstmate can PROVE it replaces, and the
# mechanism it uses. Anything absent here is an unverified gap.
#
# claude: `--strict-mcp-config` restricts the session to the servers in
# `--mcp-config`, ignoring user scope (~/.claude.json), project scope
# (.mcp.json), and local scope alike, so one generated file is the whole surface.
fm_mcp_isolation_mode() {
  case "${1:-}" in
    claude) printf '%s\n' strict ;;
    *) printf '%s\n' unverified ;;
  esac
}

# Path of the generated per-task config. Outside the worktree (like the Pi
# extension) so it is never committed, never inside the project's trust scope,
# and removed by teardown with the task's other state files.
fm_mcp_config_path() {
  printf '%s/%s.mcp.json\n' "${1%/}" "$2"
}

fm_mcp_definitions_path() {
  printf '%s/crew-mcp.json\n' "${1%/}"
}

# A name must be safe to use as a JSON object key and as a shell-quoted jq
# argument, and must read as a server name rather than a path or expression.
fm_mcp_name_valid() {
  case "${1:-}" in
    '') return 1 ;;
    *) printf '%s' "$1" | LC_ALL=C grep -Eq '^[A-Za-z0-9_][A-Za-z0-9_.-]*$' ;;
  esac
}

# Validate config/crew-mcp.json in full, or fail with one actionable line.
# Refusing on malformed configuration is deliberate: silently treating an
# unreadable allowlist as empty would look identical to a working opt-in and
# would hide a typo that disables a server the task needs.
fm_mcp_definitions_validate() {
  local file=$1 problem
  command -v jq >/dev/null 2>&1 || {
    echo "error: $file exists but jq is not installed, so its server definitions cannot be validated; install jq or remove the file to launch workers with the empty default allowlist" >&2
    return 1
  }
  problem=$(jq -r '
    def namefail:
      [ (.servers // {} | keys[]), ((.default // [])[] | tostring) ]
      | map(select(test("^[A-Za-z0-9_][A-Za-z0-9_.-]*$") | not));
    if type != "object" then "top level must be a JSON object"
    elif (has("servers") and (.servers | type != "object")) then "\"servers\" must be an object of <name>: <server definition>"
    elif (has("default") and (.default | type != "array")) then "\"default\" must be an array of server names"
    elif ((.servers // {}) | to_entries | map(select(.value | type != "object")) | length) > 0
      then "every \"servers\" entry must be an object: " + (((.servers // {}) | to_entries | map(select(.value | type != "object")) | map(.key) | join(", ")))
    elif ((.default // []) | map(select(type != "string")) | length) > 0
      then "every \"default\" entry must be a string server name"
    elif (namefail | length) > 0
      then "server names must match [A-Za-z0-9_][A-Za-z0-9_.-]*: " + (namefail | join(", "))
    elif (((.default // []) - ((.servers // {}) | keys)) | length) > 0
      then "\"default\" names have no definition under \"servers\": " + (((.default // []) - ((.servers // {}) | keys)) | join(", "))
    else "" end
  ' "$file" 2>/dev/null) || {
    echo "error: $file is not valid JSON; correct it or remove it rather than letting an unreadable allowlist look like an empty one" >&2
    return 1
  }
  [ -z "$problem" ] || {
    echo "error: $file is invalid - $problem" >&2
    return 1
  }
  return 0
}

# Resolve the names a spawn will grant, printing one per line.
#   $1 config dir, $2 requested value (empty = the file's "default", `none` = an
#   explicit empty allowlist that overrides that default).
# Every requested name must have a firstmate-owned definition; an unknown name is
# a refusal, which is what keeps `--mcp-allow` from ever meaning "copy whatever
# the user's own MCP config calls that".
fm_mcp_allowlist_resolve() {
  local config_dir=$1 requested=${2-} file names name
  file=$(fm_mcp_definitions_path "$config_dir")
  if [ "$requested" = none ]; then
    return 0
  fi
  if [ -z "$requested" ]; then
    [ -f "$file" ] || return 0
    fm_mcp_definitions_validate "$file" || return 1
    jq -r '(.default // [])[]' "$file"
    return 0
  fi
  [ -f "$file" ] || {
    echo "error: --mcp-allow names a server but $file does not exist; a worker only ever receives a server firstmate itself defines there, never an entry copied out of the harness's own config" >&2
    return 1
  }
  fm_mcp_definitions_validate "$file" || return 1
  names=$(printf '%s' "$requested" | tr ',' '\n')
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    fm_mcp_name_valid "$name" || {
      echo "error: --mcp-allow server name '$name' is not a valid name (expected [A-Za-z0-9_][A-Za-z0-9_.-]*)" >&2
      return 1
    }
    jq -e --arg n "$name" '(.servers // {}) | has($n)' "$file" >/dev/null 2>&1 || {
      echo "error: --mcp-allow names '$name', which has no definition under \"servers\" in $file; define it there (firstmate-owned, no secret copied from the harness's own config) or drop it from this task's allowlist" >&2
      return 1
    }
    printf '%s\n' "$name"
  done <<EOF
$names
EOF
  return 0
}

# Write the generated per-task config atomically at mode 0600. A firstmate-owned
# server definition can legitimately carry a credential, so the file is never
# group- or world-readable even though it lives in a private state directory.
fm_mcp_config_write() {
  local out=$1 config_dir=$2 names=$3 file tmp
  file=$(fm_mcp_definitions_path "$config_dir")
  tmp="$out.tmp.$$"
  if [ -z "$names" ]; then
    printf '%s\n' "$FM_MCP_EMPTY_CONFIG" > "$tmp" || return 1
  else
    printf '%s\n' "$names" \
      | jq -Rs --slurpfile defs "$file" \
        'split("\n") | map(select(length > 0))
         | {mcpServers: (reduce .[] as $n ({}; .[$n] = $defs[0].servers[$n]))}' \
        > "$tmp" || {
        rm -f "$tmp" 2>/dev/null || true
        return 1
      }
  fi
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$out" || {
    rm -f "$tmp" 2>/dev/null || true
    return 1
  }
  return 0
}
