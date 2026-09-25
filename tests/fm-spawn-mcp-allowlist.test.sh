#!/usr/bin/env bash
# Behavior tests for the worker MCP allowlist (bin/fm-mcp-allowlist-lib.sh as
# consumed by bin/fm-spawn.sh).
#
# The guarantee under test: a firstmate worker never inherits the machine user's
# MCP servers. These tests drive the real fm-spawn through launch construction
# with a fake tmux pane and a real isolated git worktree, so they assert the
# command firstmate would actually type and the config file that command points
# at, never the launch template's source bytes.
#
# A user-scope config carrying credential-bearing servers is planted for every
# case, so a regression that drops strict mode or copies an entry out of that
# file fails here rather than in production.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-mcp-allowlist)

# The credential-bearing user-scope surface this change exists to cut off. Names
# match the real finding on the developer machine so an inheritance regression is
# recognizable in the failure output.
USER_SCOPE_SERVERS='context7 hackerone motion motion-plus'

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
  chmod +x "$fakebin/timeout"
  printf '%s\n' "$fakebin"
}

# One case directory: an isolated firstmate home, a real project plus task
# worktree, a fake PATH, and a planted user-scope MCP config.
make_spawn_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog id server
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  {
    printf '{"mcpServers":{'
    local first=1
    for server in $USER_SCOPE_SERVERS; do
      [ "$first" -eq 1 ] || printf ','
      first=0
      printf '"%s":{"command":"%s-mcp","env":{"TOKEN":"user-scope-secret-%s"}}' \
        "$server" "$server" "$server"
    done
    printf '}}\n'
  } > "$case_dir/user-scope.claude.json"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

write_definitions() {
  cat > "$1/config/crew-mcp.json"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$launchlog" \
    GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

run_ship_spawn() {
  run_spawn "$@" --mode no-mistakes --yolo off
}

# The launch must point at the generated file, and that file is the whole MCP
# surface only because strict mode is on; assert both together so neither half
# can be dropped on its own.
#
# claude's --mcp-config is variadic, so the token that follows the generated path
# has to be an option or the flag swallows it. Asserting the exact
# "--mcp-config '<path>' --strict-mcp-config" adjacency pins both halves AND the
# order in one check, on every case in this file rather than only the dedicated
# no-model one below.
assert_strict_launch() {
  local launch=$1 home=$2 id=$3
  assert_contains "$launch" "--mcp-config '$home/state/$id.mcp.json' --strict-mcp-config" \
    "claude worker launch must pass --mcp-config pointed at the firstmate-generated allowlist and terminate that variadic flag with --strict-mcp-config, or it would load every user-scope and project-scope MCP server (or swallow the brief as a config path)"
}

# The recorded grant has to be an EXACT line: a substring match would let
# mcp_allow=hackerone satisfy an assertion about an empty grant.
assert_meta_line() {
  local meta=$1 line=$2 msg=$3
  grep -Fxq -- "$line" "$meta" || fail "$msg (looked for exact line '$line')"
}

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

assert_no_user_scope_servers() {
  local haystack=$1 label=$2 server
  for server in $USER_SCOPE_SERVERS; do
    assert_not_contains "$haystack" "$server" \
      "$label leaked user-scope MCP server '$server'"
  done
  assert_not_contains "$haystack" "user-scope-secret" \
    "$label leaked a user-scope MCP server credential"
}

test_claude_worker_launch_is_strictly_scoped_to_an_empty_allowlist() {
  local rec id out status launch generated mode
  id=mcp-default-empty-a1
  rec=$(make_spawn_case mcp-default-empty claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "default claude spawn should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_strict_launch "$launch" "$HOME_DIR" "$id"

  generated=$(cat "$HOME_DIR/state/$id.mcp.json")
  [ "$generated" = '{"mcpServers":{}}' ] \
    || fail "generated allowlist should be exactly {\"mcpServers\":{}} with no configured servers; got: $generated"
  assert_no_user_scope_servers "$generated" "the generated allowlist"
  assert_no_user_scope_servers "$launch" "the composed launch command"

  mode=$(file_mode "$HOME_DIR/state/$id.mcp.json")
  [ "$mode" = 600 ] \
    || fail "generated allowlist should be owner-only (a firstmate-owned definition may carry a credential); got mode '$mode'"

  assert_meta_line "$HOME_DIR/state/$id.meta" 'mcp_allow=' "meta should record an empty worker MCP grant"
  assert_meta_line "$HOME_DIR/state/$id.meta" 'mcp_isolation=strict' \
    "meta should record that firstmate enforced the claude worker MCP boundary"
  pass "a claude worker launches strictly scoped to an empty firstmate-owned allowlist"
}

test_claude_launch_without_model_or_effort_terminates_the_variadic_config_flag() {
  local rec id out status launch marker after next_token
  id=mcp-variadic-a7
  rec=$(make_spawn_case mcp-variadic claude "$id")
  read_case_record "$rec"

  # No --model and no --effort is the DEFAULT crewmate and scout shape, so both
  # placeholders expand to nothing and only the template's own ordering keeps
  # claude's variadic --mcp-config from eating the encoded brief as a second
  # config path. Verified against claude 2.1.282: with --mcp-config last the
  # binary refuses to start with "MCP config file not found: <the brief>", so
  # every default worker on this harness would fail to launch.
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "default claude spawn with no model or effort should succeed"
  launch=$(cat "$LAUNCH_LOG")

  # This case only guards anything while the spawn really passes neither flag;
  # either one would terminate the variadic on its own and hide the regression.
  assert_not_contains "$launch" "--model " \
    "this regression case must spawn with no --model, or a model flag would mask the variadic swallow"
  assert_not_contains "$launch" "--effort " \
    "this regression case must spawn with no --effort, or an effort flag would mask the variadic swallow"

  assert_strict_launch "$launch" "$HOME_DIR" "$id"

  # Whatever sits immediately after the generated path has to be an option.
  marker="--mcp-config '$HOME_DIR/state/$id.mcp.json' "
  after=${launch#*"$marker"}
  next_token=${after%% *}
  case "$next_token" in
    --*) ;;
    *) fail "the token after --mcp-config is '$next_token' rather than an option, so claude's variadic --mcp-config consumes it as a second config file and the worker never starts" ;;
  esac
  pass "a claude launch with no model or effort still terminates the variadic --mcp-config with an option"
}

test_user_scope_server_name_is_not_grantable_without_a_firstmate_definition() {
  local rec id out status
  id=mcp-no-inherit-a2
  rec=$(make_spawn_case mcp-no-inherit claude "$id")
  read_case_record "$rec"
  # The name exists in the user's own MCP config, which is exactly the thing a
  # spawn must never resolve a name against.
  cp "$CASE_DIR/user-scope.claude.json" "$HOME_DIR/user-scope.claude.json"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --mcp-allow hackerone)
  status=$?
  expect_code 1 "$status" "granting a server with no firstmate-owned definition must refuse"
  assert_contains "$out" "does not exist" \
    "refusal should name the missing firstmate-owned definitions file"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "a refused allowlist must not leave a half-created task record behind"
  assert_absent "$HOME_DIR/state/$id.mcp.json" \
    "a refused allowlist must not leave a generated config behind"
  pass "a user-scope server name is not grantable without a firstmate-owned definition"
}

