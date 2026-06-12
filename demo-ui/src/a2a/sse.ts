// Parse a fetch() Response body (text/event-stream) into SSE events.
// A2A streams POST responses, so EventSource (GET-only) can't be used — we read
// the ReadableStream and split on the SSE frame boundary (blank line).

export interface SseEvent {
  event?: string
  data: string
  id?: string
}

export async function* readSse(
  body: ReadableStream<Uint8Array>,
  signal?: AbortSignal,
): AsyncGenerator<SseEvent> {
  const reader = body.getReader()
  const decoder = new TextDecoder()
  let buffer = ''

  const onAbort = () => reader.cancel().catch(() => {})
  signal?.addEventListener('abort', onAbort)

  try {
    while (true) {
      const { done, value } = await reader.read()
      if (done) break
      buffer += decoder.decode(value, { stream: true })

      let idx: number
      // SSE frames are separated by a blank line (\n\n). Handle \r\n too.
      while ((idx = indexOfFrameBoundary(buffer)) !== -1) {
        const rawFrame = buffer.slice(0, idx)
        buffer = buffer.slice(idx).replace(/^(\r?\n){1,2}/, '')
        const evt = parseFrame(rawFrame)
        if (evt) yield evt
      }
    }
    // flush any trailing frame
    const tail = parseFrame(buffer)
    if (tail) yield tail
  } finally {
    signal?.removeEventListener('abort', onAbort)
    reader.releaseLock()
  }
}

function indexOfFrameBoundary(s: string): number {
  const a = s.indexOf('\n\n')
  const b = s.indexOf('\r\n\r\n')
  if (a === -1) return b
  if (b === -1) return a
  return Math.min(a, b)
}

function parseFrame(frame: string): SseEvent | null {
  if (!frame.trim()) return null
  const out: SseEvent = { data: '' }
  const dataLines: string[] = []
  for (const line of frame.split(/\r?\n/)) {
    if (!line || line.startsWith(':')) continue // comment / keep-alive
    const colon = line.indexOf(':')
    const field = colon === -1 ? line : line.slice(0, colon)
    let val = colon === -1 ? '' : line.slice(colon + 1)
    if (val.startsWith(' ')) val = val.slice(1)
    if (field === 'data') dataLines.push(val)
    else if (field === 'event') out.event = val
    else if (field === 'id') out.id = val
  }
  if (!dataLines.length) return null
  out.data = dataLines.join('\n')
  return out
}
