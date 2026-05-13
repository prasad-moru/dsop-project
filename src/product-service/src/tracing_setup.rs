use opentelemetry::global;
use opentelemetry::sdk::propagation::TraceContextPropagator;
use opentelemetry_datadog::new_pipeline;
use std::env;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt, EnvFilter};

pub fn init_tracing() {
    let dd_agent_host = env::var("DD_AGENT_HOST")
        .unwrap_or_else(|_| "localhost".to_string());
    let dd_service = env::var("DD_SERVICE")
        .unwrap_or_else(|_| "product-service".to_string());
    let dd_env = env::var("DD_ENV")
        .unwrap_or_else(|_| "production".to_string());
    let dd_version = env::var("DD_VERSION")
        .unwrap_or_else(|_| "0.1.0".to_string());

    let agent_endpoint = format!("http://{}:8126", dd_agent_host);

    global::set_text_map_propagator(TraceContextPropagator::new());

    let tracer = new_pipeline()
        .with_service_name(&dd_service)
        .with_agent_endpoint(&agent_endpoint)
        .with_api_version(opentelemetry_datadog::ApiVersion::Version05)
        .with_trace_config(
            opentelemetry::sdk::trace::config().with_resource(
                opentelemetry::sdk::Resource::new(vec![
                    opentelemetry::KeyValue::new("service.name", dd_service.clone()),
                    opentelemetry::KeyValue::new("env", dd_env.clone()),
                    opentelemetry::KeyValue::new("version", dd_version.clone()),
                ])
            )
        )
        .install_batch(opentelemetry::runtime::Tokio)
        .expect("Failed to initialize Datadog tracer");

    let telemetry_layer = tracing_opentelemetry::layer().with_tracer(tracer);

    // JSON stdout layer — Filebeat/ELK picks this up.
    // DD_LOGS_INJECTION=true means Datadog agent correlates these
    // logs with APM traces via dd.trace_id / dd.span_id fields.
    let fmt_layer = tracing_subscriber::fmt::layer()
        .json()
        .with_current_span(true)
        .with_span_list(false)
        .with_target(true)
        .with_thread_ids(false)
        .with_thread_names(false);

    tracing_subscriber::registry()
        .with(
            EnvFilter::from_default_env()
                .add_directive(tracing::Level::INFO.into()),
        )
        .with(telemetry_layer)
        .with(fmt_layer)
        .init();
}