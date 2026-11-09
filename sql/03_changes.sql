-- Part A: ReplacingMergeTree
DROP TABLE IF EXISTS shop.order_status_events SYNC;
CREATE TABLE shop.order_status_events
(
    order_id   UInt32,
    status     LowCardinality(String),
    updated_at DateTime
)
ENGINE = ReplacingMergeTree(updated_at)
ORDER BY order_id;

-- Keep the three inserts as separate parts so duplicates stay visible (restarted later).
SYSTEM STOP MERGES shop.order_status_events;

INSERT INTO shop.order_status_events
SELECT order_id, 'paid', created_at
FROM shop.orders
WHERE order_id % 20 = 0;

INSERT INTO shop.order_status_events
SELECT order_id, 'shipped', created_at + 3600
FROM shop.orders
WHERE order_id % 40 = 0;

INSERT INTO shop.order_status_events
SELECT order_id, 'delivered', created_at + 86400
FROM shop.orders
WHERE order_id % 80 = 0;

-- Q6: active parts, then row counts without and with FINAL
SELECT count() AS active_parts, sum(rows) AS total_rows
FROM system.parts
WHERE database = 'shop' AND table = 'order_status_events' AND active;

SELECT count() AS rows_without_final FROM shop.order_status_events;
SELECT count() AS rows_with_final FROM shop.order_status_events FINAL;

-- Status distribution without FINAL (wrong: counts every version)
SELECT status, count() AS orders
FROM shop.order_status_events
GROUP BY status ORDER BY status;

-- Final status distribution with FINAL
SELECT status, count() AS orders
FROM shop.order_status_events FINAL
GROUP BY status ORDER BY status;

-- Final status distribution with argMax
SELECT final_status AS status, count() AS orders
FROM
(
    SELECT order_id, argMax(status, updated_at) AS final_status
    FROM shop.order_status_events
    GROUP BY order_id
)
GROUP BY final_status ORDER BY final_status;

SYSTEM START MERGES shop.order_status_events;

-- ===== Part B: mutation and lightweight delete =====
-- Before
SELECT status, count() AS orders FROM shop.orders
WHERE customer_id = 777 AND toYYYYMM(created_at) = 202503 GROUP BY status ORDER BY status;
SELECT count() AS customer_12345_rows FROM shop.orders WHERE customer_id = 12345;
SELECT count() AS active_parts, sum(rows) AS physical_rows, sum(bytes_on_disk) AS bytes_on_disk
FROM system.parts WHERE database = 'shop' AND table = 'orders' AND active;

ALTER TABLE shop.orders UPDATE status = 'cancelled'
WHERE customer_id = 777 AND toYYYYMM(created_at) = 202503;

SELECT mutation_id, command, is_done, parts_to_do, parts_to_do_names, latest_fail_reason
FROM system.mutations WHERE database = 'shop' AND table = 'orders';

SELECT sleep(3) FORMAT Null;

SELECT mutation_id, command, is_done, parts_to_do, latest_fail_reason
FROM system.mutations WHERE database = 'shop' AND table = 'orders';

SYSTEM FLUSH LOGS;
SELECT event_time, part_name, rows, formatReadableSize(size_in_bytes) AS part_size
FROM system.part_log
WHERE database = 'shop' AND table = 'orders' AND event_type = 'MutatePart'
ORDER BY event_time;

SELECT status, count() AS orders FROM shop.orders
WHERE customer_id = 777 AND toYYYYMM(created_at) = 202503 GROUP BY status ORDER BY status;

-- Lightweight delete
DELETE FROM shop.orders WHERE customer_id = 12345;

SELECT count() AS customer_12345_rows_after FROM shop.orders WHERE customer_id = 12345;
SELECT count() AS active_parts, sum(rows) AS physical_rows, sum(bytes_on_disk) AS bytes_on_disk
FROM system.parts WHERE database = 'shop' AND table = 'orders' AND active;
SELECT count() AS logical_rows FROM shop.orders;

OPTIMIZE TABLE shop.orders FINAL;

SELECT count() AS active_parts, sum(rows) AS physical_rows, sum(bytes_on_disk) AS bytes_on_disk
FROM system.parts WHERE database = 'shop' AND table = 'orders' AND active;

-- ===== Part C: TTL =====
DROP TABLE IF EXISTS shop.ttl_demo SYNC;
CREATE TABLE shop.ttl_demo (id UInt32, ts DateTime)
ENGINE = MergeTree ORDER BY id
TTL ts + INTERVAL 1 MINUTE;

SYSTEM STOP MERGES shop.ttl_demo;
INSERT INTO shop.ttl_demo SELECT number, now() - 120 FROM numbers(10);
INSERT INTO shop.ttl_demo SELECT 100 + number, now() FROM numbers(5);

SELECT count() AS rows_before_optimize FROM shop.ttl_demo;
SYSTEM START MERGES shop.ttl_demo;
OPTIMIZE TABLE shop.ttl_demo FINAL;
SELECT count() AS rows_after_optimize FROM shop.ttl_demo;

-- Q8 second part: what a 1-year TTL on orders would affect (read-only, nothing is changed)
SELECT now() AS server_now,
       countIf(created_at < now() - INTERVAL 1 YEAR) AS already_expired_rows,
       count() AS total_rows
FROM shop.orders;
SELECT name, value FROM system.merge_tree_settings
WHERE name IN ('merge_with_ttl_timeout', 'ttl_only_drop_parts');
SELECT name, value FROM system.settings WHERE name = 'materialize_ttl_after_modify';
