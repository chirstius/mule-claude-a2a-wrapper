import { reactive } from 'vue'
import { A2AClient, uuid, type RpcMethod } from '../a2a/client'
import type { A2AEvent, Artifact, Task, TaskState, ToolCall, ToolDecision } from '../a2a/types'

export type Mode = 'stream' | 'blocking'

export interface TimelineEntry {
  id: string
  ts: number
  kind:
    | 'state'
    | 'tool'
    | 'tool-result'
    | 'thinking'
    | 'working'
    | 'artifact'
    | 'data'
    | 'info'
    | 'error'
    | 'policy-allow'
    | 'policy-deny'
  label: string
  detail?: string
  /** Human wait time (ms) attached to a "resume after approval" entry — not counted in active time. */
  waitMs?: number
}

export interface Usage {
  input_tokens: number
  output_tokens: number
  cache_creation_input_tokens: number
  cache_read_input_tokens: number
  model_requests: number
}

/** One A2A HTTP round-trip: the raw JSON-RPC request + the raw response frame(s). */
export interface A2AExchange {
  id: string
  label: string
  request: any
  messages: any[]
}

export interface AssistantTurn {
  id: string
  role: 'agent'
  mode: Mode
  taskId?: string
  contextId?: string
  state: TaskState
  answer: string
  files: Artifact[]
  approvals: ToolCall[]
  timeline: TimelineEntry[]
  usage?: Usage
  exchanges: A2AExchange[]
  final: boolean // the whole (possibly multi-approval) exchange is done
  error?: string
  startedAt: number
  endedAt?: number
  activeMs: number // accumulated agent-processing time (excludes approval waits)
  segStart?: number // start of the currently-running segment (undefined while paused/done)
  pausedAt?: number // when the current input-required pause began
}

export interface UserTurn {
  id: string
  role: 'user'
  text: string
  note?: string
  request?: any // raw A2A JSON-RPC request that this message produced
}

export type Turn = UserTurn | AssistantTurn

export interface PushDelivery {
  id: string
  ts: number
  summary: string
}

const store = reactive({
  endpoint: defaultEndpoint() as string, // full A2A URL (host + path); editable in the header
  mode: 'stream' as Mode,
  contextId: undefined as string | undefined,
  turns: [] as Turn[],
  busy: false,
  abort: null as AbortController | null,
  error: '' as string,
  pushEnabled: false,
  pushDeliveries: [] as PushDelivery[],
})

// Default endpoint = browser origin + path (path baked at embed time from config; falls back to /a2a).
function defaultEndpoint(): string {
  const raw = (import.meta.env.VITE_A2A_PATH || '/a2a').trim()
  // Guard against a build-time-mangled value: Git-Bash/MSYS rewrites a "/a2a"
  // env value into a Windows path like "C:/Program Files/Git/a2a". A real A2A
  // path has no drive letter, colon, or space — fall back to /a2a if it does.
  const path = /^\/[A-Za-z0-9\-._~/]*$/.test(raw) ? raw : '/a2a'
  const origin = typeof window !== 'undefined' ? window.location.origin : ''
  return origin + (path.startsWith('/') ? path : '/' + path)
}

function client() {
  return new A2AClient(store.endpoint)
}
function method(): RpcMethod {
  return store.mode === 'stream' ? 'message/stream' : 'message/send'
}

function te(kind: TimelineEntry['kind'], label: string, detail?: string): TimelineEntry {
  return { id: uuid(), ts: Date.now(), kind, label, detail }
}

