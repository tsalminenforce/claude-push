import { appendFile, readFile } from "node:fs/promises"
import { homedir } from "node:os"

const CONFIG_FILE = `${homedir()}/.config/claude-push/config`
const DEFAULT_SERVER = "https://ntfy.sh"
const DEFAULT_TIMEOUT_SECONDS = 90
const PREVIEW_LIMIT = 300
const PROBE_FILE = "/tmp/opencode_push_probe.log"

type PermissionInput = {
  id: string
  type: string
  title?: string
  pattern?: string | string[]
  metadata?: Record<string, unknown>
}

type PermissionOutput = {
  status: "ask" | "allow" | "deny"
}

type PermissionAskedEvent = {
  type: "permission.asked"
  properties: {
    id: string
    sessionID: string
    permission: string
    patterns: string[]
    metadata: Record<string, unknown>
  }
}

type PluginEvent = PermissionAskedEvent | { type: string; properties?: Record<string, unknown> }

type SharedConfig = {
  topic: string
  responseTopic: string
  timeoutSeconds: number
  server: string
  token: string
  debug: boolean
}

type Notification = {
  title: string
  message: string
}

void appendProbe("module evaluated")

export const OpencodePush = async ({
  client,
  directory,
  serverUrl,
  worktree,
}: {
  client: {
    permission?: {
      respond: (parameters: { sessionID: string; permissionID: string; directory?: string; response?: "once" | "always" | "reject" }) => Promise<{ error?: unknown; response: Response }>
    }
    postSessionIdPermissionsPermissionId?: (options: {
      path: { id: string; permissionID: string }
      body: { response: "once" | "always" | "reject" }
      headers?: Record<string, string>
    }) => Promise<{ data?: unknown; error?: unknown; request: Request; response: Response }>
  }
  directory: string
  serverUrl?: URL
  worktree?: string
}) => {
  void appendProbe("server initialized", {
    directory,
    worktree,
    serverUrl: serverUrl ? String(serverUrl) : undefined,
    hasClient: client !== undefined,
    clientKeys: client && typeof client === "object" ? Object.keys(client as Record<string, unknown>) : undefined,
  })

  return {
    event: async ({ event }: { event: PluginEvent }) => {
      if (event.type !== "permission.asked") {
        return
      }

      await handlePermissionEvent(client, event, directory)
    },
    "permission.ask": async (input: PermissionInput, output: PermissionOutput) => {
      output.status = "ask"
      let config: SharedConfig | null = null
      void appendProbe("permission.ask entered", {
        id: input.id,
        type: input.type,
        title: input.title,
        pattern: input.pattern,
      })

      try {
        config = await loadConfig()
        if (!config) {
          void appendProbe("loadConfig returned null")
          return
        }

        debugLog(config, "permission.ask received", {
          id: input.id,
          type: input.type,
          title: input.title,
          pattern: input.pattern,
        })

        const requestId = buildRequestId()
        const notification = formatNotification(input, directory)
        const published = await publishNotification(config, requestId, notification, directory)

        if (!published) {
          debugLog(config, "notification publish failed", { requestId })
          return
        }

        debugLog(config, "notification published", {
          requestId,
          responseTopic: config.responseTopic,
        })

        try {
          const decision = await waitForDecision(config, requestId)
          debugLog(config, "permission decision received", {
            requestId,
            decision: decision ?? "timeout",
          })
          if (decision === "allow" || decision === "deny") {
            output.status = decision
          }
        } finally {
          await deleteNotification(config, requestId)
        }
      } catch (error) {
        debugLog(config, "permission.ask failed", {
          error: formatError(error),
        })
        output.status = "ask"
      }
    },
  }
}

export const server = OpencodePush