test_unknown_name_refuses_even_when_definitions_exist() {
  local rec id out status
  id=mcp-unknown-name-a3
  rec=$(make_spawn_case mcp-unknown-name claude "$id")
  read_case_record "$rec"
  write_definitions "$HOME_DIR" <<'JSON'
{ "servers": { "docs-fetch": { "command": "node", "args": ["/opt/fm/docs-fetch.js"] } } }
JSON

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --mcp-allow context7)
  status=$?
  expect_code 1 "$status" "an undefined server name must refuse the spawn"
  assert_contains "$out" "no definition under" \
    "refusal should say the name has no firstmate-owned definition"
  assert_absent "$HOME_DIR/state/$id.meta" "refused spawn should create no task record"
  pass "an undefined server name refuses instead of resolving somewhere else"
}

test_configured_default_allowlist_is_the_only_granted_surface() {
  local rec id out status generated launch
  id=mcp-config-default-a4
  rec=$(make_spawn_case mcp-config-default claude "$id")
  read_case_record "$rec"
  write_definitions "$HOME_DIR" <<'JSON'
{
  "servers": {
    "docs-fetch": { "command": "node", "args": ["/opt/fm/docs-fetch.js"] },
    "sql-ro": { "command": "sql-mcp", "env": { "MODE": "ro" } }
  },
  "default": ["docs-fetch"]
}
JSON

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "spawn with a configured default allowlist should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_strict_launch "$launch" "$HOME_DIR" "$id"
  generated=$(cat "$HOME_DIR/state/$id.mcp.json")
  assert_contains "$generated" '"docs-fetch"' "configured default server should be granted"
  assert_not_contains "$generated" '"sql-ro"' \
    "a defined but un-defaulted server must not be granted"
  assert_no_user_scope_servers "$generated" "the generated allowlist"
  assert_meta_line "$HOME_DIR/state/$id.meta" 'mcp_allow=docs-fetch' \
    "meta should record the resolved default grant"
  pass "only the configured default allowlist reaches the worker"
}

