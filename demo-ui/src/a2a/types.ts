// Minimal A2A (Agent-to-Agent) protocol types used by the demo UI.
// Mirrors the shapes the Claude wrapper emits (see docs/USAGE.md).

export type TaskState =
  | 'submitted'
  | 'working'
  | 'input-required'
  | 'completed'
  | 'failed'
  | 'canceled'
  | 'unknown'

export interface TextPart {
  kind: 'text'
  text: string
}
export interface DataPart {
  kind: 'data'
  data: Record<string, any>
}
export type Part = TextPart | DataPart | { kind: string; [k: string]: any }

export interface A2AMessage {
  role: 'user' | 'agent'
  kind: 'message'
  messageId: string
  contextId?: string
  taskId?: string
  parts: Part[]
}

export interface TaskStatus {
  state: TaskState
  message?: A2AMessage
  timestamp?: string
}

export interface Artifact {
  artifactId: string
  name?: string
  parts: Part[]
}

export interface Task {
  kind: 'task'
  id: string
  contextId: string
  status: TaskStatus
  artifacts?: Artifact[]
  history?: A2AMessage[]
}

// Streaming events (JSON-RPC result payloads)
export interface StatusUpdateEvent {
  kind: 'status-update'
  taskId: string
  contextId: string
  status: TaskStatus
  final?: boolean
}
export interface ArtifactUpdateEvent {
  kind: 'artifact-update'
  taskId: string
  contextId: string
  artifact: Artifact
  append?: boolean
  lastChunk?: boolean
}
export type A2AEvent = Task | StatusUpdateEvent | ArtifactUpdateEvent | { kind: string; [k: string]: any }

// ---- Tool-confirmation (HITL) DataPart conventions ----
export interface ToolCall {
  toolUseId: string
  name: string
  toolType?: string
  key?: string
  input?: Record<string, any>
}
export interface ToolConfirmationRequest {
  type: 'tool-confirmation-request'
  taskId?: string
  calls: ToolCall[]
}
export interface ToolDecision {
  toolUseId: string
  result: 'allow' | 'deny'
  denyMessage?: string
}
export interface ToolConfirmationResponse {
  type: 'tool-confirmation-response'
  decisions: ToolDecision[]
}

export interface JsonRpcResponse<T = any> {
  jsonrpc: '2.0'
  id: string | number
  result?: T
  error?: { code: number; message: string; data?: any }
}

// ---- A2A AgentCard (loose: cards vary, render defensively) ----
export interface AgentSkill {
  id: string
  name?: string
  description?: string
  tags?: string[]
  examples?: string[]
  inputModes?: string[]
  outputModes?: string[]
  [k: string]: any
}
export interface AgentExtension {
  uri: string
  description?: string
  required?: boolean
  params?: any
}
export interface AgentCapabilities {
  streaming?: boolean
  pushNotifications?: boolean
  stateTransitionHistory?: boolean
  extensions?: AgentExtension[]
  [k: string]: any
}
export interface AgentInterface {
  url: string
  transport: string
}
export interface AgentCard {
  protocolVersion?: string
  name?: string
  description?: string
  url?: string
  preferredTransport?: string
  additionalInterfaces?: AgentInterface[]
  iconUrl?: string
  version?: string
  documentationUrl?: string
  provider?: { organization?: string; url?: string }
  capabilities?: AgentCapabilities
  securitySchemes?: Record<string, any>
  security?: Array<Record<string, string[]>>
  defaultInputModes?: string[]
  defaultOutputModes?: string[]
  skills?: AgentSkill[]
  supportsAuthenticatedExtendedCard?: boolean
  [k: string]: any
}
