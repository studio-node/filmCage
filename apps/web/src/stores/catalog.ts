import { defineStore } from 'pinia'
import { supabase } from '../lib/supabaseClient'
import { fuzzyMatch } from '../lib/fuzzySearch'

export interface CatalogCategory {
  id: string
  name: string
  kind: 'direct' | 'general'
  display_order: number
}
export interface CatalogLocation {
  id: string
  name: string
}
export interface CatalogItem {
  id: string
  name: string
  brand: string | null
  model: string | null
  description: string | null
  purchase_price: number | null
  location_id: string
  direct_category_id: string | null
  general_category_id: string | null
  min_tier: 'beginner' | 'intermediate' | 'advanced'
}
export interface CatalogSearchResult {
  item: CatalogItem
  score: number
}

// Shared, in-memory cache of the equipment catalog (item models, plus
// the categories/locations needed to label them) — loaded once and
// reused by both the top-nav global search and the Browse Equipment
// page, instead of each place fetching it independently. This also
// holds the search box's text itself (`query`), so the nav bar's
// search input and the Browse Equipment page's search input are
// really just two views onto the same state, the way the mockup's
// single global STATE.search drove both.
//
// Unit-level availability (item_units_with_status) is NOT cached
// here — that's per-unit stock that changes far more often than the
// catalog itself, and only Browse Equipment needs it, so it still
// fetches that part on its own.
export const useCatalogStore = defineStore('catalog', {
  state: () => ({
    items: [] as CatalogItem[],
    categories: [] as CatalogCategory[],
    locations: [] as CatalogLocation[],
    loaded: false,
    loading: false,
    error: '',
    query: '',
    // Set by the global search dropdown when someone picks a specific
    // item rather than just submitting the whole query. Browse
    // Equipment watches this and opens that item's drawer once it
    // sees it, then clears it back to null.
    pendingOpenItemId: null as string | null,
  }),
  getters: {
    categoryById: (state) => new Map(state.categories.map((c) => [c.id, c])),
    locationById: (state) => new Map(state.locations.map((l) => [l.id, l])),
  },
  actions: {
    async ensureLoaded(force = false) {
      if (this.loaded && !force) return
      if (this.loading) return
      this.loading = true
      this.error = ''
      try {
        const [catRes, locRes, modelRes] = await Promise.all([
          supabase.from('categories').select('id, name, kind, display_order').order('display_order'),
          supabase.from('locations').select('id, name').order('name'),
          supabase
            .from('item_models')
            .select(
              'id, name, brand, model, description, purchase_price, location_id, direct_category_id, general_category_id, min_tier'
            )
            .eq('is_active', true)
            .order('name'),
        ])
        if (catRes.error) throw catRes.error
        if (locRes.error) throw locRes.error
        if (modelRes.error) throw modelRes.error

        this.categories = catRes.data ?? []
        this.locations = locRes.data ?? []
        this.items = (modelRes.data ?? []) as CatalogItem[]
        this.loaded = true
      } catch (e) {
        this.error = e instanceof Error ? e.message : 'Failed to load the catalog'
      } finally {
        this.loading = false
      }
    },

    // The text one item is searchable by: its own name/brand/model,
    // plus both of its category names and its location — so "lav" or
    // "the cage" can surface an item even if neither word is in its
    // name. Still used by Browse Equipment's grid filter, which has
    // no cap and so doesn't need the tiered ranking below -- every
    // match shows regardless of order.
    searchableText(item: CatalogItem): string {
      const direct = item.direct_category_id ? this.categoryById.get(item.direct_category_id)?.name : ''
      const general = item.general_category_id ? this.categoryById.get(item.general_category_id)?.name : ''
      const location = this.locationById.get(item.location_id)?.name
      return [item.name, item.brand, item.model, direct, general, location].filter(Boolean).join(' ')
    },

    // Three separate slices of the same text, used only by rank()
    // below to tell apart WHY something matched, not just whether it
    // did:
    //  - identityText: the item's own name/brand/model.
    //  - directCategoryText: its direct category only (e.g.
    //    "Cameras" -- the specific "this item IS one of these" tag).
    //  - restText: its general category (e.g. "Camera Dept" -- a
    //    broader "belongs to this department" tag, which can cover
    //    plenty of non-camera gear) plus its location.
    identityText(item: CatalogItem): string {
      return [item.name, item.brand, item.model].filter(Boolean).join(' ')
    },
    directCategoryText(item: CatalogItem): string {
      return item.direct_category_id ? this.categoryById.get(item.direct_category_id)?.name ?? '' : ''
    },
    restText(item: CatalogItem): string {
      const general = item.general_category_id ? this.categoryById.get(item.general_category_id)?.name : ''
      const location = this.locationById.get(item.location_id)?.name
      return [general, location].filter(Boolean).join(' ')
    },

    // Ranks a list of items for a query into tiers, best tier first,
    // best score within a tier second:
    //   0 — matched on the item's own name/brand/model
    //   1 — matched on its direct category (a specific "this is one
    //       of these" tag, e.g. "Cameras")
    //   2 — matched only on its general category or location (a
    //       broader tag, e.g. "Camera Dept", that plenty of non-
    //       matching gear can also share)
    // This is what keeps a specific, well-tagged item (a camera
    // literally tagged direct-category "Cameras") from getting
    // crowded out of a short, capped results list by a flood of
    // OTHER items that only share its broader general-category tag
    // (e.g. a dozen "Camera Dept" items that aren't themselves
    // cameras) -- without this, every one of those ties at the same
    // fuzzy score and a hard cap just keeps whichever came first
    // alphabetically, which has nothing to do with relevance.
    rank(query: string, items: CatalogItem[]): { item: CatalogItem; tier: number; score: number }[] {
      const q = query.trim()
      if (!q) return []
      const results: { item: CatalogItem; tier: number; score: number }[] = []
      for (const item of items) {
        const identity = fuzzyMatch(q, this.identityText(item))
        if (identity) {
          results.push({ item, tier: 0, score: identity.score })
          continue
        }
        const direct = fuzzyMatch(q, this.directCategoryText(item))
        if (direct) {
          results.push({ item, tier: 1, score: direct.score })
          continue
        }
        const rest = fuzzyMatch(q, this.restText(item))
        if (rest) results.push({ item, tier: 2, score: rest.score })
      }
      results.sort((a, b) => a.tier - b.tier || a.score - b.score)
      return results
    },

    // Ranked fuzzy search over the whole catalog for the nav bar's
    // small suggestion dropdown — best tier/score first, capped at
    // `limit`.
    search(query: string, limit = 8): CatalogSearchResult[] {
      return this.rank(query, this.items)
        .slice(0, limit)
        .map((r) => ({ item: r.item, score: r.score }))
    },
  },
})