test_per_task_flag_overrides_the_configured_default() {
  local rec id out status generated
  id=mcp-flag-grant-a5
  rec=$(make_spawn_case mcp-flag-grant claude "$id")
  read_case_record "$rec"
  write_definitions "$HOME_DIR" <<'JSON'
{
  "servers": {
    "docs-fetch": { "command": "node", "args": ["/opt/fm/docs-fetch.js"] },
    "sql-ro": { "command": "sql-mcp", "env": { "MODE": "ro" } }
  },
  "default": ["docs-fetch"]
}
JSON

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --mcp-allow sql-ro)
  status=$?
  expect_code 0 "$status" "explicit per-task allowlist should succeed"
  generated=$(cat "$HOME_DIR/state/$id.mcp.json")
  assert_contains "$generated" '"sql-ro"' "the explicitly granted server should be present"
  assert_contains "$generated" '"MODE": "ro"' \
    "the granted server should carry its firstmate-owned definition"
  assert_not_contains "$generated" '"docs-fetch"' \
    "an explicit per-task allowlist replaces the configured default rather than adding to it"
  assert_meta_line "$HOME_DIR/state/$id.meta" 'mcp_allow=sql-ro' \
    "meta should record the explicit per-task grant"
  pass "an explicit per-task allowlist replaces the configured default"
}

test_explicit_none_drops_the_configured_default() {
  local rec id out status generated
  id=mcp-flag-none-a6
  rec=$(make_spawn_case mcp-flag-none claude "$id")
  read_case_record "$rec"
  write_definitions "$HOME_DIR" <<'JSON'
{
  "servers": { "docs-fetch": { "command": "node" } },
  "default": ["docs-fetch"]
}
JSON

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --mcp-allow none)
  status=$?
  expect_code 0 "$status" "--mcp-allow none should succeed"
  generated=$(cat "$HOME_DIR/state/$id.mcp.json")
  [ "$generated" = '{"mcpServers":{}}' ] \
    || fail "--mcp-allow none should grant nothing; got: $generated"
  pass "--mcp-allow none drops the configured default for one task"
}

test_malformed_definitions_refuse_rather_than_read_as_empty() {
  local rec id out status
  id=mcp-malformed-a7
  rec=$(make_spawn_case mcp-malformed claude "$id")
  read_case_record "$rec"
  printf '%s\n' '{"servers": {"docs-fetch": ' > "$HOME_DIR/config/crew-mcp.json"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "malformed definitions must refuse the spawn"
  assert_contains "$out" "not valid JSON" "refusal should name the parse failure"
  assert_absent "$HOME_DIR/state/$id.meta" "refused spawn should create no task record"
  pass "malformed definitions refuse instead of looking like an empty allowlist"
}

test_default_naming_an_undefined_server_refuses() {
  local rec id out status
  id=mcp-dangling-default-a8
  rec=$(make_spawn_case mcp-dangling-default claude "$id")
  read_case_record "$rec"
  write_definitions "$HOME_DIR" <<'JSON'
{ "servers": { "docs-fetch": { "command": "node" } }, "default": ["docs-fetch", "hackerone"] }
JSON

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "a default naming an undefined server must refuse"
  assert_contains "$out" "have no definition under" \
    "refusal should name the dangling default entry"
  pass "a default naming an undefined server refuses rather than resolving elsewhere"
}

test_harness_without_verified_isolation_discloses_the_gap() {
  local rec id out status
  id=mcp-gap-disclosure-a9
  rec=$(make_spawn_case mcp-gap-disclosure codex "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "a codex spawn should still succeed"
  assert_contains "$out" "worker MCP isolation is NOT enforced for harness 'codex'" \
    "an unenforced harness must disclose the gap rather than stay silent"
  assert_meta_line "$HOME_DIR/state/$id.meta" 'mcp_isolation=unverified' \
    "meta must record the honest unenforced state, never a false strict claim"
  assert_absent "$HOME_DIR/state/$id.mcp.json" \
    "a harness with no strict-config mechanism should get no generated file to imply one"
  pass "a harness with no verified isolation discloses and records the gap"
}

test_allowlist_flag_refused_where_it_cannot_be_enforced() {
  local rec id out status
  id=mcp-gap-refuses-flag-b1
  rec=$(make_spawn_case mcp-gap-refuses-flag codex "$id")
  read_case_record "$rec"
  write_definitions "$HOME_DIR" <<'JSON'
{ "servers": { "docs-fetch": { "command": "node" } } }
JSON

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --mcp-allow docs-fetch)
  status=$?
  expect_code 1 "$status" "--mcp-allow must refuse where firstmate cannot enforce it"
  assert_contains "$out" "cannot be honored for this launch (harness 'codex')" \
    "refusal should say the harness has no verified isolation mechanism"
  pass "--mcp-allow refuses on a harness where it would be a claim rather than a boundary"
}

