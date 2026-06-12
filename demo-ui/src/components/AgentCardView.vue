<script setup lang="ts">
import { computed, ref } from 'vue'
import type { AgentCard } from '../a2a/types'

const props = defineProps<{ card: AgentCard; sourceUrl?: string }>()
const showRaw = ref(false)

const caps = computed(() => props.card.capabilities ?? {})
const hasIO = computed(
  () => (props.card.defaultInputModes?.length ?? 0) > 0 || (props.card.defaultOutputModes?.length ?? 0) > 0,
)
const schemes = computed(() => Object.entries(props.card.securitySchemes ?? {}))
const hasSecurity = computed(
  () => schemes.value.length > 0 || (props.card.security?.length ?? 0) > 0 || props.card.supportsAuthenticatedExtendedCard != null,
)
function capColor(v: any) {
  return v === true ? 'success' : v === false ? 'default' : 'warning'
}
function capMark(v: any) {
  return v === true ? '✓' : v === false ? '✗' : '?'
}
const raw = computed(() => JSON.stringify(props.card, null, 2))
</script>

<template>
  <div class="ac">
    <!-- header -->
    <div class="ac-head">
      <v-avatar size="52" rounded="lg" color="surface-bright">
        <v-img v-if="card.iconUrl" :src="card.iconUrl" :alt="card.name" />
        <span v-else class="ac-emoji">🤖</span>
      </v-avatar>
      <div class="ac-id">
        <div class="ac-name">{{ card.name || 'Unnamed agent' }}</div>
        <div class="ac-sub">
          <v-chip v-if="card.version" size="x-small" variant="tonal">v{{ card.version }}</v-chip>
          <v-chip v-if="card.protocolVersion" size="x-small" variant="tonal" color="secondary">A2A {{ card.protocolVersion }}</v-chip>
          <span v-if="card.provider?.organization" class="ac-org">
            · {{ card.provider.organization }}<a v-if="card.provider.url" :href="card.provider.url" target="_blank" rel="noopener"> ↗</a>
          </span>
        </div>
      </div>
    </div>
    <p v-if="card.description" class="ac-desc">{{ card.description }}</p>

    <!-- endpoint / transport -->
    <section v-if="card.url || card.preferredTransport || card.additionalInterfaces?.length">
      <h4>Endpoint</h4>
      <div v-if="card.url" class="kv"><span class="k">url</span><span class="v mono">{{ card.url }}</span></div>
      <div v-if="card.preferredTransport" class="kv">
        <span class="k">transport</span>
        <span class="v"><v-chip size="x-small" variant="tonal" color="info">{{ card.preferredTransport }}</v-chip></span>
      </div>
      <div v-for="i in card.additionalInterfaces || []" :key="i.url" class="kv">
        <span class="k">also</span><span class="v mono">{{ i.transport }} · {{ i.url }}</span>
      </div>
    </section>

    <!-- capabilities -->
    <section v-if="card.capabilities">
      <h4>Capabilities</h4>
      <div class="row">
        <v-chip size="small" variant="tonal" :color="capColor(caps.streaming)">{{ capMark(caps.streaming) }} streaming</v-chip>
        <v-chip size="small" variant="tonal" :color="capColor(caps.pushNotifications)">{{ capMark(caps.pushNotifications) }} push</v-chip>
        <v-chip size="small" variant="tonal" :color="capColor(caps.stateTransitionHistory)">{{ capMark(caps.stateTransitionHistory) }} state history</v-chip>
      </div>
      <div v-if="caps.extensions?.length" class="exts">
        <div v-for="e in caps.extensions" :key="e.uri" class="ext">
          <div class="ext-top">
            <v-chip size="x-small" variant="tonal" :color="e.required ? 'warning' : undefined">{{ e.required ? 'required' : 'optional' }}</v-chip>
            <span class="ext-uri mono">{{ e.uri }}</span>
          </div>
          <div v-if="e.description" class="ext-desc">{{ e.description }}</div>
        </div>
      </div>
    </section>

    <!-- I/O modes -->
    <section v-if="hasIO">
      <h4>Default I/O modes</h4>
      <div class="kv"><span class="k">in</span><span class="v"><v-chip v-for="m in card.defaultInputModes || []" :key="m" size="x-small" variant="tonal" class="mr-1 mb-1">{{ m }}</v-chip></span></div>
      <div class="kv"><span class="k">out</span><span class="v"><v-chip v-for="m in card.defaultOutputModes || []" :key="m" size="x-small" variant="tonal" class="mr-1 mb-1">{{ m }}</v-chip></span></div>
    </section>

    <!-- security -->
    <section v-if="hasSecurity">
      <h4>Security</h4>
      <div v-for="[name, scheme] in schemes" :key="name" class="kv">
        <span class="k">{{ name }}</span><span class="v mono">{{ scheme.type }}<template v-if="scheme.scheme"> · {{ scheme.scheme }}</template><template v-if="scheme.in"> · in {{ scheme.in }}</template></span>
      </div>
      <div v-if="!schemes.length" class="muted">No security schemes (open)</div>
      <div v-if="card.supportsAuthenticatedExtendedCard != null" class="kv">
        <span class="k">extended card</span><span class="v">{{ card.supportsAuthenticatedExtendedCard ? 'supported' : 'no' }}</span>
      </div>
    </section>

    <!-- skills -->
    <section v-if="card.skills?.length">
      <h4>Skills ({{ card.skills.length }})</h4>
      <div v-for="s in card.skills" :key="s.id" class="skill">
        <div class="skill-name">{{ s.name || s.id }} <span class="skill-id mono">{{ s.id }}</span></div>
        <div v-if="s.description" class="skill-desc">{{ s.description }}</div>
        <div v-if="s.tags?.length" class="row mt"><v-chip v-for="t in s.tags" :key="t" size="x-small" variant="tonal" color="primary">{{ t }}</v-chip></div>
        <ul v-if="s.examples?.length" class="skill-ex"><li v-for="(ex, i) in s.examples" :key="i">{{ ex }}</li></ul>
        <div v-if="s.inputModes?.length || s.outputModes?.length" class="muted skill-modes">
          io: {{ (s.inputModes || []).join(', ') || '—' }} → {{ (s.outputModes || []).join(', ') || '—' }}
        </div>
      </div>
    </section>

    <!-- links + raw -->
    <section class="ac-foot">
      <a v-if="card.documentationUrl" :href="card.documentationUrl" target="_blank" rel="noopener" class="ac-link">📖 Documentation ↗</a>
      <a class="ac-link" href="#" @click.prevent="showRaw = !showRaw">{{ showRaw ? '▾' : '▸' }} raw JSON</a>
      <span v-if="sourceUrl" class="ac-src mono">{{ sourceUrl }}</span>
    </section>
    <pre v-if="showRaw" class="ac-raw">{{ raw }}</pre>
  </div>
