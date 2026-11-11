// Light/dark theme toggle for the top bar. tokens.css already supports
// both palettes via @media(prefers-color-scheme) and an explicit
// data-theme attribute -- this just adds a manual override on top of
// that OS default, remembered across visits.
import { ref } from 'vue'

const STORAGE_KEY = 'filmcage-theme'
type ThemePref = 'light' | 'dark'

function systemPrefersDark(): boolean {
  return window.matchMedia('(prefers-color-scheme: dark)').matches
}

function readStored(): ThemePref | null {
  try {
    const v = localStorage.getItem(STORAGE_KEY)
    return v === 'light' || v === 'dark' ? v : null
  } catch {
    // Private browsing / storage blocked -- fall back to OS preference only.
    return null
  }
}

const stored = readStored()
export const isDark = ref(stored ? stored === 'dark' : systemPrefersDark())

function applyTheme() {
  document.documentElement.setAttribute('data-theme', isDark.value ? 'dark' : 'light')
}
applyTheme()

export function toggleTheme() {
  isDark.value = !isDark.value
  try {
    localStorage.setItem(STORAGE_KEY, isDark.value ? 'dark' : 'light')
  } catch {
    // ignore -- nothing to persist to, the in-memory toggle still works
  }
  applyTheme()
}
