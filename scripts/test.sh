#!/bin/bash
set -euo pipefail

# claude-push test utility

CONFIG_FILE="${HOME}/.config/claude-push/config"
INSTALL_DIR="${HOME}/.local/share/claude-push"
CLAUDE_SETTINGS="${HOME}/.claude/settings.json"

DEBUG=false

usage() {
  echo "Usage: $0 [-d] <command>"
  echo ""
  echo "Options:"
  echo "  -d           Debug mode (runs hook with bash -x)"
  echo ""
  echo "Commands:"
  echo "  test-notify  Send a test notification to verify ntfy is working"
  echo "  status       Check installation status"
  exit 1
}

check_config() {
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: config not found at ${CONFIG_FILE}"
    echo "Run install.sh first."
    exit 1
  fi
  source "$CONFIG_FILE"
}

cmd_test_notify() {
  HOOK_PATH="${INSTALL_DIR}/hooks/claude-push.sh"
  if [ ! -x "$HOOK_PATH" ]; then
    echo "Error: hook not found at ${HOOK_PATH}"
    echo "Run install.sh first."
    exit 1
  fi

  echo "Sending test notification via installed hook: ${HOOK_PATH}"
  echo "Tap 'Allow' or 'Deny' on your device to test the response flow."
  echo ""

  # Build a fake PermissionRequest identical to what Claude Code sends
  FAKE_INPUT=$(jq -n \
    --arg cwd "$PWD" \
    '{
      session_id: "test-00000000-0000-0000-0000-000000000000",
      transcript_path: "/tmp/claude-push-test.jsonl",
      cwd: $cwd,
      permission_mode: "default",
      hook_event_name: "PermissionRequest",
      tool_name: "Bash",
      tool_input: {
        command: "echo '\''hello world'\''",
        description: "Test notification from claude-push"
      },
      permission_suggestions: []
    }')

  # Pipe it into the actual hook script
  if [ "$DEBUG" = true ]; then
    RESULT=$(echo "$FAKE_INPUT" | bash -x "$HOOK_PATH")
  else
    RESULT=$(echo "$FAKE_INPUT" | "$HOOK_PATH")
  fi

  if [ -n "$RESULT" ]; then
    DECISION=$(echo "$RESULT" | jq -r '.hookSpecificOutput.decision.behavior // empty')
    echo "Received: ${DECISION}"
    echo "Test passed!"
  else
    echo "Timeout: no response received."
    echo "Make sure ntfy app is installed and subscribed to your topic."
  fi
}

cmd_status() {
  echo "=== claude-push status ==="
  echo ""

  # Config
  if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    echo "[OK] Config: ${CONFIG_FILE}"
    echo "     Server: ${CLAUDE_PUSH_SERVER}"
    echo "     Topic: ${CLAUDE_PUSH_TOPIC}"
    echo "     Timeout: ${CLAUDE_PUSH_TIMEOUT:-90}s"
    if [ -n "${CLAUDE_PUSH_TOKEN:-}" ]; then
      echo "     Auth: bearer token configured"
    else
      echo "     Auth: none"
    fi
  else
    echo "[NG] Config: not found at ${CONFIG_FILE}"
  fi

  # Hook script
  HOOK_PATH="${INSTALL_DIR}/hooks/claude-push.sh"
  if [ -f "$HOOK_PATH" ] && [ -x "$HOOK_PATH" ]; then
    echo "[OK] Hook: ${HOOK_PATH}"
  else
    echo "[NG] Hook: not found or not executable at ${HOOK_PATH}"
  fi

  # Claude settings
  if [ -f "$CLAUDE_SETTINGS" ] && command -v jq &> /dev/null; then
    HOOK_REGISTERED=$(jq -r '
      .hooks.PermissionRequest // [] | .[] |
      select(.hooks[0].command | test("claude-push")) |
      .hooks[0].command
    ' "$CLAUDE_SETTINGS" 2>/dev/null || true)
    if [ -n "$HOOK_REGISTERED" ]; then
      echo "[OK] Settings: hook registered in ${CLAUDE_SETTINGS}"
    else
      echo "[NG] Settings: hook not found in ${CLAUDE_SETTINGS}"
    fi
  else
    echo "[NG] Settings: ${CLAUDE_SETTINGS} not found or jq missing"
  fi

  # Dependencies
  for cmd in jq curl; do
    if command -v "$cmd" &> /dev/null; then
      echo "[OK] Dependency: ${cmd}"
    else
      echo "[NG] Dependency: ${cmd} not found"
    fi
  done
}

while getopts "d" opt; do
  case "$opt" in
    d) DEBUG=true ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))

case "${1:-}" in
  test-notify) cmd_test_notify ;;
  status) cmd_status ;;
  *) usage ;;
esac
