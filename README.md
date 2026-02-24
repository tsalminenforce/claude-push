# claude-push

Mobile push notifications for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) permission requests via [ntfy.sh](https://ntfy.sh).

When Claude Code needs permission to run a tool, you get a push notification on your phone with **Allow** / **Deny** buttons. Tap to respond — no need to stay at your terminal.

## How It Works

```
Claude Code (PermissionRequest hook)
  → ntfy.sh notification with Allow/Deny buttons
    → You tap a button on your phone
      → Response sent back via ntfy.sh SSE
        → Claude Code continues (or stops)
```

Uses Claude Code's [hooks system](https://docs.anthropic.com/en/docs/claude-code/hooks) (`PermissionRequest` event) to intercept permission prompts and route them through ntfy.sh.

## Requirements

- macOS or Linux
- `bash`, `jq`, `curl`
- [ntfy.sh](https://ntfy.sh) app on your phone (iOS / Android)

## Install

```bash
git clone https://github.com/coa00/claude-push.git
cd claude-push
bash install.sh
```

The installer will:

1. Check dependencies (`jq`, `curl`)
2. Ask for an ntfy topic name (or generate a random one)
3. Create config at `~/.config/claude-push/config`
4. Install the hook to `~/.local/share/claude-push/hooks/`
5. Register the hook in `~/.claude/settings.json`
6. Send a test notification

After install, open the ntfy app and subscribe to your topic.

## Usage

Just use Claude Code as normal. When a permission request triggers, you'll get a push notification.

- **Allow** — Claude Code proceeds with the action
- **Deny** — Claude Code cancels the action
- **Timeout** (default 90s) — Falls back to the interactive terminal prompt

### Configuration

Edit `~/.config/claude-push/config`:

```bash
CLAUDE_PUSH_TOPIC="my-unique-topic"   # ntfy topic name
CLAUDE_PUSH_TIMEOUT=90                 # seconds to wait for response
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

For private topics, see [ntfy.sh access control](https://docs.ntfy.sh/config/#access-control).

## Credits

Inspired by [konsti-web/claude_push](https://github.com/konsti-web/claude_push) (Windows/PowerShell + keystroke injection). This repo is a **macOS/Linux + bash + PermissionRequest hook** approach.

## License

MIT
