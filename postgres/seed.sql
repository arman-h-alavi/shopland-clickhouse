CREATE TABLE products (
    product_id integer PRIMARY KEY,
    title text NOT NULL,
    category text NOT NULL,
    brand text NOT NULL
);

INSERT INTO products
SELECT
    g,
    'product-' || g,
    (ARRAY['Mobile','Laptop','Book','Clothes','Food','Toys'])[1 + g % 6],
    'brand-' || (g % 50)
FROM generate_series(1, 5000) AS g;