function isAnswer(a: Artifact) {
  return a.name === 'Answer' || a.artifactId?.startsWith('answer-')
}
function artifactText(a: Artifact): string {
  return (a.parts || [])
    .filter((p: any) => (p.kind ?? p.type) === 'text')
    .map((p: any) => p.text ?? '')
    .join('\n')
}
function messageText(msg: any): string {
  return (msg?.parts || [])
    .filter((p: any) => (p.kind ?? p.type) === 'text')
    .map((p: any) => p.text ?? '')
    .join('\n')
}
function confirmationRequest(msg: any): ToolCall[] | null {
  const dp = (msg?.parts || []).find(
    (p: any) => p.kind === 'data' && p.data?.type === 'tool-confirmation-request',
  )
  return dp ? (dp.data.calls as ToolCall[]) : null
}
function runSummary(msg: any): { usage?: Usage } | null {
  const dp = (msg?.parts || []).find((p: any) => p.kind === 'data' && p.data?.type === 'run-summary')
  return dp ? (dp.data as { usage?: Usage }) : null
}
function workingKind(txt: string): TimelineEntry['kind'] {
  if (/^thinking/i.test(txt)) return 'thinking'
  if (/^tool result/i.test(txt)) return 'tool-result'
  if (/auto-approved/i.test(txt)) return 'policy-allow'
  if (/auto-denied/i.test(txt)) return 'policy-deny'
  if (/using tool/i.test(txt)) return 'tool'
  return 'working'
}

function applyArtifact(turn: AssistantTurn, a: Artifact) {
  if (isAnswer(a)) {
    turn.answer = artifactText(a)
    turn.timeline.push(te('artifact', 'Answer artifact', `${artifactText(a).length} chars`))
  } else {
    const i = turn.files.findIndex((f) => f.artifactId === a.artifactId)
    if (i >= 0) turn.files[i] = a
    else turn.files.push(a)
    turn.timeline.push(te('artifact', `File artifact: ${a.name ?? a.artifactId}`))
  }
}

function applyStatus(turn: AssistantTurn, status: any) {
  if (status?.state && status.state !== turn.state) {
    turn.state = status.state
    turn.timeline.push(te('state', `state → ${status.state}`, status.timestamp))
  }
  const msg = status?.message
  if (msg) {
    const rs = runSummary(msg)
    if (rs?.usage) turn.usage = rs.usage
    const calls = confirmationRequest(msg)
    if (calls && calls.length) {
      turn.approvals = calls
      turn.timeline.push(te('data', 'tool-confirmation-request', calls.map((c) => c.name).join(', ')))
    }
    const txt = messageText(msg)
    if (txt) {
      if (status.state === 'working') {
        turn.timeline.push(te(workingKind(txt), txt))
      } else if (status.state === 'input-required') {
        turn.timeline.push(te('data', txt))
      } else if (status.state === 'failed') {
        turn.error = txt
        turn.timeline.push(te('error', txt))
      }
    }
  }
}

function applyTask(turn: AssistantTurn, task: Task) {
  turn.taskId = task.id
  turn.contextId = task.contextId
  store.contextId = task.contextId
  if (task.status) applyStatus(turn, task.status)
  for (const a of task.artifacts ?? []) applyArtifact(turn, a)
}

function applyEvent(turn: AssistantTurn, ev: A2AEvent) {
  const kind = (ev as any).kind
  if (kind === 'task') {
    applyTask(turn, ev as Task)
  } else if (kind === 'status-update') {
    const e = ev as any
    turn.taskId ||= e.taskId
    if (e.contextId) {
      turn.contextId = e.contextId
      store.contextId = e.contextId
    }
    applyStatus(turn, e.status)
    // NOTE: do NOT set turn.final on e.final — an input-required stream also ends with final:true
    // but the turn is only PAUSED. runSegment() decides done-vs-paused from the resulting state.
  } else if (kind === 'artifact-update') {
    const e = ev as any
    if (e.artifact) applyArtifact(turn, e.artifact)
  }
}

