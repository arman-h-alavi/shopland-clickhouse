USE shop;

-- ===== 1. Baseline: support query, 5 runs (results discarded, metrics read from query_log) =====
-- Reference text of the query:
--   SELECT order_id, product_id, status, quantity * unit_price AS amount, created_at
--   FROM shop.orders WHERE customer_id = 4321 ORDER BY created_at DESC;
SELECT order_id, product_id, status, quantity * unit_price AS amount, created_at FROM shop.orders WHERE customer_id = 4321 ORDER BY created_at DESC SETTINGS log_comment = 'q6_before' FORMAT Null;
SELECT order_id, product_id, status, quantity * unit_price AS amount, created_at FROM shop.orders WHERE customer_id = 4321 ORDER BY created_at DESC SETTINGS log_comment = 'q6_before' FORMAT Null;
SELECT order_id, product_id, status, quantity * unit_price AS amount, created_at FROM shop.orders WHERE customer_id = 4321 ORDER BY created_at DESC SETTINGS log_comment = 'q6_before' FORMAT Null;
SELECT order_id, product_id, status, quantity * unit_price AS amount, created_at FROM shop.orders WHERE customer_id = 4321 ORDER BY created_at DESC SETTINGS log_comment = 'q6_before' FORMAT Null;
SELECT order_id, product_id, status, quantity * unit_price AS amount, created_at FROM shop.orders WHERE customer_id = 4321 ORDER BY created_at DESC SETTINGS log_comment = 'q6_before' FORMAT Null;

SELECT count() AS rows_for_customer_4321 FROM shop.orders WHERE customer_id = 4321;

-- ===== 2. Index usage before =====
EXPLAIN indexes = 1
SELECT order_id, product_id, status, quantity * unit_price AS amount, created_at
FROM shop.orders WHERE customer_id = 4321 ORDER BY created_at DESC;

-- ===== 3. Optimization: second table sorted by customer, filled by a materialized view =====
DROP VIEW IF EXISTS orders_by_customer_mv SYNC;
DROP TABLE IF EXISTS orders_by_customer SYNC;
CREATE TABLE orders_by_customer
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
ORDER BY (customer_id, created_at);

CREATE MATERIALIZED VIEW orders_by_customer_mv TO orders_by_customer AS
SELECT * FROM orders;

-- Backfill: the view only sees rows inserted after it was created
INSERT INTO orders_by_customer SELECT * FROM orders;
OPTIMIZE TABLE orders_by_customer FINAL;

SELECT table, count() AS active_parts, sum(rows) AS total_rows,
       formatReadableSize(sum(bytes_on_disk)) AS size_on_disk
FROM system.parts
WHERE database = 'shop' AND table IN ('orders', 'orders_by_customer') AND active
GROUP BY table ORDER BY table;

-- ===== 4. After: same query on the new table, 5 runs =====
SELECT order_id, product_id, status, quantity * unit_price AS amount, created_at FROM shop.orders_by_customer WHERE customer_id = 4321 ORDER BY created_at DESC SETTINGS log_comment = 'q6_after' FORMAT Null;
SELECT order_id, product_id, status, quantity * unit_price AS amount, created_at FROM shop.orders_by_customer WHERE customer_id = 4321 ORDER BY created_at DESC SETTINGS log_comment = 'q6_after' FORMAT Null;
SELECT order_id, product_id, status, quantity * unit_price AS amount, created_at FROM shop.orders_by_customer WHERE customer_id = 4321 ORDER BY created_at DESC SETTINGS log_comment = 'q6_after' FORMAT Null;
SELECT order_id, product_id, status, quantity * unit_price AS amount, created_at FROM shop.orders_by_customer WHERE customer_id = 4321 ORDER BY created_at DESC SETTINGS log_comment = 'q6_after' FORMAT Null;
SELECT order_id, product_id, status, quantity * unit_price AS amount, created_at FROM shop.orders_by_customer WHERE customer_id = 4321 ORDER BY created_at DESC SETTINGS log_comment = 'q6_after' FORMAT Null;

SELECT count() AS rows_for_customer_4321_new_table FROM shop.orders_by_customer WHERE customer_id = 4321;

EXPLAIN indexes = 1
SELECT order_id, product_id, status, quantity * unit_price AS amount, created_at
FROM shop.orders_by_customer WHERE customer_id = 4321 ORDER BY created_at DESC;

-- ===== 5. Metrics of every run from system.query_log =====
SYSTEM FLUSH LOGS;
SELECT log_comment AS phase, query_duration_ms AS duration_ms, read_rows,
       formatReadableSize(read_bytes) AS read_bytes,
       formatReadableSize(memory_usage) AS memory_usage
FROM system.query_log
WHERE type = 'QueryFinish' AND log_comment IN ('q6_before', 'q6_after')
  AND event_time > now() - INTERVAL 1 HOUR
ORDER BY event_time_microseconds;

-- ===== 6. Three heaviest queries of the project by read_bytes =====
SELECT any(query_kind) AS kind,
       formatReadableSize(max(read_bytes)) AS max_read_bytes,
       max(query_duration_ms) AS max_ms,
       formatReadableSize(max(memory_usage)) AS peak_memory,
       count() AS executions,
       any(substring(replaceRegexpAll(query, '\\s+', ' '), 1, 220)) AS query_start
FROM system.query_log
WHERE type = 'QueryFinish'
  AND has(databases, 'shop') AND NOT has(databases, 'system')
  AND log_comment NOT LIKE 'q6_%'
GROUP BY normalized_query_hash
ORDER BY max(read_bytes) DESC
LIMIT 3
FORMAT Vertical;