async function handlePermissionEvent(
  client: {
    permission?: {
      respond: (parameters: { sessionID: string; permissionID: string; directory?: string; response?: "once" | "always" | "reject" }) => Promise<{ error?: unknown; response: Response }>
    }
    postSessionIdPermissionsPermissionId?: (options: {
      path: { id: string; permissionID: string }
      body: { response: "once" | "always" | "reject" }
      headers?: Record<string, string>
    }) => Promise<{ data?: unknown; error?: unknown; request: Request; response: Response }>
  },
  event: PermissionAskedEvent,
  directory: string,
): Promise<void> {
  const request = event.properties
  void appendProbe("permission.asked event received", {
    id: request.id,
    sessionID: request.sessionID,
    permission: request.permission,
    patterns: request.patterns,
  })

  const config = await loadConfig()
  if (!config) {
    void appendProbe("event loadConfig returned null")
    return
  }

  const input: PermissionInput = {
    id: request.id,
    type: request.permission,
    pattern: request.patterns,
    metadata: request.metadata,
  }
  const notification = formatNotification(input, directory)
  const published = await publishNotification(config, request.id, notification, directory)
  if (!published) {
    debugLog(config, "event notification publish failed", {
      requestId: request.id,
      permission: request.permission,
    })
    return
  }

  debugLog(config, "event notification published", {
    requestId: request.id,
    sessionID: request.sessionID,
  })

  try {
    const decision = await waitForDecision(config, request.id)
    if (!decision) {
      return
    }

    const reply = toPermissionReply(decision)
    const result = await replyToPermission(client, config, request.sessionID, request.id, directory, reply)
    if (result.error || !result.response.ok) {
      const body = await result.response.text().catch(() => "")
      debugLog(config, "permission reply rejected", {
        requestId: request.id,
        status: result.response.status,
        body: truncate(body, PREVIEW_LIMIT),
        error: result.error ? stringifyPreview(result.error) : undefined,
      })
      return
    }

    debugLog(config, "permission replied from event", {
      requestId: request.id,
      reply,
    })
  } finally {
    await deleteNotification(config, request.id)
  }
}

async function loadConfig(): Promise<SharedConfig | null> {
  let raw: string

  try {
    raw = await readFile(CONFIG_FILE, "utf8")
  } catch {
    return null
  }

  const parsed = parseShellConfig(raw)
  const topic = parsed.CLAUDE_PUSH_TOPIC?.trim()
  if (!topic) {
    return null
  }

  const timeoutSeconds = parsePositiveInteger(parsed.CLAUDE_PUSH_TIMEOUT) ?? DEFAULT_TIMEOUT_SECONDS
  const server = normalizeServer(parsed.CLAUDE_PUSH_SERVER)
  const token = parsed.CLAUDE_PUSH_TOKEN ?? ""
  const debug = parseBoolean(parsed.CLAUDE_PUSH_DEBUG)

  return {
    topic,
    responseTopic: `${topic}-response`,
    timeoutSeconds,
    server,
    token,
    debug,
  }
}

function parseShellConfig(text: string): Record<string, string> {
  const result: Record<string, string> = {}

  for (const line of text.split(/\r?\n/u)) {
    const trimmed = line.trim()
    if (!trimmed || trimmed.startsWith("#")) {
      continue
    }

    const match = trimmed.match(/^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$/u)
    if (!match) {
      continue
    }

    const [, key, rawValue] = match
    result[key] = parseShellValue(rawValue.trim())
  }

  return result
}

function parseShellValue(rawValue: string): string {
  if (rawValue.startsWith("\"") && rawValue.endsWith("\"")) {
    return decodeDoubleQuotedValue(rawValue.slice(1, -1))
  }

  if (rawValue.startsWith("'") && rawValue.endsWith("'")) {
    return rawValue.slice(1, -1)
  }

  return rawValue
}

function decodeDoubleQuotedValue(value: string): string {
  let result = ""

  for (let index = 0; index < value.length; index += 1) {
    const char = value[index]
    if (char !== "\\") {
      result += char
      continue
    }

    index += 1
    const escaped = value[index]
    if (escaped === undefined) {
      result += "\\"
      break
    }

    switch (escaped) {
      case "n":
        result += "\n"
        break
      case "r":
        result += "\r"
        break
      case "t":
        result += "\t"
        break
      case '"':
      case "\\":
      case "$":
      case "`":
        result += escaped
        break
      default:
        result += escaped
        break
    }
  }

  return result
}

function parsePositiveInteger(value: string | undefined): number | undefined {
  if (!value) {
    return undefined
  }

  const parsed = Number.parseInt(value, 10)
  if (!Number.isFinite(parsed) || parsed <= 0) {
    return undefined
  }

  return parsed
}

function parseBoolean(value: string | undefined): boolean {
  if (!value) {
    return false
  }

  switch (value.trim().toLowerCase()) {
    case "1":
    case "true":
    case "yes":
    case "on":
      return true
    default:
      return false
  }
}

function normalizeServer(value: string | undefined): string {
  const server = (value?.trim() || DEFAULT_SERVER).replace(/\/+$/u, "")
  return server || DEFAULT_SERVER
}

