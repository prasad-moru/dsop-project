'use strict'

module.exports = async function (fastify, opts) {
  fastify.post('/', async function (request, reply) {
    const msg = request.body

    // Datadog APM — business context tags on the active HTTP request span
    const tracer = require('dd-trace')
    const span = tracer.scope().active()
    if (span && msg) {
      if (msg.customerId) span.setTag('order.customer_id', msg.customerId)
      if (msg.items && Array.isArray(msg.items)) {
        span.setTag('order.item_count', msg.items.length)
        const total = msg.items.reduce((sum, i) => sum + ((i.price || 0) * (i.quantity || 1)), 0)
        span.setTag('order.total_value', parseFloat(total.toFixed(2)))
      }
    }

    fastify.sendMessage(Buffer.from(JSON.stringify(msg)))
    reply.code(201)
  })

  fastify.get('/health', async function (request, reply) {
    const appVersion = process.env.APP_VERSION || '0.1.0'
    return { status: 'ok', version: appVersion }
  })

  fastify.get('/hugs', async function (request, reply) {
    return { hugs: fastify.someSupport() }
  })
}
