CREATE DATABASE IF NOT EXISTS shop;
USE shop;

DROP TABLE IF EXISTS orders SYNC;
DROP TABLE IF EXISTS orders_naive SYNC;

CREATE TABLE orders
(
    order_id    UInt32 CODEC(T64, ZSTD(1)),
    customer_id UInt32 CODEC(T64, ZSTD(1)),
    product_id  UInt16,
    city        LowCardinality(String),
    status      Enum8('delivered' = 1, 'cancelled' = 2, 'returned' = 3),
    quantity    UInt8,
    unit_price  UInt32 CODEC(T64, ZSTD(1)),
    created_at  DateTime CODEC(Delta, ZSTD(1))
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(created_at)
ORDER BY (city, created_at);

CREATE TABLE orders_naive
(
    order_id    String,
    customer_id String,
    product_id  String,
    city        String,
    status      String,
    quantity    String,
    unit_price  String,
    created_at  String
)
ENGINE = MergeTree
ORDER BY tuple();
