<script setup lang="ts">
import { ref } from 'vue'
import { useRouter } from 'vue-router'
import { useAuthStore } from '../stores/auth'
import logoFull from '../assets/logo-full.png'

const email = ref('')
const password = ref('')
const error = ref('')
const submitting = ref(false)

const auth = useAuthStore()
const router = useRouter()

async function onSubmit() {
  error.value = ''
  submitting.value = true
  try {
    await auth.signIn(email.value, password.value)
    router.push({ name: 'dashboard' })
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'Sign in failed'
  } finally {
    submitting.value = false
  }
}
</script>

<template>
  <main class="login-page">
    <div class="login-card card">
      <div class="login-logo">
        <img :src="logoFull" alt="The Film Cage" />
      </div>
      <p class="login-sub">Utah Tech Film Dept equipment checkout</p>

      <form @submit.prevent="onSubmit">
        <div class="field">
          <label for="login-email">Email</label>
          <input id="login-email" v-model="email" type="email" required autocomplete="username" />
        </div>
        <div class="field">
          <label for="login-password">Password</label>
          <input id="login-password" v-model="password" type="password" required autocomplete="current-password" />
        </div>
        <button class="btn primary" type="submit" :disabled="submitting" style="width: 100%; margin-top: 4px">
          {{ submitting ? 'Signing in…' : 'Sign in' }}
        </button>
        <p v-if="error" class="error-note">{{ error }}</p>
      </form>
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
  /* The logo asset is a flattened export on a white background, so it
     keeps a faint light halo on dark surfaces -- see the matching note
     on .brand-mark in components.css. A fixed light tile here avoids it
     the same way, regardless of which theme the page is in. */
  background: #FFFFFF;
  border: 1px solid var(--border);
  border-radius: var(--radius-m);
  padding: 14px 18px;
  max-width: 100%;
  height: auto;
}
.login-sub {
  text-align: center;
  color: var(--ink-2);
  font-size: 12.5px;
  margin-top: -6px;
}
form {
  display: flex;
  flex-direction: column;
  gap: 14px;
}
</style>
