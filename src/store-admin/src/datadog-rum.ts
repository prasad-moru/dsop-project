import { datadogRum } from '@datadog/browser-rum'

export function initDatadogRUM(): void {
  const isRumEnabled = import.meta.env.VITE_DATADOG_RUM_ENABLED === 'true'

  if (!isRumEnabled) {
    console.log('Datadog RUM is disabled')
    return
  }

  const applicationId = import.meta.env.VITE_DATADOG_RUM_APPLICATION_ID
  const clientToken = import.meta.env.VITE_DATADOG_RUM_CLIENT_TOKEN
  const site = import.meta.env.VITE_DATADOG_SITE || 'us5.datadoghq.com'
  const service = import.meta.env.VITE_DATADOG_SERVICE || 'store-admin'
  const env = import.meta.env.VITE_DATADOG_ENV || 'production'
  const version = import.meta.env.VITE_APP_VERSION || '1.0.0'

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
    sessionReplaySampleRate: 100,
    trackUserInteractions: true,
    trackResources: true,
    trackLongTasks: true,
    defaultPrivacyLevel: 'mask-user-input',
    trackViewsManually: false,
    allowedTracingUrls: [
      { match: /^https:\/\/admin\.devopsproduction\.com\/api\//, propagatorTypes: ['tracecontext'] },
      { match: /^https:\/\/admin\.devopsproduction\.com\/api\/makeline\//, propagatorTypes: ['tracecontext'] },
      { match: /^https:\/\/admin\.devopsproduction\.com\/api\/products/, propagatorTypes: ['tracecontext'] },
      { match: /^https:\/\/admin\.devopsproduction\.com\/api\/ai\//, propagatorTypes: ['tracecontext'] },
      { match: /^https:\/\/admin\.devopsproduction\.com\/api\/order/, propagatorTypes: ['tracecontext'] },
    ],
    beforeSend: (event) => {
      if (event.type === 'resource' && event.resource.url.includes('sensitive')) {
        return false;
      }
      return true;
    }
  })

  datadogRum.setGlobalContextProperty('app_type', 'admin_portal')
  datadogRum.setGlobalContextProperty('deployment_type', 'kubernetes')

  datadogRum.startSessionReplayRecording()

  console.log(`Datadog RUM initialized for ${service} in ${env}`)
}

export function trackCustomAction(actionName: string, actionContext: Record<string, unknown> = {}): void {
  datadogRum.addAction(actionName, actionContext)
}

export function trackError(error: Error | unknown, errorContext: Record<string, unknown> = {}): void {
  datadogRum.addError(error, errorContext)
}

export function setUser(userInfo: { id?: string; name?: string; email?: string }): void {
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