</template>

<style scoped>
.ac { font-size: 13.5px; }
.ac-head { display: flex; align-items: center; gap: 12px; }
.ac-emoji { font-size: 26px; }
.ac-name { font-size: 17px; font-weight: 700; color: var(--text-strong); }
.ac-sub { display: flex; align-items: center; gap: 6px; flex-wrap: wrap; margin-top: 3px; color: var(--text-dim); font-size: 12px; }
.ac-org a { color: var(--accent-2); text-decoration: none; }
.ac-desc { color: var(--text-dim); margin: 12px 0 4px; line-height: 1.5; }

section { border-top: 1px solid var(--border); margin-top: 14px; padding-top: 10px; }
h4 { margin: 0 0 8px; font-size: 11px; text-transform: uppercase; letter-spacing: .06em; color: var(--text-faint); }
.kv { display: flex; gap: 10px; padding: 2px 0; align-items: baseline; }
.kv .k { color: var(--text-faint); min-width: 92px; flex-shrink: 0; }
.kv .v { color: var(--text); word-break: break-word; }
.mono { font-family: var(--mono); font-size: 12px; }
.row { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; }
.mt { margin-top: 6px; }

.exts { margin-top: 8px; display: flex; flex-direction: column; gap: 8px; }
.ext { background: var(--bg-3); border: 1px solid var(--border); border-radius: 8px; padding: 8px 10px; }
.ext-top { display: flex; align-items: center; gap: 8px; }
.ext-uri { color: var(--hitl); }
.ext-desc { color: var(--text-dim); font-size: 12px; margin-top: 4px; line-height: 1.45; }

.skill { background: var(--bg-3); border: 1px solid var(--border); border-radius: 9px; padding: 10px 12px; margin-bottom: 8px; }
.skill-name { font-weight: 600; color: var(--text-strong); }
.skill-id { color: var(--text-faint); font-size: 11px; font-weight: 400; margin-left: 6px; }
.skill-desc { color: var(--text-dim); margin-top: 3px; line-height: 1.45; }
.skill-ex { margin: 6px 0 0; padding-left: 18px; color: var(--text-dim); font-size: 12px; }
.skill-ex li { margin: 2px 0; }
.skill-modes { margin-top: 6px; font-family: var(--mono); }

.ac-foot { display: flex; align-items: center; gap: 16px; flex-wrap: wrap; }
.ac-link { color: var(--accent-2); text-decoration: none; font-size: 12px; cursor: pointer; }
.ac-link:hover { text-decoration: underline; }
.ac-src { color: var(--text-faint); font-size: 11px; margin-left: auto; }
.ac-raw { margin-top: 10px; padding: 10px; background: var(--bg); border: 1px solid var(--border); border-radius: 7px; font-family: var(--mono); font-size: 11.5px; color: var(--text-dim); white-space: pre-wrap; word-break: break-word; max-height: 320px; overflow-y: auto; }
</style>
