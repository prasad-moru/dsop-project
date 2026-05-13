import { datadogRum } from '@datadog/browser-rum'

export function initDatadogRUM(): void {
  const isRumEnabled = import.meta.env.VITE_DATADOG_RUM_ENABLED === 'true'

  if (!isRumEnabled) {
    console.log('Datadog RUM is disabled')
    return
  }

  const applicationId = import.meta.env.VITE_DATADOG_RUM_APPLICATION_ID as string
  const clientToken = import.meta.env.VITE_DATADOG_RUM_CLIENT_TOKEN as string
  const site = (import.meta.env.VITE_DATADOG_SITE as string) || 'us5.datadoghq.com'
  const service = (import.meta.env.VITE_DATADOG_SERVICE as string) || 'store-front'
  const env = (import.meta.env.VITE_DATADOG_ENV as string) || 'production'
  const version = (import.meta.env.VITE_APP_VERSION as string) || '1.0.0'

  if (!applicationId || !clientToken) {
    console.error('Datadog RUM: Missing required configuration (Application ID or Client Token)')
    return
  }

  datadogRum.init({
    applicationId,
    clientToken,
    site,
    service,
    env,
    version,
    sessionSampleRate: 100,
    sessionReplaySampleRate: 20,
    trackUserInteractions: true,
    trackResources: true,
    trackLongTasks: true,
    defaultPrivacyLevel: 'mask-user-input',
    forwardErrorsToLogs: true,
    forwardConsoleLogs: ['error', 'warn'],
    trackViewsManually: false,
    allowedTracingUrls: [
      { match: /^https:\/\/www\.devopsproduction\.com\/api\/orders/, propagatorTypes: ['tracecontext'] },
      { match: /^https:\/\/www\.devopsproduction\.com\/api\/products/, propagatorTypes: ['tracecontext'] },
    ],
    beforeSend: (event) => {
      if (event.type === 'resource' && event.resource.url.includes('sensitive')) {
        return false
      }
      return true
    },
  })

  datadogRum.setGlobalContextProperty('app_type', 'customer_portal')
  datadogRum.setGlobalContextProperty('deployment_type', 'kubernetes')
  datadogRum.startSessionReplayRecording()

  console.log(`Datadog RUM initialized for ${service} in ${env}`)
}

export function trackCustomAction(
  actionName: string,
  actionContext: Record<string, unknown> = {},
): void {
  datadogRum.addAction(actionName, actionContext)
}

export function trackError(
  error: Error | string,
  errorContext: Record<string, unknown> = {},
): void {
  datadogRum.addError(error, errorContext)
}

export function setUser(userInfo: { id: string; name?: string; email?: string }): void {
  if (userInfo) {
    datadogRum.setUser({
      id: userInfo.id,
      name: userInfo.name,
      email: userInfo.email,
    })
  }
}

export function addTiming(name: string): void {
  datadogRum.addTiming(name)
}