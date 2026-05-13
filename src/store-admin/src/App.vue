<template>
  <TopNav />
  <router-view />
</template>

<script setup lang="ts">
import { onMounted } from 'vue'
import { useProductStore, useOrderStore } from '@/stores'
import type { Product, Order } from '@/types'
import TopNav from './components/TopNav.vue'
import { trackCustomAction, trackError, addTiming } from './datadog-rum'

const productStore = useProductStore()
const orderStore = useOrderStore()

onMounted(() => {
  if (productStore.count === 0) {
    const startTime = performance.now()
    fetch('/api/products')
      .then((response) => response.json())
      .then((data: Product[]) => {
        productStore.addProducts(data)
        const duration = performance.now() - startTime
        trackCustomAction('products_loaded', {
          count: data.length,
          duration_ms: Math.round(duration),
        })
        addTiming('products_loaded')
      })
      .catch((error) => {
        trackError(error, { action: 'get_products' })
        alert('Error occurred while fetching products')
      })
  }

  if (orderStore.count === 0) {
    const startTime = performance.now()
    fetch('/api/makeline/order/fetch')
      .then((response) => response.json())
      .then((data: Order[]) => {
        orderStore.addOrders(data)
        const duration = performance.now() - startTime
        trackCustomAction('orders_fetched', {
          count: data.length,
          duration_ms: Math.round(duration),
        })
      })
      .catch((error) => {
        orderStore.initialized = true
        trackError(error, { action: 'fetch_orders' })
        console.error(`Error occurred while fetching orders`, error)
      })
  }
})
</script>