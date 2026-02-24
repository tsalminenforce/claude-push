#!/bin/bash
# Claude Code PermissionRequest hook -> ntfy.sh with Allow/Deny actions
# Sends notification with action buttons, waits for response via SSE

CONFIG_FILE="${HOME}/.config/claude-push/config"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "claude-push: config not found at $CONFIG_FILE" >&2
  echo "claude-push: run install.sh to set up, falling back to interactive prompt" >&2
  exit 0
fi

source "$CONFIG_FILE"

TOPIC="${CLAUDE_PUSH_TOPIC:?claude-push: CLAUDE_PUSH_TOPIC not set in config}"
RESPONSE_TOPIC="${TOPIC}-response"
WAIT_TIMEOUT="${CLAUDE_PUSH_TIMEOUT:-90}"

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "Unknown"')
TOOL_INPUT=$(echo "$INPUT" | jq -r '.tool_input // {} | tostring' | head -c 200)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
PROJECT=$(basename "$CWD" 2>/dev/null || echo "unknown")

REQ_ID="$(date +%s)-$$"

# 1. Send notification with Allow/Deny action buttons
curl -s -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg topic "$TOPIC" \
    --arg title "[$PROJECT] $TOOL_NAME" \
    --arg message "$TOOL_INPUT" \
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

# 2. Wait for response via SSE
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
done < <(curl -s -N --max-time "$WAIT_TIMEOUT" \
  -H "Accept: text/event-stream" \
  "https://ntfy.sh/${RESPONSE_TOPIC}/sse")

# 3. Output decision JSON
if [ "$DECISION" = "allow" ]; then
  jq -n '{hookSpecificOutput:{hookEventName:"PermissionRequest",decision:{behavior:"allow"}}}'
elif [ "$DECISION" = "deny" ]; then
  jq -n '{hookSpecificOutput:{hookEventName:"PermissionRequest",decision:{behavior:"deny"}}}'
fi
# Timeout or no decision: no output, exit 0 -> falls back to interactive prompt
