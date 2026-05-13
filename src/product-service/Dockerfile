FROM rust:1.88 AS builder

RUN USER=root cargo new --bin product-service

WORKDIR /product-service

ADD . ./

RUN cargo build --release

FROM debian:bookworm-slim AS runner
WORKDIR /app

ARG APP_VERSION=0.1.0

RUN apt-get update && apt-get install -y wget libssl-dev && rm -rf /var/lib/apt/lists/*

COPY --from=builder /product-service/target/release/product-service /app

ENV APP_VERSION=$APP_VERSION

CMD ["./product-service"]