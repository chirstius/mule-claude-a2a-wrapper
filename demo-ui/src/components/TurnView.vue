<script setup lang="ts">
import type { Turn, AssistantTurn } from '../composables/useA2A'
import type { Artifact, ToolDecision } from '../a2a/types'
import StatusPill from './StatusPill.vue'
import ApprovalCard from './ApprovalCard.vue'
import EventPanel from './EventPanel.vue'

defineProps<{ turn: Turn; busy: boolean }>()
const emit = defineEmits<{ (e: 'approve', decisions: ToolDecision[]): void }>()

const isAgent = (t: Turn): t is AssistantTurn => t.role === 'agent'

function fmt(s: string): string {
  const esc = s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
  return esc
    .replace(/`([^`]+)`/g, '<code>$1</code>')
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
}
function artifactText(a: Artifact): string {
  return (a.parts || [])
    .filter((p: any) => (p.kind ?? p.type) === 'text')
    .map((p: any) => p.text ?? '')
    .join('\n')
}
function download(a: Artifact) {
  const blob = new Blob([artifactText(a)], { type: 'text/plain' })
  const url = URL.createObjectURL(blob)
  const link = document.createElement('a')
  link.href = url
  link.download = a.name || a.artifactId || 'artifact.txt'
  link.click()
  URL.revokeObjectURL(url)
}
function pretty(v: any): string {
  try {
    return JSON.stringify(v, null, 2)
  } catch {
    return String(v)
  }
}
function frameCount(t: AssistantTurn): number {
  return t.exchanges.reduce((n, e) => n + e.messages.length, 0)
}
</script>

<template>
  <!-- user turn -->
  <div v-if="!isAgent(turn)" class="turn user">
    <div class="avatar user">U</div>
    <div class="bubble">
      <div v-if="turn.text" class="answer">{{ turn.text }}</div>
      <div v-if="turn.note" class="note">▸ {{ turn.note }}</div>
      <details v-if="turn.request" class="a2a">
        <summary>⟨⟩ A2A request</summary>
        <pre>{{ pretty(turn.request) }}</pre>
      </details>
    </div>
  </div>

  <!-- agent turn -->
  <div v-else class="turn agent">
    <div class="avatar agent">A</div>
    <div class="bubble" style="flex:1">
      <div class="row" style="margin-bottom:2px">
        <StatusPill :state="turn.state" />
        <span class="chip">{{ turn.mode }}</span>
        <span v-if="turn.taskId" class="muted" :title="turn.taskId">task {{ turn.taskId.slice(0, 8) }}</span>
      </div>

      <!-- live event panel: collapsed current activity -> expand for timeline + summary -->
      <EventPanel :turn="turn" />

      <!-- answer -->
      <div v-if="turn.answer" class="answer" style="margin-top:10px" v-html="fmt(turn.answer)" />

      <!-- error -->
      <div v-if="turn.error" class="banner" style="margin:8px 0 0">⚠ {{ turn.error }}</div>

      <!-- file artifacts -->
      <div v-for="f in turn.files" :key="f.artifactId" class="file">
        <div class="fhead">
          <span>📄 {{ f.name || f.artifactId }}</span>
          <span class="grow" />
          <button class="btn-mini" @click="download(f)">download</button>
        </div>
        <pre>{{ artifactText(f) }}</pre>
      </div>

      <!-- HITL approval (inline; answering it continues THIS same turn) -->
      <ApprovalCard
        v-if="turn.approvals.length"
        :calls="turn.approvals"
        :busy="busy"
        @decide="(d) => emit('approve', d)"
      />

      <!-- raw A2A messages for the whole exchange -->
      <details v-if="turn.exchanges.length" class="a2a">
        <summary>⟨⟩ A2A messages — {{ turn.exchanges.length }} exchange{{ turn.exchanges.length > 1 ? 's' : '' }}, {{ frameCount(turn) }} frame(s)</summary>
        <div v-for="ex in turn.exchanges" :key="ex.id" class="a2a-ex">
          <div class="a2a-lbl">▸ {{ ex.label }} — request</div>
          <pre>{{ pretty(ex.request) }}</pre>
          <div class="a2a-lbl">◂ response ({{ ex.messages.length }} frame{{ ex.messages.length === 1 ? '' : 's' }})</div>
          <pre>{{ pretty(ex.messages) }}</pre>
        </div>
      </details>
    </div>
  </div>
</template>
