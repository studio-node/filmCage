<script setup lang="ts">
import { ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import AdminAddItemView from './AdminAddItemView.vue'
import EditItemsView from './EditItemsView.vue'

type InventoryTab = 'add' | 'edit'

// Suzanne's ask (11/11, later): "combine those into inventory
// management and then put that page with 2 tabs" -- Add Items and
// Edit Items were two near-identical nav entries pointing at two
// separate full pages; now they're one page with a tab switcher,
// same shape as the Reservation Queue's own Pending/All tabs.
const route = useRoute()
const router = useRouter()

// Driven by (and reflected back into) the `tab` query param, so a
// bookmark, a reload, or the old /admin and /admin/items redirects
// (see router/index.ts) all land on the right tab -- not just local
// component state that resets on navigation.
const activeTab = ref<InventoryTab>(route.query.tab === 'edit' ? 'edit' : 'add')

watch(activeTab, (tab) => {
  if (route.query.tab !== tab) {
    router.replace({ query: { ...route.query, tab } })
  }
})
watch(
  () => route.query.tab,
  (tab) => {
    const next: InventoryTab = tab === 'edit' ? 'edit' : 'add'
    if (next !== activeTab.value) activeTab.value = next
  }
)
</script>

<template>
  <div class="view">
    <div class="view-head">
      <div>
        <span class="view-eyebrow">Inventory</span>
        <h1>Inventory Management</h1>
        <p class="view-desc">
          Add new equipment to the catalog, or update an existing item's details and per-unit
          condition.
        </p>
      </div>
    </div>

    <div class="tabs">
      <button class="tab" :class="{ active: activeTab === 'add' }" @click="activeTab = 'add'">
        Add Item
      </button>
      <button class="tab" :class="{ active: activeTab === 'edit' }" @click="activeTab = 'edit'">
        Edit Items
      </button>
    </div>

    <!-- Each tab is still its own component with its own fetch/save
    logic -- nothing about Add Items or Edit Items was rewritten here,
    just given a shared page shell and a tab to switch between. -->
    <AdminAddItemView v-if="activeTab === 'add'" />
    <EditItemsView v-else />
  </div>
</template>
