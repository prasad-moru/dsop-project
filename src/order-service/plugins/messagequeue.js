'use strict'

const fp = require('fastify-plugin')

module.exports = fp(async function (fastify, opts) {
  fastify.decorate('sendMessage', function (message) {
    const body = message.toString()

    // Get the tracer and capture the currently active span BEFORE async operations
    // The active span is the HTTP request span created by dd-trace auto-instrumentation
    // We capture it here so we can pass it as parent to the custom publish span
    const tracer = require('dd-trace')
    const activeSpan = tracer.scope().active()

    if (process.env.ORDER_QUEUE_USERNAME && process.env.ORDER_QUEUE_PASSWORD) {
      console.log(`sending message to ${process.env.ORDER_QUEUE_NAME} on ${process.env.ORDER_QUEUE_HOSTNAME} using local auth credentials`)

      const rhea = require('rhea')
      const container = rhea.create_container()
      var amqp_message = container.message

      const connectOptions = {
        hostname: process.env.ORDER_QUEUE_HOSTNAME,
        host: process.env.ORDER_QUEUE_HOSTNAME,
        port: process.env.ORDER_QUEUE_PORT,
        username: process.env.ORDER_QUEUE_USERNAME,
        password: process.env.ORDER_QUEUE_PASSWORD,
        reconnect_limit: process.env.ORDER_QUEUE_RECONNECT_LIMIT || 0
      }

      if (process.env.ORDER_QUEUE_TRANSPORT !== undefined) {
        connectOptions.transport = process.env.ORDER_QUEUE_TRANSPORT
      }

      // Create a custom child span for the RabbitMQ publish operation
      // This appears as a separate span under the HTTP request in the Datadog trace view
      // Tags follow OpenTelemetry messaging semantic conventions that Datadog understands
      const publishSpan = tracer.startSpan('rabbitmq.publish', {
        childOf: activeSpan,
        tags: {
          'span.kind': 'producer',
          'messaging.system': 'rabbitmq',
          'messaging.destination': process.env.ORDER_QUEUE_NAME,
          'messaging.destination_kind': 'queue',
          'messaging.protocol': 'AMQP',
          'messaging.protocol_version': '1.0',
          'messaging.url': `amqp://${process.env.ORDER_QUEUE_HOSTNAME}:${process.env.ORDER_QUEUE_PORT}`,
          'out.host': process.env.ORDER_QUEUE_HOSTNAME,
          'out.port': parseInt(process.env.ORDER_QUEUE_PORT) || 5672
        }
      })

      const connection = container.connect(connectOptions)

      container.once('sendable', function (context) {
        const sender = context.sender

        // Manually inject the publish span's trace context into AMQP message properties
        // The consumer service (makeline-service) reads these properties to extract
        // the trace context and continue the distributed trace as a child span
        // This connects order-service → RabbitMQ → makeline-service into one trace
        const traceHeaders = {}
        tracer.inject(publishSpan.context(), 'text_map', traceHeaders)

        try {
          sender.send({
            body: amqp_message.data_section(Buffer.from(body, 'utf8')),
            application_properties: traceHeaders   // carries x-datadog-trace-id, x-datadog-parent-id
          })

          // Tag the span with message size for visibility in Datadog
          publishSpan.setTag('messaging.message_payload_size_bytes', Buffer.byteLength(body, 'utf8'))
          publishSpan.finish()

        } catch (err) {
          publishSpan.setTag('error', true)
          publishSpan.setTag('error.type', err.constructor.name)
          publishSpan.setTag('error.message', err.message)
          publishSpan.setTag('error.stack', err.stack)
          publishSpan.finish()
        }

        sender.close()
        connection.close()
      })

      // Finish the span with error tag if the connection itself fails
      container.on('error', function (err) {
        publishSpan.setTag('error', true)
        publishSpan.setTag('error.type', err.constructor.name)
        publishSpan.setTag('error.message', err.message)
        publishSpan.setTag('error.stack', err.stack)
        publishSpan.finish()
      })

      connection.open_sender(process.env.ORDER_QUEUE_NAME)

    } else if (process.env.USE_WORKLOAD_IDENTITY_AUTH === 'true') {
      const { ServiceBusClient } = require('@azure/service-bus')
      const { DefaultAzureCredential } = require('@azure/identity')

      const fullyQualifiedNamespace = process.env.ORDER_QUEUE_HOSTNAME || process.env.AZURE_SERVICEBUS_FULLYQUALIFIEDNAMESPACE

      console.log(`sending message to ${process.env.ORDER_QUEUE_NAME} on ${fullyQualifiedNamespace} using Microsoft Entra ID Workload Identity credentials`)

      if (!fullyQualifiedNamespace) {
        console.log('no hostname set for message queue. exiting.')
        return
      }

      const queueName = process.env.ORDER_QUEUE_NAME
      const credential = new DefaultAzureCredential()

      // Custom child span for Azure Service Bus publish
      const publishSpan = tracer.startSpan('servicebus.publish', {
        childOf: activeSpan,
        tags: {
          'span.kind': 'producer',
          'messaging.system': 'azure_service_bus',
          'messaging.destination': queueName,
          'messaging.destination_kind': 'queue',
          'out.host': fullyQualifiedNamespace
        }
      })

      // Inject trace context into Service Bus message applicationProperties
      // so the consumer can extract and continue the trace
      const traceHeaders = {}
      tracer.inject(publishSpan.context(), 'text_map', traceHeaders)

      async function sendMessage() {
        const sbClient = new ServiceBusClient(fullyQualifiedNamespace, credential)
        const sender = sbClient.createSender(queueName)

        try {
          await sender.sendMessages({
            body: body,
            applicationProperties: traceHeaders
          })

          publishSpan.setTag('messaging.message_payload_size_bytes', Buffer.byteLength(body, 'utf8'))
          publishSpan.finish()

        } catch (err) {
          publishSpan.setTag('error', true)
          publishSpan.setTag('error.type', err.constructor.name)
          publishSpan.setTag('error.message', err.message)
          publishSpan.setTag('error.stack', err.stack)
          publishSpan.finish()
          throw err
        } finally {
          await sender.close()
          await sbClient.close()
        }
      }

      sendMessage().catch(console.error)

    } else {
      console.log('no credentials set for message queue. exiting.')
      return
    }
  })
})