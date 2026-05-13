use opentelemetry::global;
use product_service::{configuration::Settings, startup::run};

mod tracing_setup;

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    let settings = Settings::new().set_wasm_rules_engine(false);

    tracing_setup::init_tracing();

    // Run the server and capture result before shutdown
    let result = run(settings)?.await;

    // Flush all in-flight spans to the Datadog agent on port 8126
    // before the process exits. Without this, the last batch of
    // spans is dropped and never appears in Datadog APM.
    global::shutdown_tracer_provider();

    result
}