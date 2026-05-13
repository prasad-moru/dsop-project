<template>
  <TopNav />
  <RouterView />
</template>

<script setup lang="ts">
import { onMounted } from 'vue'
import { RouterView } from 'vue-router'
import { useProductStore } from '@/stores'
import type { Product } from '@/types'
import TopNav from './components/TopNav.vue'
import { trackCustomAction, trackError, addTiming } from './datadog-rum'

const productStore = useProductStore()

onMounted(() => {
  if (productStore.count === 0) {
    const startTime = performance.now()
    console.log('Fetching products')

    fetch('/api/products')
      .then((response) => response.json())
      .then((data: Product[]) => {
        productStore.addProducts(data)
        console.log(`Fetched ${data.length} products`)

        const duration = performance.now() - startTime
        trackCustomAction('products_loaded', {
          count: data.length,
          duration_ms: Math.round(duration),
        })
        addTiming('products_loaded')
      })
      .catch((error: Error) => {
        console.log(error)
        trackError(error, { action: 'get_products' })
        alert('Error occurred while fetching products')
      })
  }
})
</script>

<style scoped></style>