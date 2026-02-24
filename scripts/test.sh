#!/bin/bash
set -euo pipefail

# claude-push test utility

CONFIG_FILE="${HOME}/.config/claude-push/config"
INSTALL_DIR="${HOME}/.local/share/claude-push"
CLAUDE_SETTINGS="${HOME}/.claude/settings.json"

usage() {
  echo "Usage: $0 <command>"
  echo ""
  echo "Commands:"
  echo "  test-notify  Send a test notification to verify ntfy.sh is working"
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
  check_config

  TOPIC="$CLAUDE_PUSH_TOPIC"
  RESPONSE_TOPIC="${TOPIC}-response"

  echo "Sending test notification to topic: ${TOPIC}"
  echo "Tap 'Allow' or 'Deny' on your device to test the response flow."
  echo ""

  REQ_ID="test-$(date +%s)"

  # Send notification with action buttons
  curl -s -H "Content-Type: application/json" \
    -d "$(jq -n \
      --arg topic "$TOPIC" \
      --arg title "[test] Bash" \
      --arg message "echo 'hello world'" \
      --arg allow_url "https://ntfy.sh/${RESPONSE_TOPIC}" \
      --arg allow_body "allow|$REQ_ID" \
      --arg deny_url "https://ntfy.sh/${RESPONSE_TOPIC}" \
      --arg deny_body "deny|$REQ_ID" \
      '{
        topic: $topic, title: $title, message: $message,
        priority: 4, tags: ["lock"],
        actions: [
          {action:"http",label:"Allow",url:$allow_url,method:"POST",body:$allow_body},
          {action:"http",label:"Deny",url:$deny_url,method:"POST",body:$deny_body}
        ]
      }')" "https://ntfy.sh/" > /dev/null 2>&1

  echo "Notification sent! Waiting for response (timeout: ${CLAUDE_PUSH_TIMEOUT:-90}s)..."

  # Wait for response
  DECISION=""
  while IFS= read -r line; do
    if [[ "$line" == data:* ]]; then
      DATA="${line#data: }"
      MSG=$(echo "$DATA" | jq -r '.message // empty' 2>/dev/null)
      if [[ "$MSG" == *"|$REQ_ID" ]]; then
        DECISION="${MSG%%|*}"
        break
      fi
    fi
  done < <(curl -s -N --max-time "${CLAUDE_PUSH_TIMEOUT:-90}" \
    -H "Accept: text/event-stream" \
    "https://ntfy.sh/${RESPONSE_TOPIC}/sse")

  if [ -n "$DECISION" ]; then
    echo "Received: ${DECISION}"
    echo "Test passed!"
  else
    echo "Timeout: no response received."
    echo "Make sure ntfy app is installed and subscribed to topic: ${TOPIC}"
  fi
}

cmd_status() {
  echo "=== claude-push status ==="
  echo ""

  # Config
  if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    echo "[OK] Config: ${CONFIG_FILE}"
    echo "     Topic: ${CLAUDE_PUSH_TOPIC}"
    echo "     Timeout: ${CLAUDE_PUSH_TIMEOUT:-90}s"
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

case "${1:-}" in
  test-notify) cmd_test_notify ;;
  status) cmd_status ;;
  *) usage ;;
esac