function newAssistantTurn(): AssistantTurn {
  const t: AssistantTurn = {
    id: uuid(),
    role: 'agent',
    mode: store.mode,
    state: 'submitted',
    answer: '',
    files: [],
    approvals: [],
    timeline: [],
    exchanges: [],
    final: false,
    startedAt: Date.now(),
    activeMs: 0,
  }
  store.turns.push(t)
  // return the REACTIVE proxy so per-event mutations during the run are tracked
  return store.turns[store.turns.length - 1] as AssistantTurn
}

/** Run one A2A round-trip into `turn` (appending). May leave the turn PAUSED on input-required. */
async function runSegment(turn: AssistantTurn, request: any, label: string) {
  store.busy = true
  store.error = ''
  store.abort = new AbortController()
  const signal = store.abort.signal
  const c = client()
  const exchange: A2AExchange = { id: uuid(), label, request, messages: [] }
  turn.exchanges.push(exchange)
  const onRaw = (raw: any) => exchange.messages.push(raw)
  turn.segStart = Date.now()
  turn.pausedAt = undefined
  turn.timeline.push(te('info', label))
  try {
    if (request.method === 'message/stream') {
      for await (const ev of c.streamRequest(request, signal, onRaw)) applyEvent(turn, ev)
    } else {
      const task = await c.sendRequest(request, signal, onRaw)
      applyTask(turn, task)
    }
  } catch (err: any) {
    if (signal.aborted) {
      turn.timeline.push(te('info', 'aborted by client'))
    } else {
      turn.error = String(err?.message ?? err)
      turn.state = 'failed'
      turn.timeline.push(te('error', turn.error))
      store.error = turn.error
    }
  } finally {
    turn.activeMs += Date.now() - (turn.segStart ?? Date.now())
    turn.segStart = undefined
    store.busy = false
    store.abort = null
    if (turn.state === 'input-required' && turn.approvals.length) {
      turn.pausedAt = Date.now() // paused awaiting human approval — NOT final
    } else {
      turn.final = true
      turn.endedAt = Date.now()
    }
  }
}

// ---- public actions ----
async function sendText(text: string) {
  if (!text.trim() || store.busy) return
  const request = client().buildRequest(method(), { text, contextId: store.contextId })
  store.turns.push({ id: uuid(), role: 'user', text, request })
  const turn = newAssistantTurn()
  await runSegment(turn, request, method())
}

/** Answer a pending approval IN PLACE — the same agent turn continues (coalesced). */
async function respondToApprovals(turn: AssistantTurn, decisions: ToolDecision[]) {
  if (store.busy) return
  const calls = turn.approvals
  const waitMs = turn.pausedAt ? Date.now() - turn.pausedAt : undefined
  for (const d of decisions) {
    const name = calls.find((c) => c.toolUseId === d.toolUseId)?.name ?? d.toolUseId.slice(0, 8)
    turn.timeline.push(
      te(d.result === 'allow' ? 'tool-result' : 'error', `${d.result === 'allow' ? '✓ approved' : '✕ denied'}: ${name}`),
    )
  }
  turn.approvals = []
  turn.timeline.push({ ...te('info', 'resume after approval'), waitMs })
  const request = client().buildRequest(method(), {
    contextId: store.contextId,
    dataParts: [A2AClient.confirmationResponse(decisions)],
  })
  await runSegment(turn, request, `${method()} (resume)`)
}

async function cancel() {
  const t = [...store.turns].reverse().find((x): x is AssistantTurn => x.role === 'agent' && !!x.taskId)
  store.abort?.abort()
  if (t?.taskId) {
    try {
      await client().cancel(t.taskId)
      t.timeline.push(te('info', 'tasks/cancel sent'))
      if (!t.final) {
        t.state = 'canceled'
        t.final = true
        t.endedAt = Date.now()
      }
    } catch (err: any) {
      store.error = `cancel failed: ${err?.message ?? err}`
    }
  }
}

function reset() {
  store.turns = []
  store.contextId = undefined
  store.error = ''
  store.pushDeliveries = []
}

export function useA2A() {
  return { store, sendText, respondToApprovals, cancel, reset }
}
