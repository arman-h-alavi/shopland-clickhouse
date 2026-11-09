USE shop;

-- ===== A) daily_sales: SummingMergeTree + MV (delivered only) =====
DROP VIEW IF EXISTS daily_sales_mv SYNC;
DROP TABLE IF EXISTS daily_sales SYNC;
CREATE TABLE daily_sales
(
    day        Date,
    city       LowCardinality(String),
    product_id UInt16,
    orders     UInt64,
    items      UInt64,
    revenue    UInt64
)
ENGINE = SummingMergeTree
ORDER BY (day, city, product_id);

CREATE MATERIALIZED VIEW daily_sales_mv TO daily_sales AS
SELECT toDate(created_at) AS day, city, product_id,
       count() AS orders,
       sum(quantity) AS items,
       sum(toUInt64(quantity) * unit_price) AS revenue
FROM orders
WHERE status = 'delivered'
GROUP BY day, city, product_id;

-- Backfill: the view only sees rows inserted after it was created
INSERT INTO daily_sales
SELECT toDate(created_at) AS day, city, product_id,
       count() AS orders,
       sum(quantity) AS items,
       sum(toUInt64(quantity) * unit_price) AS revenue
FROM orders
WHERE status = 'delivered'
GROUP BY day, city, product_id;

-- ===== B) daily_customers: AggregatingMergeTree + MV =====
DROP VIEW IF EXISTS daily_customers_mv SYNC;
DROP TABLE IF EXISTS daily_customers SYNC;
CREATE TABLE daily_customers
(
    day        Date,
    customers  AggregateFunction(uniq, UInt32),
    avg_amount AggregateFunction(avg, UInt64)
)
ENGINE = AggregatingMergeTree
ORDER BY day;

CREATE MATERIALIZED VIEW daily_customers_mv TO daily_customers AS
SELECT toDate(created_at) AS day,
       uniqState(customer_id) AS customers,
       avgState(toUInt64(quantity) * unit_price) AS avg_amount
FROM orders
WHERE status = 'delivered'
GROUP BY day;

INSERT INTO daily_customers
SELECT toDate(created_at) AS day,
       uniqState(customer_id) AS customers,
       avgState(toUInt64(quantity) * unit_price) AS avg_amount
FROM orders
WHERE status = 'delivered'
GROUP BY day;

-- ===== C) Refreshable MV: top 10 products of the last 30 days of data =====
DROP VIEW IF EXISTS top_products_mv SYNC;
DROP TABLE IF EXISTS top_products SYNC;
CREATE TABLE top_products (product_id UInt16, items UInt64, revenue UInt64)
ENGINE = MergeTree ORDER BY product_id;

CREATE MATERIALIZED VIEW top_products_mv
REFRESH EVERY 10 MINUTE
TO top_products
AS
SELECT product_id, sum(items) AS items, sum(revenue) AS revenue
FROM daily_sales
WHERE day > (SELECT max(day) FROM daily_sales) - 30
GROUP BY product_id
ORDER BY items DESC, revenue DESC, product_id
LIMIT 10;

SYSTEM WAIT VIEW top_products_mv;

-- ===== D) PostgreSQL engine table and dictionary =====
DROP TABLE IF EXISTS products_pg SYNC;
CREATE TABLE products_pg
(
    product_id Int32,
    title      String,
    category   String,
    brand      String
)
ENGINE = PostgreSQL('postgres:5432', 'shopland', 'products', 'student', 'student');

DROP DICTIONARY IF EXISTS products_dict;
CREATE DICTIONARY products_dict
(
    product_id UInt64,
    title      String,
    category   String,
    brand      String
)
PRIMARY KEY product_id
SOURCE(POSTGRESQL(host 'postgres' port 5432 user 'student' password 'student' db 'shopland' table 'products'))
LAYOUT(FLAT())
LIFETIME(MIN 60 MAX 120);

-- ===== Evidence queries =====
SELECT count() AS rows_in_postgres_table FROM products_pg;
SELECT * FROM products_pg ORDER BY product_id LIMIT 3;
SELECT number + 1 AS product_id,
       dictGet('shop.products_dict', 'category', toUInt64(number + 1)) AS category
FROM numbers(6);
SELECT name, status, element_count, lifetime_min, lifetime_max, last_successful_update_time
FROM system.dictionaries WHERE database = 'shop';

SELECT *
FROM system.view_refreshes WHERE database = 'shop' FORMAT Vertical;
SELECT * FROM top_products ORDER BY items DESC, revenue DESC;

-- Sanity: backfilled tables against the source table
SELECT count() AS physical_rows, uniqExact(day, city, product_id) AS distinct_keys,
       sum(orders) AS total_orders, sum(revenue) AS total_revenue
FROM daily_sales;
SELECT count() AS delivered_orders, sum(toUInt64(quantity) * unit_price) AS delivered_revenue
FROM orders WHERE status = 'delivered';
SELECT day, uniqMerge(customers) AS customers, round(avgMerge(avg_amount)) AS avg_amount
FROM daily_customers GROUP BY day ORDER BY day LIMIT 3;

-- ===== Q9 demo on a scratch table (three batches with the same keys) =====
DROP TABLE IF EXISTS sales_demo SYNC;
CREATE TABLE sales_demo
(
    day     Date,
    city    LowCardinality(String),
    orders  UInt64,
    revenue UInt64
)
ENGINE = SummingMergeTree
ORDER BY (day, city);
SYSTEM STOP MERGES sales_demo;

INSERT INTO sales_demo
SELECT toDate(created_at) AS day, city, count() AS orders, sum(toUInt64(quantity) * unit_price) AS revenue
FROM orders WHERE status = 'delivered' AND toYYYYMM(created_at) = 202503 AND order_id % 3 = 0
GROUP BY day, city;
INSERT INTO sales_demo
SELECT toDate(created_at) AS day, city, count() AS orders, sum(toUInt64(quantity) * unit_price) AS revenue
FROM orders WHERE status = 'delivered' AND toYYYYMM(created_at) = 202503 AND order_id % 3 = 1
GROUP BY day, city;
INSERT INTO sales_demo
SELECT toDate(created_at) AS day, city, count() AS orders, sum(toUInt64(quantity) * unit_price) AS revenue
FROM orders WHERE status = 'delivered' AND toYYYYMM(created_at) = 202503 AND order_id % 3 = 2
GROUP BY day, city;

SELECT count() AS physical_rows, uniqExact(day, city) AS distinct_keys FROM sales_demo;
-- Without sum/GROUP BY: three partial rows for one key
SELECT day, city, orders, revenue FROM sales_demo
WHERE day = '2025-03-15' AND city = 'Tehran';
-- With sum/GROUP BY
SELECT day, city, sum(orders) AS orders, sum(revenue) AS revenue FROM sales_demo
WHERE day = '2025-03-15' AND city = 'Tehran' GROUP BY day, city;
-- Ground truth from orders
SELECT toDate(created_at) AS day, city, count() AS orders, sum(toUInt64(quantity) * unit_price) AS revenue
FROM orders WHERE status = 'delivered' AND toDate(created_at) = '2025-03-15' AND city = 'Tehran'
GROUP BY day, city;

SYSTEM START MERGES sales_demo;
OPTIMIZE TABLE sales_demo FINAL;
SELECT count() AS physical_rows_after_merge FROM sales_demo;
DROP TABLE sales_demo SYNC;