test_empty_flag_value_is_a_refusal_not_a_silent_empty_grant() {
  local rec id out status
  id=mcp-empty-value-b2
  rec=$(make_spawn_case mcp-empty-value claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --mcp-allow=)
  status=$?
  expect_code 1 "$status" "an empty --mcp-allow value must refuse"
  assert_contains "$out" "pass 'none'" "refusal should point at the explicit empty form"
  pass "an empty --mcp-allow value refuses instead of guessing"
}

test_scout_worker_is_scoped_the_same_way() {
  local rec id out status launch
  id=mcp-scout-b3
  rec=$(make_spawn_case mcp-scout claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout)
  status=$?
  expect_code 0 "$status" "scout spawn should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_strict_launch "$launch" "$HOME_DIR" "$id"
  pass "a scout worker is scoped by the same allowlist as a ship worker"
}

test_secondmate_agent_is_scoped_the_same_way() {
  local rec id out status launch sm
  id=mcp-secondmate-b4
  rec=$(make_spawn_case mcp-secondmate claude "$id")
  read_case_record "$rec"
  sm="$CASE_DIR/secondmate-home"
  mkdir -p "$sm/bin" "$sm/data"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$sm/data/charter.md"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate spawn should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_strict_launch "$launch" "$HOME_DIR" "$id"
  pass "a secondmate agent is scoped by the same allowlist as a crewmate"
}

test_raw_launch_command_cannot_claim_an_unearned_boundary() {
  local rec id out status
  id=mcp-raw-launch-b5
  rec=$(make_spawn_case mcp-raw-launch claude "$id")
  read_case_record "$rec"

  # The raw-command escape hatch can name a strict-capable harness while omitting
  # the flags. The record must stay honest rather than inherit the harness's fact.
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    'claude --dangerously-skip-permissions')
  status=$?
  expect_code 0 "$status" "raw launch command should still spawn"
  assert_meta_line "$HOME_DIR/state/$id.meta" 'mcp_isolation=unverified' \
    "a raw launch command without the strict flags must not record an enforced boundary"
  assert_contains "$out" "worker MCP isolation is NOT enforced" \
    "a raw launch command without the strict flags must disclose the gap"
  pass "a raw launch command cannot claim a boundary it does not carry"
}

test_foreign_strict_flags_do_not_make_a_grant_deliverable() {
  local rec id out status
  id=mcp-foreign-strict-b6
  rec=$(make_spawn_case mcp-foreign-strict claude "$id")
  read_case_record "$rec"
  write_definitions "$HOME_DIR" <<'JSON'
{ "servers": { "docs-fetch": { "command": "node" } }, "default": ["docs-fetch"] }
JSON

  # A raw command can carry its OWN --mcp-config that firstmate does not own and
  # cannot fill, so the harness's strict flags alone must not be read as firstmate
  # having delivered the grant.
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    'claude --dangerously-skip-permissions --strict-mcp-config --mcp-config /tmp/theirs.json')
  status=$?
  expect_code 0 "$status" "raw launch command with its own MCP config should still spawn"
  assert_meta_line "$HOME_DIR/state/$id.meta" 'mcp_isolation=unverified' \
    "a launch firstmate did not scope must not record an enforced boundary"
  assert_meta_line "$HOME_DIR/state/$id.meta" 'mcp_allow=' \
    "mcp_allow must stay empty when firstmate delivered no allowlist, even with a configured default"
  assert_absent "$HOME_DIR/state/$id.mcp.json" \
    "firstmate should generate no file for a launch it cannot point at one"
  pass "another party's strict flags do not count as a firstmate-delivered grant"
}

test_claude_worker_launch_is_strictly_scoped_to_an_empty_allowlist
test_claude_launch_without_model_or_effort_terminates_the_variadic_config_flag
test_user_scope_server_name_is_not_grantable_without_a_firstmate_definition
test_unknown_name_refuses_even_when_definitions_exist
test_configured_default_allowlist_is_the_only_granted_surface
test_per_task_flag_overrides_the_configured_default
test_explicit_none_drops_the_configured_default
test_malformed_definitions_refuse_rather_than_read_as_empty
test_default_naming_an_undefined_server_refuses
test_harness_without_verified_isolation_discloses_the_gap
test_allowlist_flag_refused_where_it_cannot_be_enforced
test_empty_flag_value_is_a_refusal_not_a_silent_empty_grant
test_scout_worker_is_scoped_the_same_way
test_secondmate_agent_is_scoped_the_same_way
test_raw_launch_command_cannot_claim_an_unearned_boundary
test_foreign_strict_flags_do_not_make_a_grant_deliverable