function toPermissionReply(decision: "allow" | "deny"): "once" | "reject" {
  return decision === "allow" ? "once" : "reject"
}

function buildRequestId(): string {
  const random = Math.random().toString(16).slice(2, 10)
  return `${Date.now()}-${random}`
}

function formatNotification(input: PermissionInput, directory: string): Notification {
  const metadata = asRecord(input.metadata)
  const title = input.title?.trim() || `OpenCode requests permission for ${input.type}`
  const tool = pickFirstString(metadata, [["tool"]]) || input.type
  const pattern = formatPattern(input.pattern)

  const command = pickFirstString(metadata, [["command"], ["args", "command"]])
  const description = pickFirstString(metadata, [["description"], ["args", "description"]])
  const filePath = relativizePath(
    pickFirstString(metadata, [["filePath"], ["path"], ["file"], ["args", "filePath"], ["args", "path"]]),
    directory,
  )
  const oldString = pickFirstString(metadata, [["oldString"], ["args", "oldString"]])
  const newString = pickFirstString(metadata, [["newString"], ["args", "newString"]])
  const content = pickFirstString(metadata, [["content"], ["args", "content"]])
  const searchPattern = pickFirstString(metadata, [["pattern"], ["args", "pattern"], ["query"], ["args", "query"]])
  const url = pickFirstString(metadata, [["url"], ["args", "url"]])
  const agent = pickFirstString(metadata, [["subagentType"], ["subagent_type"], ["agent"], ["description"], ["prompt"]])
  const lines: string[] = []

  switch (tool) {
    case "bash":
      if (description) {
        lines.push(description)
      }
      if (command) {
        lines.push(codeBlock(truncate(command, PREVIEW_LIMIT)))
      }
      break
    case "edit":
      if (filePath) {
        lines.push(`**${filePath}**`)
      }
      if (oldString || newString) {
        lines.push(diffBlock(truncate(oldString || "", 160), truncate(newString || "", 160)))
      } else if (content) {
        lines.push(codeBlock(truncate(content, PREVIEW_LIMIT)))
      }
      break
    case "read":
      if (filePath) {
        lines.push(`**${filePath}**`)
      }
      break
    case "glob":
    case "grep":
      if (searchPattern) {
        lines.push(`Pattern: \`${truncate(searchPattern, PREVIEW_LIMIT)}\``)
      }
      if (filePath) {
        lines.push(`Path: **${filePath}**`)
      }
      break
    case "webfetch":
      if (url) {
        lines.push(url)
      }
      break
    case "task":
    case "skill":
      if (agent) {
        lines.push(truncate(agent, PREVIEW_LIMIT))
      }
      break
    default:
      if (filePath) {
        lines.push(`Path: **${filePath}**`)
      }
      if (command) {
        lines.push(codeBlock(truncate(command, PREVIEW_LIMIT)))
      }
      break
  }

  if (pattern && !lines.some((line) => line.includes(pattern))) {
    lines.push(`Suggested rule: \`${truncate(pattern, PREVIEW_LIMIT)}\``)
  }

  if (lines.length === 0) {
    lines.push(codeBlock(truncate(stringifyPreview({ type: input.type, metadata }), PREVIEW_LIMIT), "json"))
  }

  return {
    title,
    message: lines.join("\n\n"),
  }
}

function formatPattern(pattern: string | string[] | undefined): string | undefined {
  if (typeof pattern === "string") {
    return pattern
  }

  if (Array.isArray(pattern)) {
    const values = pattern.filter((value): value is string => typeof value === "string" && value.length > 0)
    if (values.length > 0) {
      return values.join(", ")
    }
  }

  return undefined
}

function asRecord(value: unknown): Record<string, unknown> {
  if (value && typeof value === "object" && !Array.isArray(value)) {
    return value as Record<string, unknown>
  }

  return {}
}

function pickFirstString(source: Record<string, unknown>, paths: string[][]): string | undefined {
  for (const path of paths) {
    const value = getPath(source, path)
    const normalized = normalizeString(value)
    if (normalized) {
      return normalized
    }
  }

  return undefined
}

function getPath(source: Record<string, unknown>, path: string[]): unknown {
  let current: unknown = source

  for (const segment of path) {
    if (!current || typeof current !== "object" || Array.isArray(current)) {
      return undefined
    }

    current = (current as Record<string, unknown>)[segment]
  }

  return current
}

