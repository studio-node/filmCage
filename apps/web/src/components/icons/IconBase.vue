<script setup lang="ts">
// A small, hand-drawn line-icon set covering everything the app used to
// render as an emoji or a bare text glyph (search/bell/lock/camera/menu/
// close/check/chevrons), plus the nav icons the sidebar's NavItem type
// has always declared but never actually rendered. One shared component
// instead of 18 tiny files -- same stroke weight/size/viewBox everywhere
// so the whole icon set reads as one family.
withDefaults(
  defineProps<{
    name:
      | 'menu' | 'search' | 'close' | 'bell' | 'lock' | 'camera' | 'check'
      | 'chevron-left' | 'chevron-right' | 'sun' | 'moon'
      | 'grid' | 'box' | 'calendar' | 'list' | 'inbox' | 'truck' | 'chart' | 'shield'
    size?: number
  }>(),
  { size: 18 }
)
</script>

<template>
  <svg
    :width="size"
    :height="size"
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    stroke-width="1.8"
    stroke-linecap="round"
    stroke-linejoin="round"
    aria-hidden="true"
    class="icon"
  >
    <template v-if="name === 'menu'">
      <line x1="3.5" y1="6.5" x2="20.5" y2="6.5" />
      <line x1="3.5" y1="12" x2="20.5" y2="12" />
      <line x1="3.5" y1="17.5" x2="20.5" y2="17.5" />
    </template>

    <template v-else-if="name === 'search'">
      <circle cx="10.5" cy="10.5" r="6.5" />
      <line x1="15.3" y1="15.3" x2="20.5" y2="20.5" />
    </template>

    <template v-else-if="name === 'close'">
      <line x1="5" y1="5" x2="19" y2="19" />
      <line x1="19" y1="5" x2="5" y2="19" />
    </template>

    <template v-else-if="name === 'bell'">
      <path d="M6 10.5a6 6 0 0 1 12 0c0 4 1.4 5.6 2 6.5H4c.6-.9 2-2.5 2-6.5Z" />
      <path d="M10 19.5a2.2 2.2 0 0 0 4 0" />
    </template>

    <template v-else-if="name === 'lock'">
      <rect x="5" y="11" width="14" height="9.5" rx="2" />
      <path d="M8 11V8a4 4 0 0 1 8 0v3" />
    </template>

    <template v-else-if="name === 'camera'">
      <circle cx="10" cy="11" r="2.1" />
      <circle cx="14.4" cy="9.4" r="1.6" />
      <rect x="4.5" y="11.5" width="11" height="7" rx="1.6" />
      <path d="M15.5 14.5 19.5 12v5.5l-4-2.3Z" />
    </template>

    <template v-else-if="name === 'check'">
      <path d="M5 12.5 9.5 17 19 6.5" />
    </template>

    <template v-else-if="name === 'chevron-left'">
      <path d="M14.5 5.5 8 12l6.5 6.5" />
    </template>

    <template v-else-if="name === 'chevron-right'">
      <path d="M9.5 5.5 16 12l-6.5 6.5" />
    </template>

    <template v-else-if="name === 'sun'">
      <circle cx="12" cy="12" r="4.3" />
      <line x1="12" y1="2.5" x2="12" y2="5" />
      <line x1="12" y1="19" x2="12" y2="21.5" />
      <line x1="2.5" y1="12" x2="5" y2="12" />
      <line x1="19" y1="12" x2="21.5" y2="12" />
      <line x1="4.9" y1="4.9" x2="6.6" y2="6.6" />
      <line x1="17.4" y1="17.4" x2="19.1" y2="19.1" />
      <line x1="4.9" y1="19.1" x2="6.6" y2="17.4" />
      <line x1="17.4" y1="6.6" x2="19.1" y2="4.9" />
    </template>

    <template v-else-if="name === 'moon'">
      <path d="M19.5 14.3A8 8 0 1 1 9.7 4.5a6.4 6.4 0 0 0 9.8 9.8Z" />
    </template>

    <!-- nav icons -->
    <template v-else-if="name === 'grid'">
      <rect x="3.75" y="3.75" width="7" height="7" rx="1.3" />
      <rect x="13.25" y="3.75" width="7" height="7" rx="1.3" />
      <rect x="3.75" y="13.25" width="7" height="7" rx="1.3" />
      <rect x="13.25" y="13.25" width="7" height="7" rx="1.3" />
    </template>

    <template v-else-if="name === 'box'">
      <path d="M12 3.5 20 7.8v8.4L12 20.5 4 16.2V7.8Z" />
      <path d="M4 7.8 12 12l8-4.2" />
      <line x1="12" y1="12" x2="12" y2="20.5" />
    </template>

    <template v-else-if="name === 'calendar'">
      <rect x="3.75" y="5" width="16.5" height="15" rx="2" />
      <line x1="3.75" y1="9.5" x2="20.25" y2="9.5" />
      <line x1="8" y1="3" x2="8" y2="6.5" />
      <line x1="16" y1="3" x2="16" y2="6.5" />
    </template>

    <template v-else-if="name === 'list'">
      <line x1="9" y1="6.5" x2="20" y2="6.5" />
      <line x1="9" y1="12" x2="20" y2="12" />
      <line x1="9" y1="17.5" x2="20" y2="17.5" />
      <line x1="4.3" y1="6.5" x2="4.7" y2="6.5" />
      <line x1="4.3" y1="12" x2="4.7" y2="12" />
      <line x1="4.3" y1="17.5" x2="4.7" y2="17.5" />
    </template>

    <template v-else-if="name === 'inbox'">
      <path d="M3.5 13 6 5.5h12l2.5 7.5" />
      <path d="M3.5 13v5.5a1.5 1.5 0 0 0 1.5 1.5h14a1.5 1.5 0 0 0 1.5-1.5V13h-5l-1.5 2.3h-4L8 13H3.5Z" />
    </template>

    <template v-else-if="name === 'truck'">
      <rect x="2.75" y="7" width="11" height="9" rx="1.2" />
      <path d="M13.75 10h3.6l2.9 3v3h-6.5Z" />
      <circle cx="7" cy="18" r="1.7" />
      <circle cx="16.5" cy="18" r="1.7" />
    </template>

    <template v-else-if="name === 'chart'">
      <line x1="4" y1="20" x2="20" y2="20" />
      <rect x="6" y="13" width="3.2" height="7" rx="0.6" />
      <rect x="10.4" y="8.5" width="3.2" height="11.5" rx="0.6" />
      <rect x="14.8" y="4.5" width="3.2" height="15.5" rx="0.6" />
    </template>

    <template v-else-if="name === 'shield'">
      <path d="M12 3.2 19 6v5.5c0 4.8-3 7.6-7 9.3-4-1.7-7-4.5-7-9.3V6Z" />
      <path d="M9 12 11.2 14.2 15.5 9.5" />
    </template>
  </svg>
</template>

<style scoped>
.icon {
  flex: none;
  display: block;
}
</style>
