use opentelemetry::{global, trace::Span, trace::Tracer, KeyValue};
use opentelemetry_otlp::WithExportConfig;
use opentelemetry_sdk::{
    trace::{Config, TracerProvider},
    Resource,
};
use rand::Rng;
use serde::Serialize;
use std::env;
use std::thread;
use std::time::{Duration, Instant};

// Initialize OpenTelemetry tracer that exports to Datadog Agent OTLP receiver
// The agent converts OTLP spans to Datadog format and forwards to Datadog backend
fn init_tracer() -> TracerProvider {
    let otlp_endpoint = env::var("OTEL_EXPORTER_OTLP_ENDPOINT")
        .unwrap_or_else(|_| "http://localhost:4318".to_string());

    let exporter = opentelemetry_otlp::new_exporter()
        .http()
        .with_endpoint(otlp_endpoint)
        .build_span_exporter()
        .expect("failed to build OTLP span exporter");

    // opentelemetry_sdk 0.24: with_resource() lives inside Config, NOT on Builder directly
    let resource = Resource::new(vec![
        KeyValue::new(
            "service.name",
            env::var("DD_SERVICE").unwrap_or_else(|_| "virtual-customer".to_string()),
        ),
        KeyValue::new(
            "deployment.environment",
            env::var("DD_ENV").unwrap_or_else(|_| "production".to_string()),
        ),
        KeyValue::new(
            "service.version",
            env::var("DD_VERSION").unwrap_or_else(|_| "1.0.0".to_string()),
        ),
    ]);

    let provider = TracerProvider::builder()
        .with_simple_exporter(exporter)
        .with_config(Config::default().with_resource(resource))
        .build();

    global::set_tracer_provider(provider.clone());
    provider
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let _provider = init_tracer();

    let order_service_url =
        env::var("ORDER_SERVICE_URL").unwrap_or_else(|_| "http://localhost:3000".to_string());

    let orders_per_hour: u64 = env::var("ORDERS_PER_HOUR")
        .unwrap_or_else(|_| "1".to_string())
        .parse()
        .unwrap_or(1);

    if orders_per_hour == 0 {
        println!("Please set the ORDERS_PER_HOUR environment variable");
        std::process::exit(1);
    }

    println!("Orders to submit per hour: {}", orders_per_hour);

    let order_submission_interval: f64 = (60.0 / orders_per_hour as f64) * 60.0;
    println!("Order submission interval: {} seconds", order_submission_interval);

    let sleep_duration = Duration::from_secs_f64(order_submission_interval);
    println!("Sleep duration between orders: {:?}", sleep_duration);

    let mut order_counter = 0;
    let start_time = Instant::now();

    let client = reqwest::blocking::Client::new();
    let tracer = global::tracer("virtual-customer");

    loop {
        order_counter += 1;

        let customer_id = (rand::thread_rng().gen_range(1000000000..2147483647)).to_string();
        let number_of_items = rand::thread_rng().gen_range(1..5);

        let items: Vec<Item> = (0..number_of_items)
            .map(|_| Item {
                product_id: rand::thread_rng().gen_range(1..10),
                quantity: rand::thread_rng().gen_range(1..5),
                price: rand::thread_rng().gen_range(1.0..100.0),
            })
            .collect();

        let order = Order { customer_id: customer_id.clone(), items };
        let serialized_order = serde_json::to_string(&order)?;

        let mut span = tracer.start("order.submit");
        span.set_attribute(KeyValue::new("order.customer_id", customer_id.clone()));
        span.set_attribute(KeyValue::new("order.item_count", number_of_items as i64));
        span.set_attribute(KeyValue::new("order.counter", order_counter as i64));
        span.set_attribute(KeyValue::new("http.request.method", "POST"));
        span.set_attribute(KeyValue::new("url.full", order_service_url.clone()));

        let response = client
            .post(order_service_url.clone())
            .header("Content-Type", "application/json")
            .body(serialized_order.clone())
            .send();

        match response {
            Ok(res) => {
                let status = res.status();
                span.set_attribute(KeyValue::new(
                    "http.response.status_code",
                    status.as_u16() as i64,
                ));
                println!(
                    "Order {} sent at {:.2?} with status of {}. {}",
                    order_counter,
                    start_time.elapsed(),
                    status,
                    serialized_order
                );
            }
            Err(err) => {
                span.set_attribute(KeyValue::new("error", true));
                span.set_attribute(KeyValue::new("error.message", err.to_string()));
                println!("Failed to submit order: {}", err);
            }
        }

        drop(span);
        thread::sleep(sleep_duration);
    }
}

#[derive(Serialize, Debug)]
struct Order {
    #[serde(rename = "customerId")]
    customer_id: String,
    items: Vec<Item>,
}

#[derive(Serialize, Debug)]
struct Item {
    #[serde(rename = "productId")]
    product_id: u32,
    quantity: u32,
    price: f32,
}
