#!/bin/bash
# claude-push notify — pipe markdown to send a status update to the ntfy topic
#
# Usage:
#   echo "**Done!** All tests passed." | notify.sh
#   echo "## Status\nWorking on step 2/5" | notify.sh -t "Agent update"
#   notify.sh -t "Title" < message.md

set -euo pipefail

CONFIG_FILE="${HOME}/.config/claude-push/config"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "claude-push: config not found at $CONFIG_FILE" >&2
  echo "claude-push: run install.sh to set up" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

TOPIC="${CLAUDE_PUSH_TOPIC:?claude-push: CLAUDE_PUSH_TOPIC not set in config}"
NTFY_SERVER="${CLAUDE_PUSH_SERVER:-https://ntfy.sh}"
NTFY_SERVER="${NTFY_SERVER%/}"

AUTH_HEADER=()
if [ -n "${CLAUDE_PUSH_TOKEN:-}" ]; then
  AUTH_HEADER=( -H "Authorization: Bearer ${CLAUDE_PUSH_TOKEN}" )
fi

TITLE="Agent update"

while getopts "t:" opt; do
  case "$opt" in
    t) TITLE="$OPTARG" ;;
    *) echo "Usage: $0 [-t title]" >&2; exit 1 ;;
  esac
done

MESSAGE="$(cat)"

if [ -z "$MESSAGE" ]; then
  echo "claude-push: no message on stdin" >&2
  exit 1
fi

PUBLISH_REQUEST="$(jq -n \
  --arg topic "$TOPIC" \
  --arg title "$TITLE" \
  --arg message "$MESSAGE" \
  '{
    topic: $topic,
    title: $title,
    message: $message,
    markdown: true,
    priority: 3,
    tags: ["loudspeaker"]
  }')"

PUBLISH_RESPONSE="$(curl -sS -H "Content-Type: application/json" \
  "${AUTH_HEADER[@]}" \
  -d "$PUBLISH_REQUEST" \
  -w '\n%{http_code}' \
  "${NTFY_SERVER}/" 2>&1)"

PUBLISH_HTTP_CODE="${PUBLISH_RESPONSE##*$'\n'}"
PUBLISH_BODY="${PUBLISH_RESPONSE%$'\n'*}"

if [[ ! "$PUBLISH_HTTP_CODE" =~ ^2[0-9][0-9]$ ]]; then
  echo "claude-push: ntfy returned HTTP ${PUBLISH_HTTP_CODE}: ${PUBLISH_BODY}" >&2
  exit 1
fi
