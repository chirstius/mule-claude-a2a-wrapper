<script setup lang="ts">
import { computed, nextTick, ref, watch } from 'vue'
import { mdiCardAccountDetailsOutline, mdiWeatherNight, mdiWhiteBalanceSunny } from '@mdi/js'
import { useTheme } from 'vuetify'
import { useA2A } from './composables/useA2A'
import { A2AClient } from './a2a/client'
import TurnView from './components/TurnView.vue'
import PushPanel from './components/PushPanel.vue'
import AgentCardView from './components/AgentCardView.vue'
import type { AgentCard, ToolDecision } from './a2a/types'

const { store, sendText, respondToApprovals, cancel, reset } = useA2A()

const theme = useTheme()
const isDark = computed(() => theme.global.current.value.dark)
function toggleTheme() {
  const next = isDark.value ? 'claudeLight' : 'claudeDark'
  theme.global.name.value = next
  document.documentElement.setAttribute('data-theme', next === 'claudeLight' ? 'light' : 'dark')
  try {
    localStorage.setItem('a2a-theme', next)
  } catch {
    /* localStorage unavailable */
  }
}

const draft = ref('')
const convo = ref<HTMLElement | null>(null)

// "Stick to bottom": only auto-scroll when the user is already at (or near) the
// bottom. If they've scrolled up to read earlier content, streaming updates must
// NOT yank them back down.
let stick = true
function onScroll() {
  const el = convo.value
  if (!el) return
  stick = el.scrollHeight - el.scrollTop - el.clientHeight < 80
}
function scrollDown() {
  if (!stick) return
  nextTick(() => {
    if (convo.value) convo.value.scrollTop = convo.value.scrollHeight
  })
}
watch(() => store.turns.map((t) => (t.role === 'agent' ? t.timeline.length : 0)).join(','), scrollDown)
watch(() => store.turns.length, scrollDown)

async function submit() {
  const text = draft.value
  draft.value = ''
  stick = true // the user just sent — always snap to the latest
  await sendText(text)
}
function onKey(e: KeyboardEvent) {
  if (e.key === 'Enter' && !e.shiftKey) {
    e.preventDefault()
    submit()
  }
}
function approve(turn: any, decisions: ToolDecision[]) {
  respondToApprovals(turn, decisions)
}

const samples = [
  'In one sentence, what is the A2A protocol?',
  'Create a file haiku.txt with a haiku about streaming data, then tell me what you wrote.',
  'My favorite number is 42.',
]

// ---- agent card inspector ----
const cardDialog = ref(false)
const cardLoading = ref(false)
const cardError = ref('')
const card = ref<AgentCard | null>(null)
const cardSourceUrl = ref('')
async function openCard() {
  cardDialog.value = true
  cardLoading.value = true
  cardError.value = ''
  try {
    const { card: c, sourceUrl } = await new A2AClient(store.endpoint).fetchAgentCard()
    card.value = c
    cardSourceUrl.value = sourceUrl
  } catch (e: any) {
    cardError.value = String(e?.message ?? e)
    card.value = null
  } finally {
    cardLoading.value = false
  }
}
</script>

