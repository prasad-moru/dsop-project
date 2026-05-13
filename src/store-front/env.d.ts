/// <reference types="vite/client" />

interface ImportMetaEnv {
  // Datadog RUM Configuration
  readonly VITE_DATADOG_RUM_ENABLED: string
  readonly VITE_DATADOG_RUM_APPLICATION_ID: string
  readonly VITE_DATADOG_RUM_CLIENT_TOKEN: string
  readonly VITE_DATADOG_SITE: string
  readonly VITE_DATADOG_SERVICE: string
  readonly VITE_DATADOG_ENV: string
  readonly VITE_APP_VERSION: string

  // Backend Service URLs
  readonly VITE_ORDER_SERVICE_URL: string
  readonly VITE_PRODUCT_SERVICE_URL: string
}

interface ImportMeta {
  readonly env: ImportMetaEnv
}