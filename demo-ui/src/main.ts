import { createApp } from 'vue'
import { createVuetify } from 'vuetify'
import { aliases, mdi } from 'vuetify/iconsets/mdi-svg'
import 'vuetify/styles'
import App from './App.vue'
import './styles.css'

// Persisted theme preference (mirrors the data-theme attr that drives our CSS vars).
let initialTheme = 'claudeDark'
try {
  const saved = localStorage.getItem('a2a-theme')
  if (saved === 'claudeLight' || saved === 'claudeDark') initialTheme = saved
} catch {
  /* localStorage unavailable */
}
document.documentElement.setAttribute('data-theme', initialTheme === 'claudeLight' ? 'light' : 'dark')

const vuetify = createVuetify({
  theme: {
    defaultTheme: initialTheme,
    themes: {
      claudeDark: {
        dark: true,
        colors: {
          background: '#0e1117',
          surface: '#161b22',
          'surface-bright': '#1c2330',
          primary: '#d97757', // Claude terracotta
          secondary: '#6ea8fe',
          error: '#f85149',
          success: '#3fb950',
          warning: '#d29922',
          info: '#6ea8fe',
        },
      },
      claudeLight: {
        dark: false,
        colors: {
          background: '#ffffff',
          surface: '#f6f8fa',
          'surface-bright': '#eceff3',
          primary: '#c75b39', // Claude terracotta, deepened for light bg
          secondary: '#0969da',
          error: '#cf222e',
          success: '#1a7f37',
          warning: '#9a6700',
          info: '#0969da',
        },
      },
    },
  },
  // tree-shaken MDI SVG icons (only the handful Vuetify components reference)
  icons: { defaultSet: 'mdi', aliases, sets: { mdi } },
  defaults: {
    VExpansionPanel: { elevation: 0 },
    VChip: { size: 'small' },
  },
})

createApp(App).use(vuetify).mount('#app')
