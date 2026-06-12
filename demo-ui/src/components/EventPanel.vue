<script setup lang="ts">
import { computed, onBeforeUnmount, ref, watch } from 'vue'
import type { AssistantTurn, TimelineEntry } from '../composables/useA2A'

const props = defineProps<{ turn: AssistantTurn }>()
const expanded = ref(false)

// activity kind -> { icon, vuetify color }
const ACT: Record<TimelineEntry['kind'], { icon: string; color: string }> = {
  state: { icon: '◆', color: 'secondary' },
  thinking: { icon: '💭', color: 'primary' },
  tool: { icon: '🔧', color: 'info' },
  'tool-result': { icon: '✓', color: 'success' },
  working: { icon: '•', color: 'blue-grey' },
  artifact: { icon: '📄', color: 'warning' },
  data: { icon: '⚖', color: 'purple' },
  info: { icon: 'ℹ', color: 'blue-grey-lighten-1' },
  error: { icon: '⚠', color: 'error' },
  'policy-allow': { icon: '🛡', color: 'success' },
  'policy-deny': { icon: '🛡', color: 'error' },
}
function meta(kind: TimelineEntry['kind']) {
  return ACT[kind] ?? ACT.info
}

// the "current" (latest) activity drives the collapsed line
const cur = computed(() => {
  const e = props.turn.timeline[props.turn.timeline.length - 1]
  if (!e) return { icon: '•', color: 'blue-grey', label: 'starting…' }
  return { ...meta(e.kind), label: e.label }
})

// live-ticking clock so elapsed counts up during quiet gaps
const now = ref(Date.now())
let timer: number | undefined
watch(
  () => props.turn.final,
  (final) => {
    if (final) { if (timer) { clearInterval(timer); timer = undefined } }
    else if (!timer) { timer = window.setInterval(() => (now.value = Date.now()), 250) }
  },
  { immediate: true },
)
onBeforeUnmount(() => timer && clearInterval(timer))

// Active processing time only (excludes time paused awaiting human approval).
const elapsed = computed(() => {
  const ms = props.turn.activeMs + (props.turn.segStart ? now.value - props.turn.segStart : 0)
  return ms < 1000 ? `${Math.round(ms)}ms` : `${(ms / 1000).toFixed(1)}s`
})
const toolCount = computed(() => props.turn.timeline.filter((e) => e.kind === 'tool').length)
const totalTokens = computed(() => {
  const u = props.turn.usage
  return u ? u.input_tokens + u.output_tokens : 0
})

function tt(ts: number): string {
  const d = new Date(ts)
  return d.toLocaleTimeString([], { hour12: false }) + '.' + String(d.getMilliseconds()).padStart(3, '0')
}
</script>

<template>
  <div class="event-panel">
    <!-- COLLAPSED: clickable live current-activity line -->
    <button class="ep-head" type="button" @click="expanded = !expanded" :aria-expanded="expanded">
      <v-progress-circular
        v-if="!turn.final"
        indeterminate :size="15" :width="2" :color="cur.color" class="mr-1"
      />
      <span v-else class="done mr-1">✓</span>
      <v-chip :color="cur.color" variant="tonal" size="small" label>
        <span class="mr-1">{{ cur.icon }}</span>{{ cur.label }}
      </v-chip>
      <span class="elapsed">{{ elapsed }}</span>
      <span class="chev" :class="{ open: expanded }">▸</span>
    </button>

    <!-- EXPANDED: summary + full timeline (no height transition -> no overflow) -->
    <div v-show="expanded" class="ep-body">
      <div class="summary">
        <v-chip size="small" variant="tonal" color="secondary">⏱ Total response time:&nbsp;<strong>{{ elapsed }}</strong></v-chip>
        <v-chip size="small" variant="tonal">{{ turn.timeline.length }} events</v-chip>
        <v-chip v-if="toolCount" size="small" variant="tonal" color="info">🔧 {{ toolCount }} {{ toolCount === 1 ? 'tool' : 'tools' }} used</v-chip>
        <v-chip v-if="turn.usage" size="small" variant="tonal" color="primary">
          ▦ {{ totalTokens.toLocaleString() }} tok
          <span class="tok-detail">· in {{ turn.usage.input_tokens }} / out {{ turn.usage.output_tokens }} · cache r{{ turn.usage.cache_read_input_tokens }}/w{{ turn.usage.cache_creation_input_tokens }} · {{ turn.usage.model_requests }} req</span>
        </v-chip>
      </div>

      <v-timeline density="compact" side="end" truncate-line="both" class="tl">
        <v-timeline-item
          v-for="e in turn.timeline"
          :key="e.id"
          :dot-color="meta(e.kind).color"
          size="x-small"
        >
          <div class="tl-row">
            <span class="tl-time">{{ tt(e.ts) }}</span>
            <span class="tl-label">{{ e.label }}<span v-if="e.detail" class="tl-detail"> · {{ e.detail }}</span><span v-if="e.waitMs != null" class="tl-wait"> · ⏳ waited {{ (e.waitMs / 1000).toFixed(1) }}s for approval</span></span>
          </div>
        </v-timeline-item>
      </v-timeline>
    </div>
  </div>
</template>

<style scoped>
.event-panel { margin-top: 8px; border: 1px solid var(--border); border-radius: var(--radius); background: var(--bg-3); overflow: hidden; }
.ep-head {
  display: flex; align-items: center; gap: 8px; width: 100%;
  background: transparent; border: 0; cursor: pointer; color: var(--text);
  padding: 7px 12px; text-align: left; font-size: 13px;
}
.ep-head:hover { background: rgba(255,255,255,.03); }
.ep-head .elapsed { margin-left: auto; color: var(--text-faint); font-family: var(--mono); font-size: 12px; }
.ep-head .done { color: var(--ok); font-weight: 700; }
.ep-head .chev { color: var(--text-faint); transition: transform .15s ease; font-size: 11px; }
.ep-head .chev.open { transform: rotate(90deg); }

.ep-body { padding: 4px 12px 12px; border-top: 1px solid var(--border); }
.summary {
  display: flex; flex-wrap: wrap; gap: 8px; align-items: center;
  margin: 10px 0 14px; padding: 11px 12px;
  background: var(--bg-2); border: 1px solid var(--border); border-radius: 9px;
}
.summary :deep(.v-chip) { font-size: 12.5px; }
.tok-detail { opacity: .85; margin-left: 4px; }

.tl { padding-top: 2px; }
.tl-row { display: flex; gap: 8px; align-items: baseline; font-size: 12.5px; }
.tl-time { color: var(--text-faint); font-family: var(--mono); flex-shrink: 0; }
.tl-label { color: var(--text); word-break: break-word; }
.tl-detail { color: var(--text-faint); }
.tl-wait { color: var(--warn); }

/* keep the timeline tight + kill the dangling connector stubs at both ends */
:deep(.v-timeline-item:first-child .v-timeline-divider__before),
:deep(.v-timeline-item:last-child .v-timeline-divider__after) { display: none !important; }
:deep(.v-timeline-item__body) { padding-inline-start: 8px; }
:deep(.v-timeline) { --v-timeline-line-thickness: 1px; }
</style>
