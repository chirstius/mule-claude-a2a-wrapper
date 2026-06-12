import { readSse } from './sse'
import type {
  A2AEvent,
  AgentCard,
  JsonRpcResponse,
  Part,
  Task,
  ToolConfirmationResponse,
  ToolDecision,
} from './types'

function uuid(): string {
  if (typeof crypto !== 'undefined' && 'randomUUID' in crypto) return crypto.randomUUID()
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0
    return (c === 'x' ? r : (r & 0x3) | 0x8).toString(16)
  })
}

export interface SendOptions {
  contextId?: string
  /** Extra data parts to include alongside the text (e.g. a tool-confirmation-response). */
  dataParts?: Array<Record<string, any>>
  /** Sent only if non-empty text is provided. */
  text?: string
}

export type RpcMethod = 'message/send' | 'message/stream'

function buildMessage(opts: SendOptions) {
  const parts: Part[] = []
  if (opts.text && opts.text.trim()) parts.push({ kind: 'text', text: opts.text })
  for (const d of opts.dataParts ?? []) parts.push({ kind: 'data', data: d })
  const message: Record<string, any> = {
    role: 'user',
    kind: 'message',
    messageId: uuid(),
    parts,
  }
  if (opts.contextId) message.contextId = opts.contextId
  return message
}

export class A2AClient {
  /** Full A2A JSON-RPC endpoint URL (host + path), e.g. http://host:8081/a2a */
  constructor(public endpoint: string) {}

  /** Build a JSON-RPC request object (so the caller can capture/display the raw request). */
  buildRequest(method: RpcMethod, opts: SendOptions) {
    return { jsonrpc: '2.0', id: uuid(), method, params: { message: buildMessage(opts) } }
  }

  /** Blocking send of a prebuilt request. onRaw receives the raw JSON-RPC response. */
  async sendRequest(request: any, signal?: AbortSignal, onRaw?: (raw: any) => void): Promise<Task> {
    const res = await fetch(this.endpoint, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(request),
      signal,
    })
    const json = (await res.json()) as JsonRpcResponse<Task>
    onRaw?.(json)
    if (json.error) throw new Error(`${json.error.code}: ${json.error.message}`)
    return json.result as Task
  }

  /** Streaming send of a prebuilt request. Yields events; onRaw receives each raw JSON-RPC frame. */
  async *streamRequest(
    request: any,
    signal?: AbortSignal,
    onRaw?: (raw: any) => void,
  ): AsyncGenerator<A2AEvent> {
    const res = await fetch(this.endpoint, {
      method: 'POST',
      headers: { 'content-type': 'application/json', accept: 'text/event-stream' },
      body: JSON.stringify(request),
      signal,
    })
    if (!res.ok || !res.body) {
      const txt = await res.text().catch(() => '')
      throw new Error(`stream HTTP ${res.status}${txt ? ': ' + txt : ''}`)
    }
    for await (const frame of readSse(res.body, signal)) {
      let parsed: JsonRpcResponse<A2AEvent>
      try {
        parsed = JSON.parse(frame.data)
      } catch {
        continue
      }
      onRaw?.(parsed)
      if (parsed.error) throw new Error(`${parsed.error.code}: ${parsed.error.message}`)
      if (parsed.result) yield parsed.result
    }
  }

  /** tasks/cancel — marks the task canceled and interrupts the underlying session. */
  async cancel(taskId: string): Promise<any> {
    const res = await fetch(this.endpoint, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: uuid(), method: 'tasks/cancel', params: { id: taskId } }),
    })
    const json = (await res.json()) as JsonRpcResponse
    if (json.error) throw new Error(`${json.error.code}: ${json.error.message}`)
    return json.result
  }

  /**
   * Fetch the A2A AgentCard for this endpoint. Tries the well-known paths relative to the
   * endpoint (e.g. {endpoint}/.well-known/agent-card.json — how this wrapper and the broker
   * serve it), then the origin root, then the older agent.json name.
   */
  async fetchAgentCard(): Promise<{ card: AgentCard; sourceUrl: string }> {
    const base = this.endpoint.replace(/\/+$/, '')
    let origin = ''
    try {
      origin = new URL(this.endpoint, typeof window !== 'undefined' ? window.location.href : undefined).origin
    } catch {
      /* relative/invalid endpoint */
    }
    const candidates = [
      `${base}/.well-known/agent-card.json`,
      ...(origin && origin !== base ? [`${origin}/.well-known/agent-card.json`] : []),
      `${base}/.well-known/agent.json`,
    ]
    let lastErr = 'no candidates'
    for (const url of candidates) {
      try {
        const res = await fetch(url, { headers: { accept: 'application/json' } })
        if (!res.ok) {
          lastErr = `HTTP ${res.status} at ${url}`
          continue
        }
        const card = (await res.json()) as AgentCard
        if (card && typeof card === 'object' && (card.name || card.protocolVersion || card.skills || card.url)) {
          return { card, sourceUrl: url }
        }
        lastErr = `unrecognized JSON at ${url}`
      } catch (e: any) {
        lastErr = `${e?.message ?? e} (${url})`
      }
    }
    throw new Error(`No agent card found. Last attempt: ${lastErr}`)
  }

  /** Build the tool-confirmation-response data part for a HITL reply. */
  static confirmationResponse(decisions: ToolDecision[]): ToolConfirmationResponse {
    return { type: 'tool-confirmation-response', decisions }
  }
}

export { uuid }
