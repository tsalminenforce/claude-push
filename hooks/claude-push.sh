#!/bin/bash
# Claude Code PermissionRequest hook -> ntfy with Allow/Deny actions
# Sends notification with action buttons, waits for response via SSE

CONFIG_FILE="${HOME}/.config/claude-push/config"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "claude-push: config not found at $CONFIG_FILE" >&2
  echo "claude-push: run install.sh to set up, falling back to interactive prompt" >&2
  exit 0
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

if [ "${CLAUDE_PUSH_DEBUG:-}" = "true" ]; then
  DEBUG_LOG="/tmp/claude-push-hook-debug.txt"
  exec 2>>"$DEBUG_LOG"
  set -x
  echo "=== claude-push debug $(date) ===" >&2
fi

TOPIC="${CLAUDE_PUSH_TOPIC:?claude-push: CLAUDE_PUSH_TOPIC not set in config}"
RESPONSE_TOPIC="${TOPIC}-response"
WAIT_TIMEOUT="${CLAUDE_PUSH_TIMEOUT:-90}"
NTFY_SERVER="${CLAUDE_PUSH_SERVER:-https://ntfy.sh}"  # config must include scheme
NTFY_SERVER="${NTFY_SERVER%/}"

AUTH_BEARER=""
AUTH_HEADER=()
if [ -n "${CLAUDE_PUSH_TOKEN:-}" ]; then
  AUTH_BEARER="Bearer ${CLAUDE_PUSH_TOKEN}"
  AUTH_HEADER=( -H "Authorization: ${AUTH_BEARER}" )
fi

INPUT=$(cat | tee /tmp/last-hook)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "Unknown"')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# Format human-readable title and message based on tool type
format_notification() {
  local tool="$1" input="$2"
  local title message

  case "$tool" in
    Bash)
      local cmd desc
      cmd=$(echo "$input" | jq -r '.command // empty')
      desc=$(echo "$input" | jq -r '.description // empty')
      title="Claude wants to run a command"
      message="$cmd"
      if [ -n "$desc" ]; then
        message="${desc}"$'\n'"\`\`\`"$'\n'"${cmd}"$'\n'"\`\`\`"
      fi
      ;;
    Edit)
      local file old new
      file=$(echo "$input" | jq -r '.file_path // empty')
      old=$(echo "$input" | jq -r '.old_string // empty' | head -c 200)
      new=$(echo "$input" | jq -r '.new_string // empty' | head -c 200)
      file="${file#"$CWD/"}"
      title="Claude wants to edit a file"
      message="**${file}**"$'\n'"\`\`\`diff"$'\n'"- ${old}"$'\n'"+ ${new}"$'\n'"\`\`\`"
      ;;
    Write)
      local file content
      file=$(echo "$input" | jq -r '.file_path // empty')
      content=$(echo "$input" | jq -r '.content // empty' | head -c 200)
      file="${file#"$CWD/"}"
      title="Claude wants to write a file"
      message="**${file}**"$'\n'"\`\`\`"$'\n'"${content}"$'\n'"\`\`\`"
      ;;
    Read)
      local file
      file=$(echo "$input" | jq -r '.file_path // empty')
      file="${file#"$CWD/"}"
      title="Claude wants to read a file"
      message="**${file}**"
      ;;
    Glob)
      local pattern
      pattern=$(echo "$input" | jq -r '.pattern // empty')
      title="Claude wants to search for files"
      message="Pattern: \`${pattern}\`"
      ;;
    Grep)
      local pattern path
      pattern=$(echo "$input" | jq -r '.pattern // empty')
      path=$(echo "$input" | jq -r '.path // empty')
      path="${path#"$CWD/"}"
      title="Claude wants to search file contents"
      message="Pattern: \`${pattern}\`"
      if [ -n "$path" ]; then
        message="${message}"$'\n'"Path: **${path}**"
      fi
      ;;
    Agent)
      local desc
      desc=$(echo "$input" | jq -r '.description // .prompt // empty' | head -c 200)
      title="Claude wants to launch a sub-agent"
      message="$desc"
      ;;
    WebFetch)
      local url
      url=$(echo "$input" | jq -r '.url // empty')
      title="Claude wants to fetch a URL"
      message="$url"
      ;;
    *)
      title="Claude requests permission for ${tool}"
      message=$(echo "$input" | jq -r 'tostring' | head -c 300)
      message=$'\`\`\`json\n'"${message}"$'\n\`\`\`'
      ;;
  esac

  echo "$title"
  echo "---"
  echo "$message"
}

NOTIFICATION=$(format_notification "$TOOL_NAME" "$(echo "$INPUT" | jq '.tool_input // {}')")
NOTIF_TITLE=$(echo "$NOTIFICATION" | head -1)
NOTIF_MESSAGE=$(echo "$NOTIFICATION" | tail -n +3)

if [ -n "$CWD" ]; then
  NOTIF_MESSAGE="Folder: **${CWD}** "$'\n'"${NOTIF_MESSAGE}"
fi

REQ_ID="$(date +%s)-$$"

# 1. Send notification with Allow/Deny action buttons (markdown format)
curl -s -H "Content-Type: application/json" \
  "${AUTH_HEADER[@]}" \
  -d "$(jq -n \
    --arg topic "$TOPIC" \
    --arg title "[$CWD] $NOTIF_TITLE" \
    --arg message "$NOTIF_MESSAGE" \
    --arg allow_url "${NTFY_SERVER}/${RESPONSE_TOPIC}" \
    --arg allow_body "allow|$REQ_ID" \
    --arg deny_url "${NTFY_SERVER}/${RESPONSE_TOPIC}" \
    --arg deny_body "deny|$REQ_ID" \
    --arg auth "$AUTH_BEARER" \
    '{
      topic: $topic, title: $title, message: $message,
      markdown: true,
      priority: 4, tags: ["lock"],
      actions: [
        ({action:"http",label:"Allow",url:$allow_url,method:"POST",body:$allow_body} + (if $auth != "" then {headers:{Authorization:$auth}} else {} end)),
        ({action:"http",label:"Deny",url:$deny_url,method:"POST",body:$deny_body} + (if $auth != "" then {headers:{Authorization:$auth}} else {} end))
      ]
    }')" "${NTFY_SERVER}/" > /dev/null 2>&1

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
  "${AUTH_HEADER[@]}" \
  -H "Accept: text/event-stream" \
  "${NTFY_SERVER}/${RESPONSE_TOPIC}/sse")

# 3. Output decision JSON
if [ "$DECISION" = "allow" ]; then
  jq -n '{hookSpecificOutput:{hookEventName:"PermissionRequest",decision:{behavior:"allow"}}}'
elif [ "$DECISION" = "deny" ]; then
  jq -n '{hookSpecificOutput:{hookEventName:"PermissionRequest",decision:{behavior:"deny"}}}'
fi
# Timeout or no decision: no output, exit 0 -> falls back to interactive prompt
