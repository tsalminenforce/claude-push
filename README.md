# claude-push

Mobile push notifications for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and [OpenCode](https://opencode.ai/) permission requests via [ntfy](https://ntfy.sh) (public `ntfy.sh` or self-hosted).

When Claude Code or OpenCode needs permission to run a tool, you get a push notification on your phone with **Allow** / **Deny** buttons. Tap to respond without staying at your terminal.

## How It Works

```
Claude Code hook / OpenCode plugin
  → ntfy notification with Allow/Deny buttons
    → You tap a button on your phone
      → Response sent back via ntfy SSE
        → tool execution continues (or stops)
```

Uses Claude Code's [hooks system](https://docs.anthropic.com/en/docs/claude-code/hooks) (`PermissionRequest` event) and an OpenCode [plugin](https://opencode.ai/docs/plugins/) (`permission.ask`) to intercept permission prompts and route them through ntfy.

## Requirements

- macOS or Linux
- `bash`, `jq`, `curl`
- [ntfy.sh](https://ntfy.sh) app on your phone (iOS / Android)

## Install

```bash
git clone https://github.com/tsalminenforce/claude-push.git
cd claude-push
bash install.sh
```

The installer will:

1. Check dependencies (`jq`, `curl`)
2. Ask for an ntfy topic name (or generate a random one)
3. Create config at `~/.config/claude-push/config`
4. Install the hook to `~/.local/share/claude-push/hooks/`
5. Register the hook in `~/.claude/settings.json`
6. Install the OpenCode plugin to `~/.config/opencode/plugins/opencode-push.ts`
7. Print the OpenCode `permission` block to merge into your config
8. Send a test notification

After install, open the ntfy app and subscribe to your topic.

## Usage

Just use Claude Code or OpenCode as normal. When a permission request triggers, you'll get a push notification with markdown-formatted details about the requested action.

- **Allow** — the tool call proceeds
- **Deny** — the tool call is blocked
- **Timeout** (default 90s) — falls back to the interactive terminal prompt or OpenCode approval UI

### OpenCode Notes

OpenCode only asks for approval when the relevant permissions are configured as `ask`.

The installer prints this block for you to merge into `~/.config/opencode/opencode.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "permission": {
    "bash": "ask",
    "edit": "ask",
    "task": "ask",
    "webfetch": "ask"
  }
}
```

Merge it into your existing config rather than replacing the whole file.

### Notification Format

Each notification includes:

- **Folder** — The working directory where the action was triggered
- **Tool and Details** — Formatted in markdown:
  - `Bash` — Command with description and code block
  - `Edit` — File path with diff-style changes
  - `Write` — File path with content preview
  - `Read`, `Glob`, `Grep`, etc. — Relevant action details
  - Others — JSON representation

### Configuration

Claude Code and OpenCode share the same config file at `~/.config/claude-push/config`:

```bash
CLAUDE_PUSH_TOPIC="my-unique-topic"   # ntfy topic name
CLAUDE_PUSH_TIMEOUT=90                 # seconds to wait for response
CLAUDE_PUSH_SERVER="https://ntfy.sh"  # optional: ntfy base URL (self-hosted supported)
CLAUDE_PUSH_TOKEN=""                  # optional: bearer token for protected server/topics
```

Changes take effect immediately (no reinstall needed).

### Test

```bash
# Send a test notification with Allow/Deny buttons
bash scripts/test.sh test-notify

# Check installation status
bash scripts/test.sh status
```

## Uninstall

```bash
bash uninstall.sh
```

Removes the hook from Claude settings, installed files, and optionally the config.

## Security

The ntfy topic name acts as a shared secret. Use a unique, hard-to-guess name. Anyone who knows your topic name can send you notifications or respond to your permission requests.

If your server/topics require auth, set `CLAUDE_PUSH_TOKEN` in config. Both the Claude hook and OpenCode plugin send it as a bearer token for publish, response listening (SSE), and Allow/Deny action callbacks.

For private topics, see [ntfy.sh access control](https://docs.ntfy.sh/config/#access-control).

## Credits

Inspired by [konsti-web/claude_push](https://github.com/konsti-web/claude_push) (Windows/PowerShell + keystroke injection). This repo is a **macOS/Linux + bash Claude hook + TypeScript OpenCode plugin** approach.

## License

MIT
