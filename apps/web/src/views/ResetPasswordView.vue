<script setup lang="ts">
import { ref } from 'vue'
import { useRouter } from 'vue-router'
import { supabase } from '../lib/supabaseClient'
import { useAuthStore } from '../stores/auth'
import { errorMessage } from '../lib/errors'
import logoFull from '../assets/logo-full.png'

// Where a password-reset email lands. auth.init() verifies the
// ?token_hash=...&type=recovery link (signing the person in) and sets
// auth.passwordRecovery, and the router keeps them here until they've
// chosen a new password.
const auth = useAuthStore()
const router = useRouter()

const password = ref('')
const confirm = ref('')
const error = ref('')
const saving = ref(false)

async function save() {
  error.value = ''
  if (password.value.length < 8) {
    error.value = 'Password must be at least 8 characters.'
    return
  }
  if (password.value !== confirm.value) {
    error.value = "Passwords don't match."
    return
  }
  saving.value = true
  try {
    const { error: err } = await supabase.auth.updateUser({ password: password.value })
    if (err) throw err
    auth.passwordRecovery = false
    router.replace({ name: 'dashboard' })
  } catch (e) {
    error.value = errorMessage(e, 'Could not set your password.')
  } finally {
    saving.value = false
  }
}
</script>

<template>
  <main class="login-page">
    <div class="login-card card">
      <div class="login-logo">
        <img :src="logoFull" alt="The Film Cage" />
      </div>
      <template v-if="auth.user">
        <p class="login-sub">Choose a new password</p>
        <form @submit.prevent="save">
          <div class="field">
            <label for="new-password">New password</label>
            <input id="new-password" v-model="password" type="password" required autocomplete="new-password" />
          </div>
          <div class="field">
            <label for="confirm-password">Confirm new password</label>
            <input id="confirm-password" v-model="confirm" type="password" required autocomplete="new-password" />
          </div>
          <button class="btn primary" type="submit" :disabled="saving" style="width: 100%">
            {{ saving ? 'Saving…' : 'Save password' }}
          </button>
          <p v-if="error" class="error-note">{{ error }}</p>
        </form>
      </template>
      <template v-else>
        <p class="error-note">
          {{ auth.recoveryError || 'This reset link is invalid or has expired.' }} Ask for a new one from the sign-in page.
        </p>
        <router-link class="btn" :to="{ name: 'login' }">Back to sign in</router-link>
      </template>
    </div>
  </main>
</template>

<style scoped>
.login-page {
  min-height: 100vh;
  display: flex;
  align-items: center;
  justify-content: center;
  background: var(--bg);
  padding: 20px;
}
.login-card {
  width: 100%;
  max-width: 360px;
  display: flex;
  flex-direction: column;
  gap: 18px;
  padding: 32px 28px;
}
.login-logo {
  display: flex;
  justify-content: center;
}
.login-logo img {
  background: #ffffff;
  border: 1px solid var(--border);
  border-radius: var(--radius-m);
  padding: 14px 18px;
  max-width: 100%;
  height: auto;
}
.login-sub {
  text-align: center;
  color: var(--ink-2);
  font-size: 13px;
  margin-top: -6px;
}
form {
  display: flex;
  flex-direction: column;
  gap: 14px;
}
</style>
