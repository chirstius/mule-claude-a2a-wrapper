<script setup lang="ts">
import type { PushDelivery } from '../composables/useA2A'
defineProps<{ enabled: boolean; deliveries: PushDelivery[] }>()
const emit = defineEmits<{ (e: 'toggle', v: boolean): void }>()
</script>

<template>
  <div class="card">
    <h3>Push notifications</h3>
    <label class="switch" style="opacity:.5; cursor:not-allowed" title="Not yet implemented">
      <input type="checkbox" :checked="enabled" disabled @change="emit('toggle', ($event.target as HTMLInputElement).checked)" />
      <span class="track" />
      <span class="muted">advertise webhook config</span>
    </label>
    <p class="muted" style="margin:10px 0 0">
      Not yet implemented. Ensure agent cards advertise: <code>pushNotifications:false</code>
    </p>
    <div v-if="deliveries.length" class="tline" style="margin-top:10px">
      <div class="tl" v-for="d in deliveries" :key="d.id">
        <span class="tk data">push</span><span class="td">{{ d.summary }}</span>
      </div>
    </div>
    <div v-else class="muted" style="margin-top:10px; font-style: italic">no deliveries yet</div>
  </div>
</template>
