<script setup lang="ts">
import { ref, watch } from 'vue'
import { supabase } from '../lib/supabaseClient'
import { useAuthStore } from '../stores/auth'
import { errorMessage } from '../lib/errors'

interface CourseOption {
  id: string
  course_name: string
  course_code: string | null
  tier: 'beginner' | 'intermediate' | 'advanced'
}
interface Profile {
  tier: 'beginner' | 'intermediate' | 'advanced' | null
  class_taken: string | null
  needs_tier_reconfirmation: boolean | null
}

const props = defineProps<{ open: boolean }>()
const emit = defineEmits<{ close: [] }>()

const auth = useAuthStore()

const loading = ref(false)
const loadError = ref('')

// --- name -------------------------------------------------------------
const name = ref('')
const savingName = ref(false)
const nameError = ref('')
const nameSaved = ref(false)

// --- class / tier (student only) ---------------------------------------
const profile = ref<Profile | null>(null)
const courseOptions = ref<CourseOption[]>([])
const selectedClass = ref<string | null>(null)
const savingClass = ref(false)
const classError = ref('')
const classSaved = ref(false)

// --- password -----------------------------------------------------------
const newPassword = ref('')
const confirmPassword = ref('')
const savingPassword = ref(false)
const passwordError = ref('')
const passwordSaved = ref(false)

function courseLabel(c: CourseOption) {
  return c.course_code ? `${c.course_code} — ${c.course_name}` : c.course_name
}
const selectedCourse = () => courseOptions.value.find((c) => c.id === selectedClass.value) ?? null

async function loadProfileData() {
  loading.value = true
  loadError.value = ''
  nameSaved.value = false
  classSaved.value = false
  passwordSaved.value = false
  newPassword.value = ''
  confirmPassword.value = ''
  passwordError.value = ''
  name.value = auth.fullName ?? ''
  try {
    if (auth.role === 'student' && auth.user) {
      const [profileRes, coursesRes] = await Promise.all([
        supabase
          .from('user_profiles')
          .select('tier, class_taken, needs_tier_reconfirmation')
          .eq('user_id', auth.user.id)
          .maybeSingle(),
        supabase
          .from('course_tier_mappings')
          .select('id, course_name, course_code, tier')
          .eq('is_active', true)
          .order('display_order'),
      ])
      if (profileRes.error) throw profileRes.error
      if (coursesRes.error) throw coursesRes.error
      profile.value = (profileRes.data as Profile | null) ?? null
      courseOptions.value = (coursesRes.data ?? []) as CourseOption[]
      selectedClass.value = profile.value?.class_taken ?? null
    } else {
      profile.value = null
      courseOptions.value = []
      selectedClass.value = null
    }
  } catch (e) {
    loadError.value = errorMessage(e, 'Could not load your profile.')
  } finally {
    loading.value = false
  }
}

watch(
  () => props.open,
  (isOpen) => {
    if (isOpen) loadProfileData()
  }
)

async function saveName() {
  if (!auth.user) return
  nameError.value = ''
  nameSaved.value = false
  const trimmed = name.value.trim()
  if (!trimmed) {
    nameError.value = 'Name is required.'
    return
  }
  savingName.value = true
  try {
    const { error } = await supabase.from('users').update({ full_name: trimmed }).eq('id', auth.user.id)
    if (error) throw error
    await auth.loadProfile() // refreshes auth.fullName everywhere it's shown (topbar avatar, dashboard greeting, etc.)
    nameSaved.value = true
  } catch (e) {
    nameError.value = errorMessage(e, 'Could not save your name.')
  } finally {
    savingName.value = false
  }
}

async function saveClass() {
  if (!auth.user) return
  classError.value = ''
  classSaved.value = false
  if (!selectedClass.value) {
    classError.value = 'Pick a class.'
    return
  }
  savingClass.value = true
  try {
    const { error } = await supabase
      .from('user_profiles')
      .update({ class_taken: selectedClass.value })
      .eq('user_id', auth.user.id)
    if (error) throw error
    // Re-fetch rather than assume — the database (not this form)
    // decides whether needs_tier_reconfirmation actually flipped
    // (it only does if the class genuinely changed) and tier never
    // moves from this update no matter what, by design.
    const { data, error: reErr } = await supabase
      .from('user_profiles')
      .select('tier, class_taken, needs_tier_reconfirmation')
      .eq('user_id', auth.user.id)
      .maybeSingle()
    if (reErr) throw reErr
    profile.value = (data as Profile | null) ?? null
    classSaved.value = true
  } catch (e) {
    classError.value = errorMessage(e, 'Could not save your class.')
  } finally {
    savingClass.value = false
  }
}