<template>
  <v-app>
  <div class="app">
    <header class="header">
      <div class="brand">
        <span class="dot" />
        Claude&nbsp;A2A&nbsp;Console
      </div>
      <div class="spacer" />
      <div class="url-field">
        <span>Agent&nbsp;endpoint</span>
        <input type="text" v-model="store.endpoint" placeholder="https://host/a2a" spellcheck="false" title="Full A2A endpoint URL — point at any wrapped agent" />
      </div>
      <button class="btn ghost card-btn" @click="openCard" title="Fetch & view this endpoint's A2A agent card">
        <v-icon :icon="mdiCardAccountDetailsOutline" size="18" />Agent&nbsp;card
      </button>
      <button
        class="btn ghost icon-btn"
        @click="toggleTheme"
        :title="isDark ? 'Switch to light mode' : 'Switch to dark mode'"
        :aria-label="isDark ? 'Switch to light mode' : 'Switch to dark mode'"
      >
        <v-icon :icon="isDark ? mdiWhiteBalanceSunny : mdiWeatherNight" size="18" />
      </button>
      <div class="seg" role="tablist" aria-label="mode">
        <button :class="{ active: store.mode === 'stream' }" @click="store.mode = 'stream'">streaming</button>
        <button :class="{ active: store.mode === 'blocking' }" @click="store.mode = 'blocking'">blocking</button>
      </div>
    </header>

    <v-dialog v-model="cardDialog" max-width="780" scrollable>
      <v-card color="surface">
        <div class="cd-head">
          <span class="cd-title"><v-icon :icon="mdiCardAccountDetailsOutline" size="18" />Agent card</span>
          <span class="spacer" />
          <button class="btn-mini" @click="cardDialog = false">✕ close</button>
        </div>
        <v-divider />
        <v-card-text class="cd-body">
          <div v-if="cardLoading" class="muted">Fetching agent card from {{ store.endpoint }} …</div>
          <div v-else-if="cardError" class="banner" style="margin:0">⚠ {{ cardError }}</div>
          <AgentCardView v-else-if="card" :card="card" :source-url="cardSourceUrl" />
        </v-card-text>
      </v-card>
    </v-dialog>

    <div v-if="store.error" class="banner" style="margin-top:10px">⚠ {{ store.error }}</div>

    <div class="body">
      <div class="main">
        <div class="conversation" ref="convo" @scroll="onScroll">
          <div v-if="!store.turns.length" class="empty">
            <h2>👋 Chat with the wrapped Claude agent over A2A</h2>
            <p>
              Toggle <strong>streaming</strong> vs <strong>blocking</strong> up top. In streaming you'll see live
              state changes, tool-usage relays, artifacts, and — if the agent pauses for a gated tool — an
              <strong>approval card</strong> (input-required / HITL).
            </p>
            <p class="row" style="justify-content:center">
              <button v-for="s in samples" :key="s" class="btn ghost" @click="draft = s">{{ s.length > 38 ? s.slice(0, 38) + '…' : s }}</button>
            </p>
          </div>

          <TurnView
            v-for="t in store.turns"
            :key="t.id"
            :turn="t"
            :busy="store.busy"
            @approve="(d) => approve(t, d)"
          />
        </div>

        <div class="composer">
          <textarea
            v-model="draft"
            :placeholder="store.busy ? 'agent is working…' : 'Message the agent…  (Enter to send, Shift+Enter for newline)'"
            @keydown="onKey"
            rows="1"
          />
          <button v-if="store.busy" class="btn deny" @click="cancel">■ Cancel</button>
          <button v-else class="btn primary" :disabled="!draft.trim()" @click="submit">Send ▸</button>
        </div>
      </div>

      <aside class="side">
        <div class="card">
          <h3>Conversation</h3>
          <div class="kv"><span class="k">contextId</span><span class="v">{{ store.contextId ? store.contextId.slice(0, 13) + '…' : '—' }}</span></div>
          <div class="kv"><span class="k">turns</span><span class="v">{{ store.turns.length }}</span></div>
          <div class="kv"><span class="k">mode</span><span class="v">{{ store.mode }}</span></div>
          <div class="kv"><span class="k">status</span><span class="v">{{ store.busy ? 'working' : 'idle' }}</span></div>
          <button class="btn ghost" style="margin-top:10px;width:100%" @click="reset">↺ New conversation</button>
        </div>

        <div class="card">
          <h3>State legend</h3>
          <div class="legend">
            <span class="pill submitted"><span class="led" /> submitted</span>
            <span class="pill working"><span class="led" /> working</span>
            <span class="pill input-required"><span class="led" /> input-required (HITL)</span>
            <span class="pill completed"><span class="led" /> completed</span>
            <span class="pill failed"><span class="led" /> failed</span>
            <span class="pill canceled"><span class="led" /> canceled</span>
          </div>
        </div>

        <PushPanel
          :enabled="store.pushEnabled"
          :deliveries="store.pushDeliveries"
          @toggle="(v) => (store.pushEnabled = v)"
        />
      </aside>
    </div>
  </div>
  </v-app>
</template>
