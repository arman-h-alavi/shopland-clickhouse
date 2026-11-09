-- Materialized views (section 4) are created after loading, so they are backfilled with INSERT ... SELECT.

INSERT INTO shop.orders
SELECT
    number + 1 AS order_id,
    rand(1) % 200000 + 1 AS customer_id,
    rand(2) % 5000 + 1 AS product_id,
    ['Tehran', 'Tehran', 'Tehran', 'Mashhad',
     'Isfahan', 'Shiraz', 'Tabriz', 'Karaj'][rand(3) % 8 + 1] AS city,
    ['delivered', 'delivered', 'delivered', 'delivered',
     'cancelled', 'returned'][rand(4) % 6 + 1] AS status,
    rand(5) % 5 + 1 AS quantity,
    (rand(6) % 2000 + 10) * 1000 AS unit_price,
    toDateTime('2025-01-01 00:00:00') + rand(7) % (365 * 86400) AS created_at
FROM numbers(10000000);

INSERT INTO shop.orders_naive
SELECT toString(order_id), toString(customer_id), toString(product_id),
       toString(city), toString(status), toString(quantity),
       toString(unit_price), toString(created_at)
FROM shop.orders;

OPTIMIZE TABLE shop.orders FINAL;
OPTIMIZE TABLE shop.orders_naive FINAL;

SET engine_file_truncate_on_insert = 1;

INSERT INTO FUNCTION file('orders_2025_03.parquet', 'Parquet')
SELECT * FROM shop.orders WHERE toYYYYMM(created_at) = 202503;

INSERT INTO FUNCTION file('orders_2025_03.csv', 'CSVWithNames')
SELECT * FROM shop.orders WHERE toYYYYMM(created_at) = 202503;

SELECT count() AS parquet_rows FROM file('orders_2025_03.parquet', 'Parquet');
SELECT count() AS table_rows FROM shop.orders WHERE toYYYYMM(created_at) = 202503;
DESCRIBE file('orders_2025_03.parquet', 'Parquet');
DESCRIBE TABLE shop.orders;

DROP TABLE IF EXISTS shop.small_inserts SYNC;
CREATE TABLE shop.small_inserts (id UInt32, ts DateTime) ENGINE = MergeTree ORDER BY id;