async function savePassword() {
  passwordError.value = ''
  passwordSaved.value = false
  if (newPassword.value.length < 8) {
    passwordError.value = 'Password must be at least 8 characters.'
    return
  }
  if (newPassword.value !== confirmPassword.value) {
    passwordError.value = "Passwords don't match."
    return
  }
  savingPassword.value = true
  try {
    const { error } = await supabase.auth.updateUser({ password: newPassword.value })
    if (error) throw error
    newPassword.value = ''
    confirmPassword.value = ''
    passwordSaved.value = true
  } catch (e) {
    passwordError.value = errorMessage(e, 'Could not change your password.')
  } finally {
    savingPassword.value = false
  }
}
</script>

<template>
  <div v-if="open" class="drawer-backdrop" @click.self="emit('close')">
    <div class="drawer">
      <div style="display: flex; align-items: center; justify-content: space-between">
        <h2 style="font-size: 19px">Your profile</h2>
        <button class="icon-btn" aria-label="Close" @click="emit('close')">✕</button>
      </div>

      <p v-if="loading">Loading…</p>
      <p v-else-if="loadError" class="error-note">{{ loadError }}</p>

      <template v-else>
        <div class="chip-row">
          <span class="badge accent" style="text-transform: capitalize">{{ auth.role?.replace('_', ' ') }}</span>
          <span v-if="profile?.tier" class="badge violet" style="text-transform: capitalize">{{ profile.tier }} tier</span>
        </div>

        <!-- ============ NAME ============ -->
        <div class="field">
          <label>Name</label>
          <input v-model="name" type="text" placeholder="Your name" />
        </div>
        <p v-if="nameError" class="error-note">{{ nameError }}</p>
        <p v-else-if="nameSaved" class="field-hint" style="color: var(--good)">Saved.</p>
        <button class="btn primary small" style="align-self: flex-start" :disabled="savingName" @click="saveName">
          {{ savingName ? 'Saving…' : 'Save name' }}
        </button>

        <div class="field">
          <label>Email</label>
          <input :value="auth.user?.email ?? ''" type="text" disabled />
          <p class="field-hint">Contact Cage staff to change the email on your account.</p>
        </div>

        <!-- ============ CLASS / TIER (student only) ============ -->
        <template v-if="auth.role === 'student'">
          <hr class="divider" />
          <div class="field">
            <label>Class you're taking</label>
            <select v-model="selectedClass">
              <option :value="null" disabled>Select a class…</option>
              <option v-for="c in courseOptions" :key="c.id" :value="c.id">{{ courseLabel(c) }}</option>
            </select>
            <p class="field-hint">
              Changing your class doesn't change your tier right away — staff review and confirm it
              before equipment access actually updates.
            </p>
          </div>
          <div v-if="profile?.needs_tier_reconfirmation" class="info-note">
            <span>⏳</span>
            <span>
              Pending staff review{{ selectedCourse() ? ` — you're currently still ${profile.tier} tier` : '' }}.
            </span>
          </div>
          <p v-if="classError" class="error-note">{{ classError }}</p>
          <p v-else-if="classSaved" class="field-hint" style="color: var(--good)">Saved — pending staff review.</p>
          <button
            class="btn primary small"
            style="align-self: flex-start"
            :disabled="savingClass || selectedClass === profile?.class_taken"
            @click="saveClass"
          >
            {{ savingClass ? 'Saving…' : 'Save class' }}
          </button>
        </template>

        <!-- ============ PASSWORD ============ -->
        <hr class="divider" />
        <div class="section-title" style="font-size: 13.5px">Change password</div>
        <div class="field">
          <label>New password</label>
          <input v-model="newPassword" type="password" placeholder="At least 8 characters" />
        </div>
        <div class="field">
          <label>Confirm new password</label>
          <input v-model="confirmPassword" type="password" placeholder="Re-type the new password" />
        </div>
        <p v-if="passwordError" class="error-note">{{ passwordError }}</p>
        <p v-else-if="passwordSaved" class="field-hint" style="color: var(--good)">Password changed.</p>
        <button
          class="btn primary small"
          style="align-self: flex-start"
          :disabled="savingPassword"
          @click="savePassword"
        >
          {{ savingPassword ? 'Saving…' : 'Change password' }}
        </button>
      </template>
    </div>
  </div>
</template>

<style scoped>
.error-note {
  color: var(--crit);
}
</style>
