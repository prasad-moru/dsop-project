import { createApp } from 'vue'
import { createPinia } from 'pinia'
import './assets/styles.scss'

import App from './App.vue'
import router from './router'
import { initDatadogRUM, trackCustomAction } from './datadog-rum'

// Initialize Datadog RUM before mounting the app
initDatadogRUM()

const app = createApp(App)

app.use(createPinia())
app.use(router)

// Track route changes via vue-router
router.afterEach((to, from) => {
  trackCustomAction('route_change', {
    from: from.path,
    to: to.path,
    name: String(to.name ?? ''),
  })
})

app.mount('#app')