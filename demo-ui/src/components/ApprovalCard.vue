<script setup lang="ts">
import { reactive } from 'vue'
import type { ToolCall, ToolDecision } from '../a2a/types'

const props = defineProps<{ calls: ToolCall[]; busy: boolean }>()
const emit = defineEmits<{ (e: 'decide', decisions: ToolDecision[]): void }>()

const denyMsgs = reactive<Record<string, string>>({})

function pretty(input: any): string {
  try {
    return JSON.stringify(input ?? {}, null, 2)
  } catch {
    return String(input)
  }
}

function allowAll() {
  emit('decide', props.calls.map((c) => ({ toolUseId: c.toolUseId, result: 'allow' as const })))
}
function denyAll() {
  emit(
    'decide',
    props.calls.map((c) => ({
      toolUseId: c.toolUseId,
      result: 'deny' as const,
      denyMessage: denyMsgs[c.toolUseId] || undefined,
    })),
  )
}
</script>

<template>
  <div class="approval">
    <div class="ahead">⚖️ Approval required — {{ calls.length }} tool call{{ calls.length > 1 ? 's' : '' }} (input-required)</div>
    <div class="acall" v-for="c in calls" :key="c.toolUseId">
      <div class="row">
        <span class="aname">{{ c.name }}</span>
        <span class="chip" v-if="c.key">{{ c.key }}</span>
        <span class="chip" v-if="c.toolType">{{ c.toolType }}</span>
      </div>
      <pre class="ainput" v-if="c.input && Object.keys(c.input).length">{{ pretty(c.input) }}</pre>
      <input
        class="deny-input"
        style="margin-top:8px;width:100%"
        v-model="denyMsgs[c.toolUseId]"
        placeholder="optional deny message for this tool…"
      />
    </div>
    <div class="actions">
      <button class="btn allow" :disabled="busy" @click="allowAll">✓ Allow</button>
      <button class="btn deny" :disabled="busy" @click="denyAll">✕ Deny</button>
    </div>
  </div>
</template>
