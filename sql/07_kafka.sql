USE shop;

DROP VIEW IF EXISTS orders_queue_mv SYNC;
DROP VIEW IF EXISTS orders_queue_errors_mv SYNC;
DROP TABLE IF EXISTS orders_queue SYNC;
DROP TABLE IF EXISTS orders_queue_errors SYNC;

CREATE TABLE orders_queue
(
    order_id    UInt32,
    customer_id UInt32,
    product_id  UInt16,
    city        LowCardinality(String),
    status      Enum8('delivered' = 1, 'cancelled' = 2, 'returned' = 3),
    quantity    UInt8,
    unit_price  UInt32,
    created_at  DateTime
)
ENGINE = Kafka
SETTINGS kafka_broker_list = 'kafka:9092',
         kafka_topic_list = 'orders',
         kafka_group_name = 'clickhouse_orders',
         kafka_format = 'JSONEachRow',
         kafka_handle_error_mode = 'stream';

CREATE MATERIALIZED VIEW orders_queue_mv TO orders AS
SELECT order_id, customer_id, product_id, city, status, quantity, unit_price, created_at
FROM orders_queue
WHERE length(_error) = 0;

CREATE TABLE orders_queue_errors
(
    `_error`       String,
    `_raw_message` String,
    `topic`        LowCardinality(String),
    `partition`    UInt64,
    `offset`       UInt64
)
ENGINE = MergeTree
ORDER BY (`topic`, `partition`, `offset`);

CREATE MATERIALIZED VIEW orders_queue_errors_mv TO orders_queue_errors AS
SELECT _error, _raw_message, _topic AS `topic`, _partition AS `partition`, _offset AS `offset`
FROM orders_queue
WHERE length(_error) > 0;