function normalizeString(value: unknown): string | undefined {
  if (typeof value === "string") {
    return value.trim() || undefined
  }

  if (Array.isArray(value)) {
    const strings = value.filter((entry): entry is string => typeof entry === "string" && entry.length > 0)
    if (strings.length > 0) {
      return strings.join(" ")
    }
  }

  return undefined
}

function relativizePath(filePath: string | undefined, directory: string): string | undefined {
  if (!filePath) {
    return undefined
  }

  const prefix = `${directory}/`
  if (filePath.startsWith(prefix)) {
    return filePath.slice(prefix.length)
  }

  return filePath
}

function truncate(value: string, limit: number): string {
  if (value.length <= limit) {
    return value
  }

  return `${value.slice(0, limit)}...`
}

function codeBlock(value: string, language = ""): string {
  const fence = language ? `\`\`\`${language}` : "\`\`\`"
  return `${fence}\n${value}\n\`\`\``
}

function diffBlock(oldValue: string, newValue: string): string {
  return codeBlock(`- ${oldValue}\n+ ${newValue}`, "diff")
}

function stringifyPreview(value: unknown): string {
  try {
    return JSON.stringify(value, null, 2)
  } catch {
    return String(value)
  }
}

function formatError(error: unknown): string {
  if (error instanceof Error) {
    return error.stack || error.message
  }

  return stringifyPreview(error)
}

function debugLog(config: Pick<SharedConfig, "debug"> | null, message: string, details?: Record<string, unknown>): void {
  if (!config?.debug) {
    return
  }

  if (!details) {
    void appendProbe(message)
    return
  }

  void appendProbe(message, details)
}

async function appendProbe(message: string, details?: Record<string, unknown>): Promise<void> {
  const line = `${new Date().toISOString()} ${message}${details ? ` ${stringifyPreview(details)}` : ""}\n`
  await appendFile(PROBE_FILE, line).catch(() => undefined)
}

async function publishNotification(
  config: SharedConfig,
  requestId: string,
  notification: Notification,
  directory: string,
): Promise<boolean> {
  const response = await fetch(`${config.server}/`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...authHeaders(config),
    },
    body: JSON.stringify({
      topic: config.topic,
      sequence_id: requestId,
      title: `[${directory}] ${notification.title}`,
      message: notification.message,
      markdown: true,
      priority: 4,
      tags: ["lock"],
      actions: buildActions(config, requestId),
    }),
  }).catch((error) => {
    debugLog(config, "publish request failed", {
      requestId,
      error: formatError(error),
    })
    return null
  })

  if (!response?.ok) {
    const body = response ? await response.text().catch(() => "") : ""
    debugLog(config, "publish rejected", {
      requestId,
      status: response?.status ?? null,
      body: truncate(body, PREVIEW_LIMIT),
    })
    return false
  }

  const body = await response.json().catch((error) => {
    debugLog(config, "publish response parse failed", {
      requestId,
      error: formatError(error),
    })
    return null
  })
  if (!body || body.event !== "message") {
    debugLog(config, "publish response unexpected", {
      requestId,
      body,
    })
    return false
  }

  return true
}

function buildActions(config: SharedConfig, requestId: string): unknown[] {
  const headers = config.token ? { Authorization: `Bearer ${config.token}` } : undefined
  const baseAction = {
    action: "http",
    url: `${config.server}/${config.responseTopic}`,
    method: "POST",
    clear: true,
  }

  return [
    {
      ...baseAction,
      label: "Allow",
      body: `allow|${requestId}`,
      ...(headers ? { headers } : {}),
    },
    {
      ...baseAction,
      label: "Deny",
      body: `deny|${requestId}`,
      ...(headers ? { headers } : {}),
    },
  ]
}

function authHeaders(config: SharedConfig): Record<string, string> {
  if (!config.token) {
    return {}
  }

  return {
    Authorization: `Bearer ${config.token}`,
  }
}

