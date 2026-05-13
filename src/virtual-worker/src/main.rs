use opentelemetry::{global, trace::Span, trace::Tracer, KeyValue};
use opentelemetry_otlp::WithExportConfig;
use opentelemetry_sdk::{
    trace::{Config, TracerProvider},
    Resource,
};
use serde::{Deserialize, Serialize};
use std::env;
use std::thread;
use std::time::{Duration, Instant};

fn init_tracer() -> TracerProvider {
    let otlp_endpoint = env::var("OTEL_EXPORTER_OTLP_ENDPOINT")
        .unwrap_or_else(|_| "http://localhost:4318".to_string());

    // Fix 1: new_exporter().http() — SpanExporter::builder() removed in 0.17
    let exporter = opentelemetry_otlp::new_exporter()
        .http()
        .with_endpoint(otlp_endpoint)
        .build_span_exporter()
        .expect("failed to build OTLP span exporter");

    let resource = Resource::new(vec![
        KeyValue::new(
            "service.name",
            env::var("DD_SERVICE").unwrap_or_else(|_| "virtual-worker".to_string()),
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

    // Fix 2: TracerProvider not SdkTracerProvider
    // Fix 3: with_resource lives inside Config, not directly on Builder
    let provider = TracerProvider::builder()
        .with_simple_exporter(exporter)
        .with_config(Config::default().with_resource(resource))
        .build();

    global::set_tracer_provider(provider.clone());
    provider
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let _provider = init_tracer();

    let client = reqwest::blocking::Client::new();
    let tracer = global::tracer("virtual-worker");

    let order_service_url = env::var("MAKELINE_SERVICE_URL")
        .unwrap_or_else(|_| "http://localhost:3001".to_string());

    let orders_per_hour: u64 = env::var("ORDERS_PER_HOUR")
        .unwrap_or_else(|_| "0".to_string())
        .parse()
        .unwrap_or(0);

    if orders_per_hour > 0 {
        println!("Orders to process per hour: {}", orders_per_hour);

        let order_processing_interval: f64 = (60.0 / orders_per_hour as f64) * 60.0;
        println!("Order processing interval: {} seconds", order_processing_interval);

        let sleep_duration = Duration::from_secs_f64(order_processing_interval);
        println!("Sleep duration between orders: {:?}", sleep_duration);

        loop {
            let mut cycle_span = tracer.start("orders.poll_and_process");
            cycle_span.set_attribute(KeyValue::new("makeline.url", order_service_url.clone()));

            let orders = get_orders(&client, &order_service_url, &tracer)?;

            if orders.len() > 0 {
                println!("Processing orders");
                cycle_span.set_attribute(KeyValue::new("orders.fetched", orders.len() as i64));
                process_orders(&client, orders, &order_service_url, &tracer)?;
                println!("Order processing complete");
            } else {
                println!("No orders to process");
                cycle_span.set_attribute(KeyValue::new("orders.fetched", 0i64));
            }

            drop(cycle_span);
            thread::sleep(sleep_duration);
        }
    } else {
        println!("Processing orders");

        let mut span = tracer.start("orders.process_all");
        span.set_attribute(KeyValue::new("makeline.url", order_service_url.clone()));

        let orders = get_orders(&client, &order_service_url, &tracer)?;
        span.set_attribute(KeyValue::new("orders.fetched", orders.len() as i64));

        process_orders(&client, orders, &order_service_url, &tracer)?;

        println!("Order processing complete");
        drop(span);

        std::process::exit(0);
    }
}

#[derive(Debug, Deserialize, Serialize)]
struct Order {
    #[serde(rename = "orderId")]
    order_id: String,
    #[serde(rename = "customerId")]
    customer_id: String,
    items: Vec<Item>,
    status: u32,
}

#[derive(Debug, Deserialize, Serialize)]
struct Item {
    #[serde(rename = "productId")]
    product_id: u32,
    quantity: u32,
    price: f32,
}

#[derive(Debug, Deserialize, Serialize)]
enum OrderStatus {
    Pending = 0,
    Processing,
    Complete,
}

fn get_orders(
    client: &reqwest::blocking::Client,
    url: &str,
    tracer: &impl Tracer,
) -> Result<Vec<Order>, Box<dyn std::error::Error>> {
    let mut span = tracer.start("orders.fetch");
    span.set_attribute(KeyValue::new("http.request.method", "GET"));
    span.set_attribute(KeyValue::new("url.full", format!("{}/order/fetch", url)));

    let response = client.get(format!("{}/order/fetch", url)).send();

    match response {
        Ok(res) => {
            let status = res.status();
            span.set_attribute(KeyValue::new(
                "http.response.status_code",
                status.as_u16() as i64,
            ));

            let res = match res.error_for_status() {
                Ok(r) => r,
                Err(e) => {
                    span.set_attribute(KeyValue::new("error", true));
                    span.set_attribute(KeyValue::new("error.message", e.to_string()));
                    drop(span);
                    return Ok(vec![]);
                }
            };

            let json = res.text()?;

            if json.trim().is_empty() || json.trim() == "null" {
                println!("No orders to process");
                span.set_attribute(KeyValue::new("orders.count", 0i64));
                drop(span);
                return Ok(vec![]);
            }

            let orders: Vec<Order> = match serde_json::from_str(&json) {
                Ok(orders) => orders,
                Err(e) => {
                    println!("Failed to parse JSON: {}", e);
                    span.set_attribute(KeyValue::new("error", true));
                    span.set_attribute(KeyValue::new("error.message", e.to_string()));
                    drop(span);
                    return Ok(vec![]);
                }
            };

            span.set_attribute(KeyValue::new("orders.count", orders.len() as i64));
            drop(span);
            Ok(orders)
        }
        Err(e) => {
            println!("Failed to fetch orders: {}", e);
            span.set_attribute(KeyValue::new("error", true));
            span.set_attribute(KeyValue::new("error.message", e.to_string()));
            drop(span);
            Ok(vec![])
        }
    }
}

fn process_orders(
    client: &reqwest::blocking::Client,
    orders: Vec<Order>,
    url: &str,
    tracer: &impl Tracer,
) -> Result<(), Box<dyn std::error::Error>> {
    let start_time = Instant::now();

    for mut order in orders {
        order.status = OrderStatus::Processing as u32;

        let serialized_order = serde_json::to_string(&order)?;

        let mut span = tracer.start("order.update");
        span.set_attribute(KeyValue::new("order.id", order.order_id.clone()));
        span.set_attribute(KeyValue::new("order.customer_id", order.customer_id.clone()));
        span.set_attribute(KeyValue::new("order.status", order.status as i64));
        span.set_attribute(KeyValue::new("order.item_count", order.items.len() as i64));
        span.set_attribute(KeyValue::new("http.request.method", "PUT"));
        span.set_attribute(KeyValue::new("url.full", format!("{}/order", url)));

        let response = client
            .put(format!("{}/order", url))
            .header("Content-Type", "application/json")
            .body(serialized_order.clone())
            .send();

        match response {
            Ok(res) => {
                span.set_attribute(KeyValue::new(
                    "http.response.status_code",
                    res.status().as_u16() as i64,
                ));
                let elapsed_time = start_time.elapsed();
                println!(
                    "Order {} processed at {:.2?} with status of {}. {}",
                    order.order_id, elapsed_time, order.status, serialized_order
                );
            }
            Err(err) => {
                span.set_attribute(KeyValue::new("error", true));
                span.set_attribute(KeyValue::new("error.message", err.to_string()));
                println!("Error completing the order: {}", err);
            }
        }

        drop(span);
    }

    Ok(())
}