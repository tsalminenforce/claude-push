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
    AskUserQuestion)
      local header question options_text
      header=$(echo "$input" | jq -r '.questions[0].header // empty')
      question=$(echo "$input" | jq -r '.questions[0].question // empty')
      options_text=$(echo "$input" | jq -r '.questions[0].options // [] | to_entries[] | "**\(.key + 1).** \(.value.label) — \(.value.description // "")"')
      title="Claude has a question"
      if [ -n "$header" ]; then
        title="Claude has a question: ${header}"
      fi
      message="${question}"
      if [ -n "$options_text" ]; then
        message="${message}"$'\n'$'\n'"${options_text}"
      fi
      ;;
    ExitPlanMode)
      local plan_title allowed
      plan_title=$(echo "$input" | jq -r '.plan // empty' | grep -m1 '^#' | sed 's/^#\+ *//')
      plan_title="${plan_title:-Plan}"
      allowed=$(echo "$input" | jq -r '.allowedPrompts // [] | .[] | "- **\(.tool)**: \(.prompt)"')
      title="Claude wants to execute a plan"
      message="**${plan_title}**"
      if [ -n "$allowed" ]; then
        message="${message}"$'\n'$'\n'"Allowed actions:"$'\n'"${allowed}"
      fi
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

REQ_ID="$(date +%s)-$$-$(printf '%04x%04x' "$RANDOM" "$RANDOM")"
SUBSCRIBE_SINCE="$(( $(date +%s) - 1 ))"
NOTIFICATION_PUBLISHED=0

cleanup_notification() {
  [ "${NOTIFICATION_PUBLISHED:-0}" -eq 1 ] || return 0
  [ -n "${REQ_ID:-}" ] || return 0
  curl -fsS -X DELETE \
    "${AUTH_HEADER[@]}" \
    "${NTFY_SERVER}/${TOPIC}/${REQ_ID}" >/dev/null 2>&1 || true
}

handle_signal() {
  local exit_code="$1"
  cleanup_notification
  trap - EXIT
  exit "$exit_code"
}

trap cleanup_notification EXIT
trap 'handle_signal 129' HUP
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

# 1. Build action buttons based on tool type
TOOL_INPUT_JSON=$(echo "$INPUT" | jq '.tool_input // {}')

if [ "$TOOL_NAME" = "AskUserQuestion" ]; then
  # One button per option (ntfy supports up to 3 actions)
  ACTIONS_JSON=$(echo "$TOOL_INPUT_JSON" | jq \
    --arg url "${NTFY_SERVER}/${RESPONSE_TOPIC}" \
    --arg req_id "$REQ_ID" \
    --arg auth "$AUTH_BEARER" \
    '[.questions[0].options // [] | to_entries[:3][] | {
      action: "http",
      label: (.value.label | .[0:40]),
      url: $url,
      method: "POST",
      body: "option:\(.key)|\($req_id)",
      clear: true
    } + (if $auth != "" then {headers:{Authorization:$auth}} else {} end)]')
else
  # Standard Allow/Deny buttons
  ACTIONS_JSON=$(jq -n \
    --arg url "${NTFY_SERVER}/${RESPONSE_TOPIC}" \
    --arg req_id "$REQ_ID" \
    --arg auth "$AUTH_BEARER" \
    '[
      ({action:"http",label:"Allow",url:$url,method:"POST",body:"allow|\($req_id)",clear:true} + (if $auth != "" then {headers:{Authorization:$auth}} else {} end)),
      ({action:"http",label:"Deny",url:$url,method:"POST",body:"deny|\($req_id)",clear:true} + (if $auth != "" then {headers:{Authorization:$auth}} else {} end))
    ]')
fi

# Send notification (markdown format)
PUBLISH_REQUEST="$(jq -n \
  --arg topic "$TOPIC" \
  --arg sequence_id "$REQ_ID" \
  --arg title "[$CWD] $NOTIF_TITLE" \
  --arg message "$NOTIF_MESSAGE" \
  --argjson actions "$ACTIONS_JSON" \
  '{
    topic: $topic, sequence_id: $sequence_id, title: $title, message: $message,
    markdown: true,
    priority: 4, tags: ["lock"],
    actions: $actions
  }')"

PUBLISH_RESPONSE="$(curl -sS -H "Content-Type: application/json" \
  "${AUTH_HEADER[@]}" \
  -d "$PUBLISH_REQUEST" \
  -w '\n%{http_code}' \
  "${NTFY_SERVER}/" 2>&1)"
PUBLISH_STATUS=$?

if [ "$PUBLISH_STATUS" -ne 0 ]; then
  echo "claude-push: failed to publish ntfy notification: ${PUBLISH_RESPONSE}" >&2
  exit 0
fi

PUBLISH_HTTP_CODE="${PUBLISH_RESPONSE##*$'\n'}"
PUBLISH_BODY="${PUBLISH_RESPONSE%$'\n'*}"

if [[ ! "$PUBLISH_HTTP_CODE" =~ ^2[0-9][0-9]$ ]]; then
  echo "claude-push: ntfy publish returned HTTP ${PUBLISH_HTTP_CODE}: ${PUBLISH_BODY}" >&2
  exit 0
fi

if ! printf '%s\n' "$PUBLISH_BODY" | jq -e '.event == "message" and (.id | type == "string")' >/dev/null 2>&1; then
  echo "claude-push: ntfy publish returned unexpected response: ${PUBLISH_BODY}" >&2
  exit 0
fi

NOTIFICATION_PUBLISHED=1

# 2. Wait for response via SSE
DECISION=""
while IFS= read -r line; do
  if [[ "$line" == data:* ]]; then
    DATA="${line#data: }"
    MSG=$(printf '%s\n' "$DATA" | jq -r 'select(.event == "message") | .message // empty' 2>/dev/null)
    case "$MSG" in
      "allow|$REQ_ID")
        DECISION="allow"
        break
        ;;
      "deny|$REQ_ID")
        DECISION="deny"
        break
        ;;
      "option:"*"|$REQ_ID")
        DECISION="${MSG%%|*}"
        break
        ;;
    esac
  fi
done < <(curl -s -N --max-time "$WAIT_TIMEOUT" \
  "${AUTH_HEADER[@]}" \
  -H "Accept: text/event-stream" \
  "${NTFY_SERVER}/${RESPONSE_TOPIC}/sse?since=${SUBSCRIBE_SINCE}")

# 3. Output decision JSON
if [[ "$DECISION" == option:* ]]; then
  OPTION_IDX="${DECISION#option:}"
  SELECTED=$(echo "$INPUT" | jq --argjson idx "$OPTION_IDX" '.tool_input.questions[0].options[$idx].label // empty')
  jq -n --argjson idx "$OPTION_IDX" --argjson sel "$SELECTED" '{
    hookSpecificOutput: {
      hookEventName: "PermissionRequest",
      decision: {
        behavior: "allow",
        updatedInput: {
          answers: [{ selectedIndex: $idx, selectedOption: $sel }]
        }
      }
    }
  }'
elif [ "$DECISION" = "allow" ]; then
  jq -n '{hookSpecificOutput:{hookEventName:"PermissionRequest",decision:{behavior:"allow"}}}'
elif [ "$DECISION" = "deny" ]; then
  jq -n '{hookSpecificOutput:{hookEventName:"PermissionRequest",decision:{behavior:"deny"}}}'
fi
# Timeout or no decision: no output, exit 0 -> falls back to interactive prompt
