-- Q1: monthly revenue per product category, 2025 (dictGet)
SELECT toYYYYMM(day) AS month,
       dictGet('shop.products_dict', 'category', toUInt64(product_id)) AS category,
       sum(revenue) AS revenue
FROM shop.daily_sales
WHERE day >= '2025-01-01' AND day < '2026-01-01'
GROUP BY month, category
ORDER BY month, category;

-- Q2: top 3 products by revenue in each category (LIMIT 3 BY)
SELECT category, product_id, revenue
FROM
(
    SELECT dictGet('shop.products_dict', 'category', toUInt64(product_id)) AS category,
           product_id, sum(revenue) AS revenue
    FROM shop.daily_sales
    GROUP BY category, product_id
)
ORDER BY category, revenue DESC
LIMIT 3 BY category;

-- Q3: per city: delivered revenue, cancelled orders, % returned (conditional combinators)
SELECT city,
       sumIf(toUInt64(quantity) * unit_price, status = 'delivered') AS revenue,
       countIf(status = 'cancelled') AS cancelled_orders,
       round(100 * countIf(status = 'returned') / count(), 2) AS returned_pct
FROM shop.orders
GROUP BY city
ORDER BY revenue DESC;

-- Q4: top 10 customers by delivered spend, with their most expensive order (argMax)
SELECT customer_id,
       sum(amount) AS total_spent,
       count() AS delivered_orders,
       max(amount) AS max_order_amount,
       argMax(order_id, amount) AS most_expensive_order_id
FROM
(
    SELECT customer_id, order_id, toUInt64(quantity) * unit_price AS amount
    FROM shop.orders
    WHERE status = 'delivered'
)
GROUP BY customer_id
ORDER BY total_spent DESC
LIMIT 10;

-- Q5: daily revenue, cumulative revenue, 7-day moving average (window functions)
-- first 10 days shown; remove LIMIT for the full series
SELECT day, revenue,
       sum(revenue) OVER (ORDER BY day ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_revenue,
       round(avg(revenue) OVER (ORDER BY day ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)) AS moving_avg_7d
FROM (SELECT day, sum(revenue) AS revenue FROM shop.daily_sales GROUP BY day)
ORDER BY day
LIMIT 10;

-- Q6: city rank per month by revenue, % change vs previous month (rank, lagInFrame)
-- Jan-Mar shown; remove LIMIT for all 12 months. First month has no previous month, so NULL.
SELECT month, city, revenue, city_rank, prev_revenue,
       round(100 * (revenue / prev_revenue - 1), 2) AS pct_change_vs_prev_month
FROM
(
    SELECT month, city, revenue,
           rank() OVER (PARTITION BY month ORDER BY revenue DESC) AS city_rank,
           lagInFrame(toNullable(revenue), 1) OVER (
               PARTITION BY city ORDER BY month
               ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS prev_revenue
    FROM
    (
        SELECT toYYYYMM(day) AS month, city, sum(revenue) AS revenue
        FROM shop.daily_sales
        GROUP BY month, city
    )
)
ORDER BY month, city_rank
LIMIT 18;

-- Q7: new customers per month (month of first order)
SELECT first_month AS month, count() AS new_customers
FROM
(
    SELECT customer_id, toYYYYMM(min(created_at)) AS first_month
    FROM shop.orders
    GROUP BY customer_id
)
GROUP BY first_month
ORDER BY first_month;
