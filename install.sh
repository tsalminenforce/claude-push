#!/bin/bash
set -euo pipefail

# claude-push installer
# Sets up ntfy push notifications for Claude Code permission requests

INSTALL_DIR="${HOME}/.local/share/claude-push"
CONFIG_DIR="${HOME}/.config/claude-push"
CONFIG_FILE="${CONFIG_DIR}/config"
CLAUDE_SETTINGS="${HOME}/.claude/settings.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== claude-push installer ==="
echo ""

# 1. Dependency check
missing=()
for cmd in jq curl; do
  if ! command -v "$cmd" &> /dev/null; then
    missing+=("$cmd")
  fi
done

if [ ${#missing[@]} -gt 0 ]; then
  echo "Error: missing dependencies: ${missing[*]}"
  echo "Install them first:"
  echo "  brew install ${missing[*]}   # macOS"
  echo "  apt install ${missing[*]}    # Debian/Ubuntu"
  exit 1
fi

if [ -f "$CONFIG_FILE" ]; then
  echo "Existing config found at ${CONFIG_FILE}, skipping configuration."
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
  TOPIC="${CLAUDE_PUSH_TOPIC}"
  SERVER="${CLAUDE_PUSH_SERVER}"
  TOKEN="${CLAUDE_PUSH_TOKEN:-}"
else
  # 2. Ask for ntfy server
  echo "ntfy server URL (leave empty for public ntfy.sh)."
  read -rp "Server URL [https://ntfy.sh]: " SERVER
  SERVER="${SERVER:-https://ntfy.sh}"
  SERVER="${SERVER%/}"
  echo ""

  # 3. Ask for ntfy topic
  DEFAULT_TOPIC="claude-push-$(openssl rand -hex 4)"
  echo "ntfy topic name is used to route notifications to your device."
  echo "Use a unique, hard-to-guess name (it acts as a shared secret)."
  echo ""
  read -rp "ntfy topic [${DEFAULT_TOPIC}]: " TOPIC
  TOPIC="${TOPIC:-$DEFAULT_TOPIC}"

  # 4. Ask for bearer token
  echo ""
  echo "Bearer token for authentication (leave empty if not required)."
  echo "Needed for protected servers/topics."
  read -rp "Bearer token []: " TOKEN

  # 5. Ask for timeout
  read -rp "Timeout in seconds [90]: " TIMEOUT
  TIMEOUT="${TIMEOUT:-90}"

  # 6. Create config
  mkdir -p "$CONFIG_DIR"
  cat > "$CONFIG_FILE" <<EOF
# claude-push configuration
CLAUDE_PUSH_TOPIC="${TOPIC}"
CLAUDE_PUSH_TIMEOUT=${TIMEOUT}
CLAUDE_PUSH_SERVER="${SERVER}"
CLAUDE_PUSH_TOKEN="${TOKEN}"
EOF
  echo "Config written to ${CONFIG_FILE}"
fi

# 7. Install hook script and register in Claude settings
HOOK_CMD="${INSTALL_DIR}/hooks/claude-push.sh"

mkdir -p "$INSTALL_DIR/hooks"
cp "$SCRIPT_DIR/hooks/claude-push.sh" "$INSTALL_DIR/hooks/claude-push.sh"
chmod +x "$INSTALL_DIR/hooks/claude-push.sh"
echo "Hook installed to ${INSTALL_DIR}/hooks/claude-push.sh"

HOOK_REGISTERED=false
if [ -f "$CLAUDE_SETTINGS" ] && \
   jq -e '.hooks.PermissionRequest // [] | .[] | select(.hooks[0].command | test("claude-push"))' "$CLAUDE_SETTINGS" > /dev/null 2>&1; then
  HOOK_REGISTERED=true
fi

if [ "$HOOK_REGISTERED" = true ]; then
  echo "Hook already registered in ${CLAUDE_SETTINGS}, skipping."
else

  mkdir -p "$(dirname "$CLAUDE_SETTINGS")"

  if [ ! -f "$CLAUDE_SETTINGS" ]; then
    echo '{}' > "$CLAUDE_SETTINGS"
  fi

  # Build the new hook entry
  NEW_HOOK=$(jq -n --arg cmd "$HOOK_CMD" '{
    matcher: "",
    hooks: [{
      type: "command",
      command: $cmd,
      timeout: 120
    }]
  }')

  # Merge into settings: append to existing PermissionRequest array or create it
  UPDATED=$(jq --argjson hook "$NEW_HOOK" '
    # Remove any existing claude-push hooks to avoid duplicates
    .hooks.PermissionRequest = [
      (.hooks.PermissionRequest // [] | .[] | select(.hooks[0].command | test("claude-push") | not))
    ] + [$hook]
  ' "$CLAUDE_SETTINGS")

  echo "$UPDATED" > "$CLAUDE_SETTINGS"
  echo "Hook registered in ${CLAUDE_SETTINGS}"
fi

# 9. Test notification
echo ""
echo "Sending test notification to topic: ${TOPIC} on ${SERVER}"
echo "Make sure ntfy app is installed and subscribed to this topic."
echo ""

AUTH_HEADER=()
if [ -n "$TOKEN" ]; then
  AUTH_HEADER=( -H "Authorization: Bearer ${TOKEN}" )
fi

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  "${AUTH_HEADER[@]}" \
  -H "Title: claude-push test" \
  -H "Priority: 3" \
  -H "Tags: white_check_mark" \
  -d "Installation successful! You will receive notifications here." \
  "${SERVER}/${TOPIC}")

if [ "$HTTP_CODE" = "200" ]; then
  echo "Test notification sent to ${SERVER}/${TOPIC}! Check your device."
else
  echo "Warning: notification to ${SERVER}/${TOPIC} returned HTTP ${HTTP_CODE}"
fi

echo ""
echo "=== Installation complete ==="
echo ""
echo "Next steps:"
echo "  1. Install ntfy app on your phone (${SERVER})"
echo "  2. Subscribe to topic: ${TOPIC}"
echo "  3. Start Claude Code - permission requests will be pushed to your device"
echo ""
echo "To verify: bash ${SCRIPT_DIR}/scripts/test.sh test-notify"
echo "To check:  bash ${SCRIPT_DIR}/scripts/test.sh status"