async function replyToPermission(
  client: {
    permission?: {
      respond: (parameters: { sessionID: string; permissionID: string; directory?: string; response?: "once" | "always" | "reject" }) => Promise<{ error?: unknown; response: Response }>
    }
    postSessionIdPermissionsPermissionId?: (options: {
      path: { id: string; permissionID: string }
      body: { response: "once" | "always" | "reject" }
      headers?: Record<string, string>
    }) => Promise<{ data?: unknown; error?: unknown; request: Request; response: Response }>
  },
  config: SharedConfig,
  sessionID: string,
  requestId: string,
  directory: string,
  reply: "once" | "reject",
): Promise<{ error?: unknown; response: Response }> {
  if (client.permission?.respond) {
    return client.permission.respond({
      sessionID,
      permissionID: requestId,
      directory,
      response: reply,
    }).catch((error) => {
      debugLog(config, "permission reply request failed", {
        requestId,
        sessionID,
        method: "client.permission.respond",
        error: formatError(error),
      })
      return {
        error,
        response: new Response(null, { status: 599, statusText: "plugin reply failed" }),
      }
    })
  }

  if (client.postSessionIdPermissionsPermissionId) {
    return client.postSessionIdPermissionsPermissionId({
      path: {
        id: sessionID,
        permissionID: requestId,
      },
      body: {
        response: reply,
      },
      headers: {
        "x-opencode-directory": encodeURIComponent(directory),
      },
    }).then((result) => ({
      error: result.error,
      response: result.response,
    })).catch((error) => {
      debugLog(config, "permission reply request failed", {
        requestId,
        sessionID,
        method: "client.postSessionIdPermissionsPermissionId",
        error: formatError(error),
      })
      return {
        error,
        response: new Response(null, { status: 599, statusText: "plugin reply failed" }),
      }
    })
  }

  debugLog(config, "permission reply client missing", {
    requestId,
    sessionID,
    clientKeys: client && typeof client === "object" ? Object.keys(client as Record<string, unknown>) : undefined,
  })

  return {
    error: new Error("No supported permission reply API on plugin client"),
    response: new Response(null, { status: 598, statusText: "missing permission client API" }),
  }

}

async function waitForDecision(config: SharedConfig, requestId: string): Promise<"allow" | "deny" | undefined> {
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), config.timeoutSeconds * 1000)
  const since = Math.floor(Date.now() / 1000) - 1

  debugLog(config, "waiting for decision", {
    requestId,
    responseTopic: config.responseTopic,
    timeoutSeconds: config.timeoutSeconds,
  })

  try {
    const response = await fetch(`${config.server}/${config.responseTopic}/sse?since=${since}`, {
      method: "GET",
      headers: {
        Accept: "text/event-stream",
        ...authHeaders(config),
      },
      signal: controller.signal,
    }).catch((error) => {
      if (isAbortError(error)) {
        debugLog(config, "decision wait aborted", { requestId })
        return null
      }

      debugLog(config, "decision stream failed", {
        requestId,
        error: formatError(error),
      })
      throw error
    })

    if (!response?.ok || !response.body) {
      debugLog(config, "decision stream unavailable", {
        requestId,
        status: response?.status ?? null,
      })
      return undefined
    }

    const reader = response.body.getReader()
    const decoder = new TextDecoder()
    let buffer = ""

    while (true) {
      const { done, value } = await reader.read().catch((error) => {
        if (isAbortError(error)) {
          return { done: true, value: undefined }
        }

        throw error
      })

      if (done) {
        break
      }

      buffer += decoder.decode(value, { stream: true })
      const lines = buffer.split(/\n/u)
      buffer = lines.pop() ?? ""

      for (const rawLine of lines) {
        const line = rawLine.replace(/\r$/u, "")
        if (!line.startsWith("data:")) {
          continue
        }

        const payload = line.slice(5).trimStart()
        const message = parseSseMessage(payload)
        if (message === `allow|${requestId}`) {
          await reader.cancel().catch(() => undefined)
          return "allow"
        }
        if (message === `deny|${requestId}`) {
          await reader.cancel().catch(() => undefined)
          return "deny"
        }
      }
    }
  } finally {
    clearTimeout(timeout)
  }

  return undefined
}

function parseSseMessage(payload: string): string | undefined {
  try {
    const parsed = JSON.parse(payload) as { event?: string; message?: string }
    if (parsed.event === "message" && typeof parsed.message === "string") {
      return parsed.message
    }
  } catch {
    return undefined
  }

  return undefined
}

function isAbortError(error: unknown): boolean {
  return error instanceof Error && error.name === "AbortError"
}

async function deleteNotification(config: SharedConfig, requestId: string): Promise<void> {
  await fetch(`${config.server}/${config.topic}/${requestId}`, {
    method: "DELETE",
    headers: authHeaders(config),
  }).catch(() => undefined)
}
