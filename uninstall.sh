#!/bin/bash
set -euo pipefail

# claude-push uninstaller

INSTALL_DIR="${HOME}/.local/share/claude-push"
CONFIG_DIR="${HOME}/.config/claude-push"
CLAUDE_SETTINGS="${HOME}/.claude/settings.json"

echo "=== claude-push uninstaller ==="
echo ""

# 1. Remove hook from Claude settings
if [ -f "$CLAUDE_SETTINGS" ] && command -v jq &> /dev/null; then
  if jq -e '.hooks.PermissionRequest' "$CLAUDE_SETTINGS" > /dev/null 2>&1; then
    UPDATED=$(jq '
      .hooks.PermissionRequest = [
        .hooks.PermissionRequest[] | select(.hooks[0].command | test("claude-push") | not)
      ] |
      if (.hooks.PermissionRequest | length) == 0 then del(.hooks.PermissionRequest) else . end
    ' "$CLAUDE_SETTINGS")
    echo "$UPDATED" > "$CLAUDE_SETTINGS"
    echo "Removed hook from ${CLAUDE_SETTINGS}"
  else
    echo "No PermissionRequest hook found in settings (skipped)"
  fi
else
  echo "Warning: could not update ${CLAUDE_SETTINGS} (file missing or jq not installed)"
fi

# 2. Remove installed files
if [ -d "$INSTALL_DIR" ]; then
  rm -rf "$INSTALL_DIR"
  echo "Removed ${INSTALL_DIR}"
else
  echo "No install directory found (skipped)"
fi

# 3. Remove config (with confirmation)
if [ -d "$CONFIG_DIR" ]; then
  read -rp "Remove config at ${CONFIG_DIR}? [y/N]: " answer
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    rm -rf "$CONFIG_DIR"
    echo "Removed ${CONFIG_DIR}"
  else
    echo "Kept ${CONFIG_DIR}"
  fi
else
  echo "No config directory found (skipped)"
fi

echo ""
echo "=== Uninstall complete ==="
