import { createApp } from 'vue'
import { createPinia } from 'pinia'
import './assets/styles.scss'

import App from './App.vue'
import router from './router'
import { initDatadogRUM } from './datadog-rum'

// Initialize Datadog RUM before creating the app
initDatadogRUM()

const app = createApp(App)

app.use(createPinia())
app.use(router)

// Track route changes
router.afterEach((to, from) => {
  if (window.DD_RUM) {
    ;(window.DD_RUM as Record<string, unknown> & { addAction: (name: string, ctx: object) => void }).addAction(
      'route_change',
      { from: from.path, to: to.path, name: to.name },
    )
  }
})

app.mount('#app')