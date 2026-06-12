<script setup lang="ts">
import type { TaskState } from '../a2a/types'
defineProps<{ state: TaskState }>()
</script>

<template>
  <span class="pill" :class="state"><span class="led" /> {{ state }}</span>
</template>
