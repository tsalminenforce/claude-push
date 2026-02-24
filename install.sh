#!/bin/bash
set -euo pipefail

# claude-push installer
# Sets up ntfy.sh push notifications for Claude Code permission requests

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

# 2. Ask for ntfy topic
DEFAULT_TOPIC="claude-push-$(openssl rand -hex 4)"
echo "ntfy.sh topic name is used to route notifications to your device."
echo "Use a unique, hard-to-guess name (it acts as a shared secret)."
echo ""
read -rp "ntfy topic [${DEFAULT_TOPIC}]: " TOPIC
TOPIC="${TOPIC:-$DEFAULT_TOPIC}"

# 3. Ask for timeout
read -rp "Timeout in seconds [90]: " TIMEOUT
TIMEOUT="${TIMEOUT:-90}"

# 4. Create config
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_FILE" <<EOF
# claude-push configuration
CLAUDE_PUSH_TOPIC="${TOPIC}"
CLAUDE_PUSH_TIMEOUT=${TIMEOUT}
EOF
echo "Config written to ${CONFIG_FILE}"

# 5. Install hook script
mkdir -p "$INSTALL_DIR/hooks"
cp "$SCRIPT_DIR/hooks/claude-push.sh" "$INSTALL_DIR/hooks/claude-push.sh"
chmod +x "$INSTALL_DIR/hooks/claude-push.sh"
echo "Hook installed to ${INSTALL_DIR}/hooks/claude-push.sh"

# 6. Register hook in Claude settings
HOOK_CMD="${INSTALL_DIR}/hooks/claude-push.sh"

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

# 7. Test notification
echo ""
echo "Sending test notification to topic: ${TOPIC}"
echo "Make sure ntfy app is installed and subscribed to this topic."
echo ""

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Title: claude-push test" \
  -H "Priority: 3" \
  -H "Tags: white_check_mark" \
  -d "Installation successful! You will receive notifications here." \
  "https://ntfy.sh/${TOPIC}")

if [ "$HTTP_CODE" = "200" ]; then
  echo "Test notification sent! Check your device."
else
  echo "Warning: notification send returned HTTP ${HTTP_CODE}"
fi

echo ""
echo "=== Installation complete ==="
echo ""
echo "Next steps:"
echo "  1. Install ntfy app on your phone (https://ntfy.sh)"
echo "  2. Subscribe to topic: ${TOPIC}"
echo "  3. Start Claude Code - permission requests will be pushed to your device"
echo ""
echo "To verify: bash ${SCRIPT_DIR}/scripts/test.sh test-notify"
echo "To check:  bash ${SCRIPT_DIR}/scripts/test.sh status"
