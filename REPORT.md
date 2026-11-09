# گزارش پروژه پایانی دوره ClickHouse

## انبار داده تحلیلی برای سفارش‌های فروشگاه آنلاین «شاپلند»

---

## ۰. مقدمه و روش کار

این گزارش همهٔ بخش‌های الزامی پروژه (بخش ۰ تا ۶ و سؤال‌های ۱ تا ۱۱) را پوشش می‌دهد. برای هر سؤال، کوئری اجراشده، خروجی واقعی و توضیح آمده است. همهٔ خروجی‌ها از اجرای واقعی روی سیستم خودم برداشته شده‌اند و هیچ عددی تخمینی یا از مستندات کپی‌شده نیست.

**نسخه‌ها:** ClickHouse نسخهٔ `26.8.36` (ایمیج `clickhouse/clickhouse-server:26.8`)، PostgreSQL ایمیج `postgres:17`، اجرا با Docker Compose روی Ubuntu.

**ساختار مخزن** (مطابق صورت پروژه):

```text
shopland-clickhouse/
├── docker-compose.yml
├── postgres/seed.sql
├── sql/
│   ├── 01_schema.sql
│   ├── 02_load.sql
│   ├── 03_changes.sql
│   ├── 04_views_and_dictionary.sql
│   ├── 05_queries.sql
│   └── 06_performance.sql
└── REPORT.md
```

**نحوهٔ اجرا از صفر:**

```bash
docker compose up -d
for f in 01_schema 02_load 03_changes 04_views_and_dictionary 05_queries 06_performance; do
  docker compose exec -T clickhouse clickhouse-client \
    --user student --password student --database shop \
    --multiquery --format PrettyCompact < sql/$f.sql
done
```

(حلقه‌های `curl` بخش ۲-ج دستورهای bash هستند و در فایل SQL نمی‌گنجند؛ در همین گزارش آمده‌اند.)

### نکته‌های روش‌شناختی که در خواندن اعداد مهم‌اند

1. **داده تصادفی است و هر بار بارگذاری عددهای متفاوتی می‌دهد.** تابع `rand(N)` در کوئری تولید داده seed ندارد (عدد داخل پرانتز فقط باعث می‌شود فراخوانی‌ها یکسان‌سازی نشوند). بنابراین تعداد سفارش‌های ماه ۳ در بارگذاری‌های مختلف من بین حدود ۸۴۹ هزار و ۸۵۱ هزار بود. **همهٔ اعداد این گزارش از یک بارگذاری نهایی هستند** و پس از آن جدول `orders` دوباره ساخته نشد.
2. **ترتیب Materialized Viewها و بارگذاری:** ابتدا ۱۰ میلیون سفارش بارگذاری شد و در بخش ۴ ویوها ساخته و با `INSERT ... SELECT` از داده قبلی پر (backfill) شدند.
3. **تنظیمات پیش‌فرض سرور:** در این نسخه `async_insert=1` و `wait_for_async_insert=1` به‌صورت پیش‌فرض فعال‌اند (در بخش ۲-ج نشان داده شده). برای همین در آزمایش «INSERT عادی» صراحتاً `async_insert=0` گذاشتم.
4. **طراحی چند بار آزموده و اصلاح شد** (جدول مقایسه در پاسخ سؤال ۱ آمده است).

---

## ۱. بخش ۰: آماده‌سازی محیط

### `docker-compose.yml`

```yaml
services:
  clickhouse:
    image: clickhouse/clickhouse-server:26.8
    ports:
      - "8123:8123"
      - "9000:9000"
    environment:
      CLICKHOUSE_DB: shop
      CLICKHOUSE_USER: student
      CLICKHOUSE_PASSWORD: student
      CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT: "1"
    volumes:
      - clickhouse_data:/var/lib/clickhouse

  postgres:
    image: postgres:17
    environment:
      POSTGRES_DB: shopland
      POSTGRES_USER: student
      POSTGRES_PASSWORD: student
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./postgres/seed.sql:/docker-entrypoint-initdb.d/01-seed.sql:ro

volumes:
  clickhouse_data:
  postgres_data:
```

هر دو سرویس در شبکهٔ پیش‌فرض Compose هستند و ClickHouse با نام سرویس (`postgres`) به PostgreSQL وصل می‌شود. فایل `postgres/seed.sql` دقیقاً همان `CREATE TABLE` و `INSERT` صورت پروژه است و در اولین راه‌اندازی خودکار اجرا می‌شود. هر دو پایگاه داده volume اسم‌دار دارند.

### خروجی `docker compose ps`

```text
NAME                               IMAGE                               SERVICE      STATUS              PORTS
shopland-clickhouse-clickhouse-1   clickhouse/clickhouse-server:26.8   clickhouse   Up About a minute   0.0.0.0:8123->8123/tcp, 0.0.0.0:9000->9000/tcp
shopland-clickhouse-postgres-1     postgres:17                         postgres     Up About a minute   5432/tcp
```

### بررسی جدول محصولات

از طریق جدول موتور PostgreSQL در ClickHouse (ساخته‌شده در بخش ۴) تعداد ردیف‌های جدول `products` خوانده شد:

```sql
SELECT count() AS rows_in_postgres_table FROM products_pg;
```

```text
rows_in_postgres_table
5000
```

---

## ۲. بخش ۱: طراحی جدول سفارش‌ها

### `sql/01_schema.sql` (طراحی نهایی)

```sql
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
    order_id String, customer_id String, product_id String, city String,
    status String, quantity String, unit_price String, created_at String
)
ENGINE = MergeTree
ORDER BY tuple();
```

**انتخاب نوع داده‌ها:**

| ستون | نوع | دلیل |
|---|---|---|
| `order_id` | `UInt32` | عدد مثبت؛ تا ۴٫۲ میلیارد جا دارد (۱۰ میلیون سفارش و شناسه‌های ۲۰ میلیونی بخش Kafka هم در آن می‌گنجند) |
| `customer_id` | `UInt32` | حدود ۲۰۰ هزار مشتری، کوچک‌ترین نوع استاندارد مناسب |
| `product_id` | `UInt16` | ۵۰۰۰ محصول |
| `city` | `LowCardinality(String)` | چند مقدار تکراری؛ فرهنگ لغت داخلی |
| `status` | `Enum8` | دقیقاً سه مقدار |
| `quantity` | `UInt8` | مقدار ۱ تا ۵ |
| `unit_price` | `UInt32` | قیمت تومانی عدد صحیح تا چند میلیون؛ بنابراین `Decimal` لازم نیست |
| `created_at` | `DateTime` | دقت ثانیه |

**Codecها:** روی `order_id`، `customer_id` و `unit_price` از `T64, ZSTD(1)` و روی `created_at` از `Delta, ZSTD(1)` استفاده شد (انتخاب با اندازه‌گیری در جدول سؤال ۱ توجیه شده است).

---

### سؤال ۱: انتخاب ترتیب `ORDER BY` با توجه به Sparse Index و Granule

**کلید انتخاب‌شده:** `ORDER BY (city, created_at)` همراه با `PARTITION BY toYYYYMM(created_at)`.

**شاخص تنک و گرانول:** ClickHouse داده را به گرانول‌هایی حدود ۸۱۹۲ ردیفی تقسیم می‌کند و برای هر گرانول فقط یک ورودی (mark) از مقدار کلید در حافظه نگه می‌دارد، نه برای هر ردیف. در جدول من ۱۲۲۸ گرانول وجود دارد. میانگین ردیف در هر گرانول از تقسیم ۹٬۹۹۹٬۹۵۰ ردیف بر ۱۲۲۸ گرانول (کل گرانول‌های خروجی `EXPLAIN`) حدود ۸٬۱۴۳ است. هنگام اجرای کوئری، شرط روی ستون‌های کلید به بازه‌ای از گرانول‌ها تبدیل می‌شود و فقط همان گرانول‌ها از دیسک خوانده می‌شوند. اگر پیشوند کلید در شرط باشد، جست‌وجو از نوع `binary search` است. اگر فقط ستون دوم کلید در شرط باشد، `generic exclusion search` استفاده می‌شود که کم‌اثرتر است. اگر هیچ ستونی از کلید در شرط نباشد، همهٔ گرانول‌ها خوانده می‌شوند.

**دلیل انتخاب:**

1. **`city` اول است.** فقط ۶ مقدار دارد و در گزارش‌های بخش ۵ (کوئری‌های ۳ و ۶) مستقیماً استفاده می‌شود. ستون کم‌تنوع در ابتدای کلید باعث می‌شود داده‌های هر شهر یک بازهٔ پیوسته باشد.
2. **`created_at` دوم است.** تقریباً همهٔ گزارش‌ها بازهٔ زمانی دارند. چون داخل هر شهر مرتب است، کدک `Delta` خوب کار می‌کند؛ حجم فشردهٔ این ستون در طراحی نهایی ۱۰٫۷۳ مگابایت شد.
3. **`product_id` عمداً در کلید نیست.** `created_at` با دقت ثانیه تقریباً یکتاست (۱۰ میلیون ردیف در حدود ۳۱٫۵ میلیون ثانیه). ستونی که بعد از آن بیاید هیچ‌وقت نمی‌تواند بازه را محدودتر کند. گزارش‌های محصول‌محور از جدول `daily_sales` (کلید `day, city, product_id`) خوانده می‌شوند.
4. **پارتیشن ماهانه:** با فیلتر زمانی، پارت‌های ماه‌های نامرتبط به‌طور کامل کنار می‌روند (Min-Max و Partition در `EXPLAIN`).

**شواهد (`EXPLAIN indexes = 1`)** با کوئری قالب زیر که فقط شرط `WHERE` آن عوض شد:

```sql
EXPLAIN indexes = 1 SELECT order_id FROM shop.orders WHERE <شرط>;
```

| حالت | شرط | گرانول‌های انتخاب‌شده در شاخص اصلی | از کل ۱۲۲۸ | الگوریتم |
|---|---|---|---|---|
| الف | `city = 'Tehran'` و یک روز (۱۰ مارس) | 2 از 104 (پس از هرس پارتیشن) | **0.16%** | binary search |
| ب | فقط همان یک روز، بدون شهر | 17 از 104 | **1.38%** | generic exclusion search |
| ج | فقط `city = 'Mashhad'` | 164 از 1228 | **13.4%** | binary search |
| د | فقط `product_id = 100` | 1228 از 1228 | **100%** | — |
| هـ | فقط `customer_id = 4321` (بخش ۶) | 1228 از 1228 | **100%** | — |

بخشی از خروجی واقعی برای حالت الف:

```text
Min-Max       Parts: 1/12   Granules: 104/1228
Partition     Parts: 1/1    Granules: 104/104
PrimaryKey    Keys: city, created_at
              Condition: ... (city in ['Tehran', 'Tehran'])
              Parts: 1/1    Granules: 2/104    Search Algorithm: binary search
```

**کوئری‌هایی که سود می‌برند:** فیلتر روی `city`، فیلتر بازهٔ زمانی (چه با شهر و چه بدون شهر) و ترکیب آن‌ها. بهترین حالت شرط روی هر دو ستون است (الف). فیلتر زمان بدون شهر (ب) هم از هرس پارتیشن و از جست‌وجوی exclusion سود می‌برد، اما گرانول بیشتری می‌خواند.

**کوئری‌هایی که سود نمی‌برند:** فیلتر روی `customer_id`، `product_id` یا `order_id` (حالت‌های د و هـ). این کوئری‌ها کل جدول را می‌خوانند. برای کوئری مشتری در بخش ۶ یک جدول دوم با کلید مناسب ساخته شد.

**مقایسهٔ طراحی‌های آزموده‌شده** (هر کدام با ۱۰ میلیون ردیف؛ چون داده تصادفی است، تفاوت‌های خیلی کوچک معنادار نیستند):

| طراحی | `ORDER BY` | کدک‌ها | حجم فشردهٔ `orders` | حجم `created_at` |
|---|---|---|---|---|
| ۱ | `(toDate(created_at), city, product_id)` | T64 روی سه ستون، Delta روی زمان | 126.93 MiB | 26.51 MiB |
| ۲ | `(city, created_at)` | Delta روی `order_id`، ZSTD ساده روی `unit_price` | 126.19 MiB | 10.73 MiB |
| ۳ (نهایی) | `(city, created_at)` | T64 روی `order_id`، `customer_id`، `unit_price` | **116.12 MiB** | 10.73 MiB |

نتیجه: وقتی کلید با روز شروع می‌شود، زمان‌ها داخل هر روز نامرتب‌اند و `Delta` اثر خود را از دست می‌دهد (۲۶٫۵ در برابر ۱۰٫۷ مگابایت). `T64` برای مقادیر تصادفی کران‌دار (مثل `order_id` و `unit_price`) بهتر از `Delta` یا ZSTD ساده بود: `order_id` از 33.60 به 28.65 و `unit_price` از 28.74 به 23.61 مگابایت رسید.

---

### سؤال ۲: مقایسهٔ حجم دو جدول با `system.columns`

```sql
SELECT table, column, type,
    formatReadableSize(sum(data_compressed_bytes)) AS compressed,
    formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed,
    round(sum(data_uncompressed_bytes) / greatest(sum(data_compressed_bytes), 1), 2) AS ratio
FROM system.columns
WHERE database = 'shop' AND table IN ('orders', 'orders_naive')
GROUP BY table, column, type ORDER BY table, column;

SELECT table,
    formatReadableSize(sum(data_compressed_bytes)) AS compressed,
    formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed,
    round(sum(data_uncompressed_bytes) / sum(data_compressed_bytes), 2) AS ratio
FROM system.columns
WHERE database = 'shop' AND table IN ('orders', 'orders_naive')
GROUP BY table ORDER BY table;
```

**خروجی به تفکیک ستون:**

| ستون | حجم فشرده `orders` | حجم فشرده `orders_naive` | تفاوت | نسبت دو جدول |
|---|---:|---:|---:|---:|
| `city` | 47.91 KiB | 617.36 KiB | 569.45 KiB | 12.9x |
| `created_at` | 10.73 MiB | 54.48 MiB | 43.75 MiB | 5.1x |
| `customer_id` | 21.50 MiB | 65.11 MiB | 43.61 MiB | 3.0x |
| `order_id` | 28.65 MiB | 66.99 MiB | 38.34 MiB | 2.3x |
| `product_id` | 19.16 MiB | 43.81 MiB | 24.65 MiB | 2.3x |
| `quantity` | 6.75 MiB | 7.10 MiB | 0.35 MiB | 1.05x |
| `status` | 5.67 MiB | 23.97 MiB | 18.30 MiB | 4.2x |
| `unit_price` | 23.61 MiB | 48.13 MiB | 24.52 MiB | 2.0x |

**خروجی کل جدول:**

| جدول | حجم فشرده | حجم غیرفشرده | نسبت فشرده‌سازی |
|---|---:|---:|---:|
| `orders` | 116.12 MiB | 200.29 MiB | 1.72 |
| `orders_naive` | 310.19 MiB | 1.13 GiB | 3.74 |

**تحلیل:**

- جدول بهینه ۱۹۴٫۰۷ مگابایت (حدود **۶۲٫۶ درصد**) کوچک‌تر است. حجم غیرفشردهٔ آن حدود ۵٫۸ برابر کمتر است.
- **نسبت فشرده‌سازی جدول ساده بیشتر است (3.74 در برابر 1.72)، اما این معیار گمراه‌کننده است.** رشتهٔ متنی پر از کاراکترهای تکراری است و ZSTD آن را خوب فشرده می‌کند، ولی از پایه چندین برابر بزرگ‌تر است. معیار درست حجم نهایی روی دیسک است.
- **بیشترین تفاوت مطلق در `created_at`** است (۴۳٫۷۵ مگابایت، با اختلاف ناچیز بالاتر از `customer_id` با ۴۳٫۶۱). دلیل: در جدول ساده هر زمان یک رشتهٔ ۱۹ کاراکتری است، ولی در جدول بهینه یک عدد ۴ بایتی است که چون داخل هر شهر مرتب است، با `Delta` به تفاضل‌های کوچک تبدیل و بسیار فشرده می‌شود.
- **بیشترین تفاوت نسبی در `city`** است (حدود ۱۲٫۹ برابر): `LowCardinality` هر شهر را یک بار در فرهنگ لغت ذخیره می‌کند و ردیف‌ها فقط یک شمارهٔ یک‌بایتی‌اند که چون داده بر اساس شهر مرتب است، به رشته‌های بسیار طولانی از مقدار تکراری تبدیل می‌شود.
- ستون `customer_id` (حدود ۲۰۰ هزار مقدار تصادفی، یعنی حدود ۱۷٫۶ بیت اطلاعات در هر ردیف) با ۲۱٫۵ مگابایت به حد نظری آنتروپی (حدود ۲۱ مگابایت) نزدیک است؛ داده تصادفی را نمی‌شود بیشتر فشرد.
- ستون `quantity` کمترین تفاوت را دارد، چون فقط یک رقم است و رشتهٔ تک‌کاراکتری در ZSTD تقریباً به‌اندازهٔ `UInt8` جا می‌گیرد.

---

## ۳. بخش ۲: بارگذاری داده و فرمت‌ها

### الف) تولید ۱۰ میلیون سفارش

کوئری صورت پروژه بدون تغییر اجرا شد (`sql/02_load.sql`):

```sql
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
```

همان داده با تبدیل همهٔ ستون‌ها به رشته در `orders_naive` ریخته شد:

```sql
INSERT INTO shop.orders_naive
SELECT toString(order_id), toString(customer_id), toString(product_id),
       toString(city), toString(status), toString(quantity),
       toString(unit_price), toString(created_at)
FROM shop.orders;

OPTIMIZE TABLE shop.orders FINAL;
OPTIMIZE TABLE shop.orders_naive FINAL;
```

(`OPTIMIZE ... FINAL` پارت‌ها را ادغام می‌کند تا حجم‌های سؤال ۲ پایدار و قابل مقایسه باشند.)

```sql
SELECT table, count() AS active_parts, sum(rows) AS total_rows
FROM system.parts WHERE database = 'shop' AND active GROUP BY table ORDER BY table;
```

| table | active_parts | total_rows |
|---|---:|---:|
| orders | 12 | 10,000,000 |
| orders_naive | 1 | 10,000,000 |

جدول `orders` ۱۲ پارت دارد (یکی برای هر ماه پارتیشن‌بندی).

**انتخاب مسیر برای Materialized Viewها:** ابتدا داده بارگذاری شد و در بخش ۴ ویوها ساخته و با `INSERT ... SELECT` از جدول `orders` پر شدند (backfill).

### ب) خروجی گرفتن و خواندن فایل

```sql
SET engine_file_truncate_on_insert = 1;

INSERT INTO FUNCTION file('orders_2025_03.parquet', 'Parquet')
SELECT * FROM shop.orders WHERE toYYYYMM(created_at) = 202503;

INSERT INTO FUNCTION file('orders_2025_03.csv', 'CSVWithNames')
SELECT * FROM shop.orders WHERE toYYYYMM(created_at) = 202503;

SELECT count() AS parquet_rows FROM file('orders_2025_03.parquet', 'Parquet');
SELECT count() AS table_rows FROM shop.orders WHERE toYYYYMM(created_at) = 202503;
DESCRIBE file('orders_2025_03.parquet', 'Parquet');
DESCRIBE TABLE shop.orders;
```

(تنظیم `engine_file_truncate_on_insert` فقط برای اجرای مجدد اسکریپت است تا خروجی فایل موجود را بازنویسی کند.)

**مقایسهٔ تعداد ردیف** (قبل از تغییرات بخش ۳):

| منبع | تعداد ردیف |
|---|---:|
| فایل Parquet | 849,341 |
| جدول `orders` (ماه ۳) | 849,341 |

**خروجی `DESCRIBE file(...)` و `DESCRIBE TABLE shop.orders`:**

```text
DESCRIBE file('orders_2025_03.parquet', 'Parquet')      DESCRIBE TABLE shop.orders
order_id     UInt32                                      order_id     UInt32     T64, ZSTD(1)
customer_id  UInt32                                      customer_id  UInt32     T64, ZSTD(1)
product_id   UInt16                                      product_id   UInt16
city         String                                      city         LowCardinality(String)
status       String                                      status       Enum8('delivered' = 1, 'cancelled' = 2, 'returned' = 3)
quantity     UInt8                                       quantity     UInt8
unit_price   UInt32                                      unit_price   UInt32     T64, ZSTD(1)
created_at   DateTime64(3, 'UTC')                        created_at   DateTime   Delta(4), ZSTD(1)
```

```bash
docker compose exec clickhouse ls -l /var/lib/clickhouse/user_files/
```

```text
-rw-r----- 1 clickhouse clickhouse 60754974 Nov  8 23:28 orders_2025_03.csv
-rw-r----- 1 clickhouse clickhouse 13727276 Nov  8 23:28 orders_2025_03.parquet
```

### سؤال ۳: حجم فایل‌ها و تفاوت نوع ستون‌ها

| فرمت | اندازه (بایت) | اندازه (MiB) |
|---|---:|---:|
| Parquet | 13,727,276 | 13.09 |
| CSVWithNames | 60,754,974 | 57.94 |

فایل CSV حدود **۴٫۴ برابر** بزرگ‌تر از Parquet است: CSV متن ساده و بدون فشرده‌سازی است، ولی Parquet ستونی است و هر ستون را جداگانه کدگذاری و فشرده می‌کند.

**تفاوت نوع‌ها در `DESCRIBE`:** سه ستون فرق دارند. `city` به‌جای `LowCardinality(String)` و `status` به‌جای `Enum8` به شکل `String` خوانده می‌شوند، چون Parquet نوع Enum و LowCardinality ندارد و ClickHouse این ستون‌ها را به‌صورت رشته می‌نویسد. `created_at` هم به‌جای `DateTime` به شکل `DateTime64(3, 'UTC')` برگشت، چون نوع زمان Parquet یک واحد زمانی (میلی‌ثانیه) دارد. کدک‌ها هم در فایل نمی‌آیند، چون ویژگی ذخیره‌سازی ClickHouse هستند و نه نوع داده.

### ج) مشکل INSERTهای زیاد و کوچک

```sql
CREATE TABLE shop.small_inserts (id UInt32, ts DateTime) ENGINE = MergeTree ORDER BY id;
```

(در صورت پروژه `ORDER BY` مشخص نشده بود، ولی `MergeTree` به آن نیاز دارد؛ `id` گذاشتم.)

```bash
URL='http://localhost:8123/?user=student&password=student'

# ۵۰۰ تک‌ردیفی عادی (صراحتاً synchronous)
for i in $(seq 1 500); do
    curl -s "$URL&async_insert=0" --data-binary "INSERT INTO shop.small_inserts VALUES ($i, now())"
done

# ۵۰۰ تک‌ردیفی با Async Insert
for i in $(seq 1 500); do
    curl -s "$URL&async_insert=1&wait_for_async_insert=0" \
        --data-binary "INSERT INTO shop.small_inserts VALUES ($i, now())"
done
```

پس از هر حلقه این کوئری اجرا شد (با `table_uuid` تا فقط تاریخچهٔ همین جدول شمرده شود):

```sql
SYSTEM FLUSH LOGS;
SELECT countIf(event_type = 'NewPart') AS new_parts, countIf(event_type = 'MergeParts') AS merges,
  (SELECT count() FROM system.parts WHERE database = 'shop' AND table = 'small_inserts' AND active) AS active_parts_now,
  (SELECT count() FROM shop.small_inserts) AS rows_in_table
FROM system.part_log
WHERE table_uuid = (SELECT uuid FROM system.tables WHERE database = 'shop' AND name = 'small_inserts');
```

خروجی تجمعی بعد از هر حلقه:

| پس از | new_parts (تجمعی) | merges (تجمعی) | active_parts_now | rows_in_table | زمان حلقه |
|---|---:|---:|---:|---:|---:|
| ۵۰۰ INSERT عادی | 500 | 103 | 5 | 500 | 4.39 s |
| ۵۰۰ INSERT ناهمگام | 520 | 107 | 5 | 1000 | 3.73 s |

بنابراین حالت عادی **۵۰۰ پارت** و حالت ناهمگام **۲۰ پارت** (۵۲۰ منهای ۵۰۰) ساخت.

تنظیمات مؤثر سرور (از `system.settings` و `system.merge_tree_settings`):

| تنظیم | مقدار |
|---|---|
| `async_insert` | 1 (پیش‌فرض) |
| `wait_for_async_insert` | 1 (پیش‌فرض) |
| `async_insert_busy_timeout_ms` | 200 |
| `parts_to_delay_insert` | 1000 |
| `parts_to_throw_insert` | 3000 |
| `max_parts_in_total` | 100000 |

**مشاهدهٔ جانبی:** در اولین تلاش، قبل از اینکه `async_insert=0` را صراحتاً بگذارم، ۵۰۰ INSERT «عادی» با تنظیمات پیش‌فرض سرور ۳۵٫۳۵ ثانیه طول کشید (حدود ۷۱ میلی‌ثانیه برای هر درخواست) و `system.asynchronous_insert_log` ۵۱۹ flush ثبت کرد. یعنی INSERT پیش‌فرض در این نسخه از مسیر ناهمگام می‌رود و چون حلقه ترتیبی است و هر درخواست منتظر flush خودش می‌ماند، هیچ دسته‌بندی رخ نمی‌دهد (باز هم ۵۰۰ پارت). حالت `wait_for_async_insert=0` همین حلقه را در ۳٫۷ ثانیه انجام داد.

### سؤال ۴: تعداد پارت‌ها، پارت‌های فعال و INSERT همزمان

- **تعداد پارت‌ها:** INSERT عادی ۵۰۰ پارت ساخت (هر INSERT یک پارت) و INSERT ناهمگام فقط ۲۰ پارت، چون سرور ردیف‌های درخواست‌های مختلف را در یک بافر جمع می‌کند و یک‌جا می‌نویسد.
- **چرا پارت‌های فعال خیلی کمترند:** `system.part_log` تاریخچهٔ همهٔ رویدادها را نگه می‌دارد (۵۰۰ پارت ساخته‌شده و ۱۰۳ رویداد ادغام)، اما `system.parts` با `active` فقط پارت‌هایی را نشان می‌دهد که اکنون وجود دارند. ادغام‌های پس‌زمینه پارت‌های کوچک را در پارت‌های بزرگ‌تر ادغام می‌کنند، پس تعداد پارت‌های فعال به ۵ رسید و پارت‌های ادغام‌شده غیرفعال شدند.
- **خطا در INSERT همزمان از چند برنامه:** اگر پارت‌ها سریع‌تر از ظرفیت ادغام ساخته شوند، تعداد پارت‌های فعال یک پارتیشن بالا می‌رود. از `parts_to_delay_insert = 1000` به بعد ClickHouse INSERTها را کند می‌کند و از `parts_to_throw_insert = 3000` خطای `TOO_MANY_PARTS` (کد 252) می‌دهد و INSERT را رد می‌کند.

### سؤال ۵: ریسک `wait_for_async_insert=0`

با `wait_for_async_insert=0` سرور پیش از نوشتن داده روی دیسک به کلاینت «موفق» برمی‌گرداند. ریسک‌ها: (۱) اگر سرور قبل از flush بافر کرش یا ری‌استارت شود، ردیف‌های تأییدشده بی‌صدا از بین می‌روند؛ (۲) خطاهای بعدی (داده نامعتبر، `TOO_MANY_PARTS`) هرگز به کلاینت نمی‌رسد؛ (۳) داده بلافاصله با `SELECT` دیده نمی‌شود. در سیستم واقعی برای داده‌های حساس مثل سفارش و پرداخت `wait_for_async_insert=1` می‌گذارم: کلاینت تا flush صبر می‌کند (معمولاً کسری از ثانیه)، ولی باز هم دسته‌بندی بین کلاینت‌ها حفظ می‌شود. مقدار 0 را فقط برای داده‌های تحمل‌پذیر در برابر از دست رفتن مثل لاگ و رویدادهای کلیک مناسب می‌دانم.

---

## ۴. بخش ۳: تغییر و حذف داده

### الف) وضعیت سفارش با `ReplacingMergeTree`

```sql
CREATE TABLE shop.order_status_events
(
    order_id   UInt32,
    status     LowCardinality(String),
    updated_at DateTime
)
ENGINE = ReplacingMergeTree(updated_at)
ORDER BY order_id;

-- پارت‌ها را جدا نگه می‌دارد تا نسخه‌های تکراری قابل مشاهده بمانند (بعداً SYSTEM START MERGES)
SYSTEM STOP MERGES shop.order_status_events;
```

سه `INSERT` دقیقاً مطابق صورت پروژه (برای `order_id % 20 = 0` وضعیت `paid`، برای `% 40 = 0` وضعیت `shipped` و برای `% 80 = 0` وضعیت `delivered`) جداگانه اجرا شد. توقف ادغام فقط برای این است که ادغام پس‌زمینه بین INSERTها نسخه‌ها را حذف نکند و نمایش قابل تکرار باشد.

### سؤال ۶: `FINAL` و `argMax`

```sql
SELECT count() AS active_parts, sum(rows) AS total_rows FROM system.parts
WHERE database = 'shop' AND table = 'order_status_events' AND active;
SELECT count() AS rows_without_final FROM shop.order_status_events;
SELECT count() AS rows_with_final    FROM shop.order_status_events FINAL;

SELECT status, count() AS orders FROM shop.order_status_events GROUP BY status ORDER BY status;
SELECT status, count() AS orders FROM shop.order_status_events FINAL GROUP BY status ORDER BY status;

SELECT final_status AS status, count() AS orders
FROM (SELECT order_id, argMax(status, updated_at) AS final_status
      FROM shop.order_status_events GROUP BY order_id)
GROUP BY final_status ORDER BY final_status;
```

| | بدون `FINAL` | با `FINAL` | با `argMax` + `GROUP BY` |
|---|---:|---:|---:|
| تعداد کل ردیف‌ها | 875,000 | 500,000 | — |
| `paid` | 500,000 | 250,000 | 250,000 |
| `shipped` | 250,000 | 125,000 | 125,000 |
| `delivered` | 125,000 | 125,000 | 125,000 |

تعداد پارت‌های فعال ۳ و مجموع ردیف‌ها ۸۷۵٬۰۰۰ بود (۵۰۰٬۰۰۰ + ۲۵۰٬۰۰۰ + ۱۲۵٬۰۰۰).

**زمان اجرا** (هر روش ۳ بار اجرا، از `system.query_log` با `log_comment`):

| روش | کمترین | میانگین | حافظهٔ مصرفی |
|---|---:|---:|---:|
| `FINAL` | 13 ms | 17 ms | 8.86 MiB |
| `argMax` + `GROUP BY` | 30 ms | 31 ms | 51.85 MiB |

**توضیح:** `ReplacingMergeTree` نسخه‌های قدیمی یک کلید را فقط هنگام ادغام پارت‌ها حذف می‌کند و ادغام در پس‌زمینه و در زمان نامعلوم اتفاق می‌افتد. هر سه پارت ما جدا مانده بودند، پس بدون `FINAL` همهٔ نسخه‌ها شمرده شدند (۸۷۵٬۰۰۰ به‌جای ۵۰۰٬۰۰۰ و `paid` برابر ۵۰۰٬۰۰۰ به‌جای ۲۵۰٬۰۰۰). هر دو روش درست (`FINAL` و `argMax`) نتیجهٔ یکسان دادند. در این اندازه `FINAL` سریع‌تر بود (۱۷ در برابر ۳۱ میلی‌ثانیه) و حافظهٔ کمتری خواست (حدود ۶ برابر کمتر)، چون جدول بر اساس `order_id` مرتب است و `FINAL` نیازی به جدول هش برای ۵۰۰ هزار گروه ندارد.

### ب) Mutation و Lightweight Delete

```sql
ALTER TABLE shop.orders UPDATE status = 'cancelled'
WHERE customer_id = 777 AND toYYYYMM(created_at) = 202503;

SELECT mutation_id, command, is_done, parts_to_do, parts_to_do_names, latest_fail_reason
FROM system.mutations WHERE database = 'shop' AND table = 'orders';

SELECT part_name, rows, formatReadableSize(size_in_bytes) AS part_size
FROM system.part_log
WHERE database = 'shop' AND table = 'orders' AND event_type = 'MutatePart' ORDER BY event_time;

DELETE FROM shop.orders WHERE customer_id = 12345;
```

**وضعیت سفارش‌های ماه ۳ مشتری ۷۷۷:**

| | delivered | cancelled | returned |
|---|---:|---:|---:|
| قبل | 4 | 1 | 1 |
| بعد | 0 | 6 | 0 |

**پیگیری در `system.mutations`:** بلافاصله پس از اجرا: `mutation_109.txt`، `is_done = 0` و `parts_to_do = 12` (نام ۱۲ پارت در `parts_to_do_names` بود). ۳ ثانیه بعد: `is_done = 1` و `parts_to_do = 0` و `latest_fail_reason` خالی.

**رویدادهای `MutatePart` در `system.part_log`** (همگی در ثانیهٔ `2026-11-09 01:39:14`):

```text
202506_2_101_2_109   202501_10_105_2_109   202502_17_106_2_109   202507_16_108_2_109
202511_11_99_2_109   202510_9_102_2_109    202504_1_92_2_109     202505_5_103_2_109
202509_7_98_2_109    202508_4_107_2_109    202512_8_95_2_109     202503_3_96_2_109   (849341 rows)
```

**حذف مشتری ۱۲۳۴۵ (Lightweight Delete):**

| مرحله | ردیف‌های مشتری ۱۲۳۴۵ | ردیف منطقی (`count()`) | ردیف فیزیکی (`sum(rows)` پارت‌ها) | حجم روی دیسک (بایت) |
|---|---:|---:|---:|---:|
| قبل از همه | 50 | 10,000,000 | 10,000,000 | 121,997,647 |
| بعد از `UPDATE` و `DELETE FROM` | 0 | 9,999,950 | 10,000,000 | 122,042,774 |
| بعد از `OPTIMIZE TABLE orders FINAL` | 0 | 9,999,950 | 9,999,950 | 121,999,014 |

### سؤال ۷: تعداد پارت‌های بازنویسی‌شده و رفتار حذف

**Mutation چند پارت را بازنویسی کرد؟** **۱۲ پارت** (۱۲ رویداد `MutatePart` با پسوند `_109`، شمارهٔ mutation). یعنی همهٔ پارت‌های جدول، نه فقط پارت ماه ۳ (`202503`) که ردیف‌های هدف در آن بودند، چون شرط `WHERE` به‌تنهایی پارت‌ها را فیلتر نمی‌کند.

**چرا نباید سفارش‌ها را یکی‌یکی با `ALTER ... UPDATE` تغییر داد؟** هر `ALTER ... UPDATE` یک کار پس‌زمینهٔ سنگین است که پارت‌های داده را بازنویسی می‌کند و هزینه‌اش به اندازهٔ پارت‌ها بستگی دارد، نه به تعداد ردیف‌های تغییرکرده. هزاران تغییر تک‌ردیفی هزاران بازنویسی پشت سر هم می‌سازد. برای تغییر زیاد باید از مدل‌هایی مثل `ReplacingMergeTree` استفاده کرد که تغییر را به‌صورت INSERT نسخهٔ جدید ثبت می‌کنند.

**آیا بعد از `DELETE FROM` حجم دیسک فوراً کم می‌شود؟** **خیر.** Lightweight Delete فقط ردیف‌ها را با یک ماسک پنهان علامت می‌زند: ردیف منطقی ۹٬۹۹۹٬۹۵۰ شد ولی ردیف فیزیکی همان ۱۰ میلیون ماند و حجم دیسک حتی اندکی بیشتر شد (۱۲۲٬۰۴۲٬۷۷۴ در برابر ۱۲۱٬۹۹۷٬۶۴۷ بایت؛ این افزایش احتمالاً اثر خالص بازنویسی `UPDATE` و ماسک حذف است). ردیف‌ها فقط وقتی به‌طور فیزیکی پاک می‌شوند که پارت در یک ادغام بازنویسی شود؛ پس از `OPTIMIZE ... FINAL` ردیف فیزیکی ۹٬۹۹۹٬۹۵۰ شد.

### ج) TTL

```sql
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
```

| | تعداد ردیف |
|---|---:|
| قبل از `OPTIMIZE` | 15 |
| بعد از `OPTIMIZE ... FINAL` | 5 |

برای بخش دوم سؤال ۸ (بدون اجرای TTL روی `orders`) فقط این کوئری‌های خواندنی اجرا شد:

```sql
SELECT now() AS server_now, countIf(created_at < now() - INTERVAL 1 YEAR) AS already_expired_rows, count() AS total_rows
FROM shop.orders;
SELECT name, value FROM system.merge_tree_settings WHERE name IN ('merge_with_ttl_timeout', 'ttl_only_drop_parts');
SELECT name, value FROM system.settings WHERE name = 'materialize_ttl_after_modify';
```

| server_now | already_expired_rows | total_rows |
|---|---:|---:|
| 2026-11-09 01:39:18 | 8,552,824 | 9,999,950 |

| تنظیم | مقدار |
|---|---|
| `merge_with_ttl_timeout` | 14400 (ثانیه، یعنی ۴ ساعت) |
| `ttl_only_drop_parts` | 0 |
| `materialize_ttl_after_modify` | 1 |

### سؤال ۸: TTL و حذف فیزیکی

**چرا ردیف‌های منقضی قبل از `OPTIMIZE` دیده می‌شوند؟** TTL فقط هنگام ادغام پارت‌ها اعمال می‌شود، نه لحظهٔ انقضا. تا ادغامی رخ ندهد (و سرور حداقل `merge_with_ttl_timeout` = ۴ ساعت بین ادغام‌های TTL فاصله می‌گذارد)، ردیف‌های منقضی در پارت می‌مانند و `SELECT` آن‌ها را می‌بیند: ۱۵ ردیف قبل و ۵ ردیف بعد از `OPTIMIZE ... FINAL`.

**اگر امروز `TTL created_at + INTERVAL 1 YEAR DELETE` را به `orders` اضافه کنیم؟** امروز (۹ نوامبر ۲۰۲۶) **۸٬۵۵۲٬۸۲۴ از ۹٬۹۹۹٬۹۵۰ ردیف (حدود ۸۵٫۵ درصد)** قدیمی‌تر از یک سال‌اند. چون `materialize_ttl_after_modify = 1` است، TTL روی داده‌های موجود هم اعمال می‌شود و بلافاصله پس از `ALTER` یک کار پس‌زمینه پارت‌های موجود را بازنویسی می‌کند و آن ردیف‌ها حذف می‌شوند. باقی‌ماندهٔ حدود ۱٫۴۵ میلیون ردیف (سفارش‌های نوامبر و دسامبر ۲۰۲۵) به‌تدریج و هر وقت یک سالشان تمام شود (تا پایان دسامبر ۲۰۲۶) در ادغام‌های بعدی حذف می‌شوند. چون `ttl_only_drop_parts = 0` است، پارت‌ها بازنویسی می‌شوند، نه اینکه کامل رها شوند. روی `orders` اجرا نشد.

---

## ۵. بخش ۴: Materialized View و Dictionary

### الف) `daily_sales` با `SummingMergeTree`

```sql
CREATE TABLE daily_sales
(
    day Date, city LowCardinality(String), product_id UInt16,
    orders UInt64, items UInt64, revenue UInt64
)
ENGINE = SummingMergeTree
ORDER BY (day, city, product_id);

CREATE MATERIALIZED VIEW daily_sales_mv TO daily_sales AS
SELECT toDate(created_at) AS day, city, product_id,
       count() AS orders, sum(quantity) AS items,
       sum(toUInt64(quantity) * unit_price) AS revenue
FROM orders WHERE status = 'delivered'
GROUP BY day, city, product_id;

-- backfill داده قبلی (ویو فقط INSERTهای بعد از ساخته شدنش را می‌بیند)
INSERT INTO daily_sales
SELECT toDate(created_at) AS day, city, product_id, count() AS orders, sum(quantity) AS items,
       sum(toUInt64(quantity) * unit_price) AS revenue
FROM orders WHERE status = 'delivered' GROUP BY day, city, product_id;
```

**اعتبارسنجی با جدول مرجع:**

| | تعداد ردیف فیزیکی | کلیدهای متمایز | تعداد سفارش | درآمد |
|---|---:|---:|---:|---:|
| `daily_sales` | 4,708,538 | 4,708,538 | 6,667,978 | 20,201,289,694,000 |
| `orders` (فقط delivered) | — | — | 6,667,978 | 20,201,289,694,000 |

### ب) `daily_customers` با `AggregatingMergeTree`

```sql
CREATE TABLE daily_customers
(
    day Date,
    customers  AggregateFunction(uniq, UInt32),
    avg_amount AggregateFunction(avg, UInt64)
)
ENGINE = AggregatingMergeTree
ORDER BY day;

CREATE MATERIALIZED VIEW daily_customers_mv TO daily_customers AS
SELECT toDate(created_at) AS day,
       uniqState(customer_id) AS customers,
       avgState(toUInt64(quantity) * unit_price) AS avg_amount
FROM orders WHERE status = 'delivered' GROUP BY day;

INSERT INTO daily_customers
SELECT toDate(created_at) AS day, uniqState(customer_id), avgState(toUInt64(quantity) * unit_price)
FROM orders WHERE status = 'delivered' GROUP BY day;

SELECT day, uniqMerge(customers) AS customers, round(avgMerge(avg_amount)) AS avg_amount
FROM daily_customers GROUP BY day ORDER BY day LIMIT 3;
```

| day | customers | avg_amount |
|---|---:|---:|
| 2025-01-01 | 17,607 | 3,077,014 |
| 2025-01-02 | 17,421 | 3,027,970 |
| 2025-01-03 | 17,522 | 3,008,465 |

(مشتری‌های یکتا و میانگین مبلغ هر دو فقط برای سفارش‌های `delivered` حساب شدند تا با تعریف درآمد یکی باشد.)

### ج) ۱۰ محصول پرفروش با Refreshable Materialized View

```sql
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
SELECT * FROM system.view_refreshes WHERE database = 'shop' FORMAT Vertical;
SELECT * FROM top_products ORDER BY items DESC, revenue DESC;
```

«پرفروش» را بر اساس تعداد کالای فروخته‌شده (`items`) و در صورت تساوی درآمد تعریف کردم و «۳۰ روز آخر» را ۳۰ روز آخر موجود در داده (نه ۳۰ روز آخر تقویم امروز) گرفتم، چون داده مربوط به سال ۲۰۲۵ است.

```text
database: shop          view: top_products_mv       status: Scheduled
last_success_time: 2026-11-09 01:50:00              last_success_duration_ms: 53
last_refresh_time: 2026-11-09 01:50:00              next_refresh_time: 2026-11-09 02:00:00
exception:                                          retry: 0
read_rows: 407743       total_rows: 407738          written_rows: 10
```

| product_id | items | revenue |
|---:|---:|---:|
| 3817 | 463 | 475,491,000 |
| 4598 | 458 | 469,065,000 |
| 4146 | 449 | 488,147,000 |
| 4121 | 444 | 441,886,000 |
| 4480 | 441 | 448,735,000 |
| 4233 | 440 | 418,123,000 |
| 4401 | 435 | 396,473,000 |
| 772 | 434 | 452,415,000 |
| 2102 | 433 | 471,725,000 |
| 2190 | 432 | 437,492,000 |

فاصلهٔ `last_success_time` و `next_refresh_time` دقیقاً ۱۰ دقیقه است و ویو ۱۰ ردیف نوشت.

### د) اتصال به PostgreSQL و Dictionary

```sql
CREATE TABLE products_pg (product_id Int32, title String, category String, brand String)
ENGINE = PostgreSQL('postgres:5432', 'shopland', 'products', 'student', 'student');

CREATE DICTIONARY products_dict
(
    product_id UInt64, title String, category String, brand String
)
PRIMARY KEY product_id
SOURCE(POSTGRESQL(host 'postgres' port 5432 user 'student' password 'student' db 'shopland' table 'products'))
LAYOUT(FLAT())
LIFETIME(MIN 60 MAX 120);

SELECT * FROM products_pg ORDER BY product_id LIMIT 3;
SELECT number + 1 AS product_id, dictGet('shop.products_dict', 'category', toUInt64(number + 1)) AS category FROM numbers(6);
SELECT name, status, element_count, lifetime_min, lifetime_max, last_successful_update_time
FROM system.dictionaries WHERE database = 'shop';
```

| product_id | title | category | brand |
|---:|---|---|---|
| 1 | product-1 | Laptop | brand-1 |
| 2 | product-2 | Book | brand-2 |
| 3 | product-3 | Clothes | brand-3 |

`dictGet` برای محصولات ۱ تا ۶ به ترتیب `Laptop`، `Book`، `Clothes`، `Food`، `Toys`، `Mobile` را برگرداند (همان دسته‌های `products`). وضعیت دیکشنری: `LOADED` با `element_count = 5000`، `lifetime_min = 60`، `lifetime_max = 120` و آخرین به‌روزرسانی `2026-11-09 01:45:14`. دیکشنری با layout از نوع `FLAT` است، چون کلید عددی و فشرده (۱ تا ۵۰۰۰) است و سریع‌ترین جست‌وجو را می‌دهد. `LIFETIME(MIN 60 MAX 120)` یعنی بارگذاری مجدد در یک لحظهٔ تصادفی بین ۶۰ تا ۱۲۰ ثانیه.

### سؤال ۹: چرا باز هم `sum()` و `GROUP BY`؟

`SummingMergeTree` ردیف‌های هم‌کلید را فقط هنگام ادغام پس‌زمینه جمع می‌کند و تا آن زمان چند ردیف جزئی برای یک کلید وجود دارد. چون در `daily_sales` من فقط یک backfill انجام شد، کلیدها یکتا بودند (۴٬۷۰۸٬۵۳۸ ردیف برابر ۴٬۷۰۸٬۵۳۸ کلید). برای نشان دادن اثر واقعی، جدول آزمایشی `sales_demo` را با همان ساختار ساختم و داده ماه ۳ را در سه INSERT جدا (با ادغام متوقف) ریختم:

```sql
SELECT count() AS physical_rows, uniqExact(day, city) AS distinct_keys FROM sales_demo;
SELECT day, city, orders, revenue FROM sales_demo WHERE day = '2025-03-15' AND city = 'Tehran';
SELECT day, city, sum(orders) AS orders, sum(revenue) AS revenue FROM sales_demo
WHERE day = '2025-03-15' AND city = 'Tehran' GROUP BY day, city;
```

| | physical_rows | distinct_keys |
|---|---:|---:|
| `sales_demo` | 558 | 186 |

بدون `sum`/`GROUP BY` برای روز ۱۵ مارس و تهران **سه ردیف جزئی** برگشت:

| day | city | orders | revenue |
|---|---|---:|---:|
| 2025-03-15 | Tehran | 2286 | 7,154,168,000 |
| 2025-03-15 | Tehran | 2274 | 7,056,964,000 |
| 2025-03-15 | Tehran | 2248 | 6,805,616,000 |

با `sum` و `GROUP BY` نتیجه **۶٬۸۰۸ سفارش و ۲۱٬۰۱۶٬۷۴۸٬۰۰۰ تومان** شد که دقیقاً با کوئری مرجع روی `orders` (همان ۶۸۰۸ و ۲۱٬۰۱۶٬۷۴۸٬۰۰۰) برابر بود. بعد از `OPTIMIZE ... FINAL` جدول به ۱۸۶ ردیف رسید. پس اگر `sum` ننویسیم، فقط یکی از مقدارهای جزئی (مثلاً ۲۲۸۶ به‌جای ۶۸۰۸ سفارش) را می‌بینیم و عدد بسته به این است که ادغام چه زمانی رخ داده باشد.

### سؤال ۱۰: `uniqMerge` در برابر `uniqExact`

```sql
-- با حالت‌های ذخیره‌شده
SELECT toYYYYMM(day) AS m, uniqMerge(customers) FROM shop.daily_customers GROUP BY m;
-- مستقیم از orders
SELECT toYYYYMM(created_at) AS m, uniqExact(customer_id) FROM shop.orders
WHERE status = 'delivered' GROUP BY m;
-- جمع ساده‌لوحانهٔ مشتری‌های یکتای روزانه
SELECT toYYYYMM(day) AS m, sum(daily_unique) FROM
  (SELECT day, uniqMerge(customers) AS daily_unique FROM shop.daily_customers GROUP BY day) GROUP BY m;
```

| ماه | `uniqMerge` | `uniqExact` | خطای نسبی | جمع روزانه‌ها (نادرست) |
|---|---:|---:|---:|---:|
| 202501 | 187,956 | 188,146 | -0.101% | 543,174 |
| 202502 | 184,823 | 184,997 | -0.094% | 492,707 |
| 202503 | 187,832 | 188,328 | -0.263% | 541,951 |
| 202504 | 186,860 | 186,939 | -0.042% | 522,523 |
| 202505 | 188,003 | 188,148 | -0.077% | 540,401 |
| 202506 | 187,186 | 187,019 | +0.089% | 523,836 |
| 202507 | 188,030 | 188,159 | -0.069% | 541,458 |
| 202508 | 188,302 | 188,083 | +0.116% | 540,790 |
| 202509 | 186,860 | 187,087 | -0.121% | 523,616 |
| 202510 | 188,102 | 188,063 | +0.021% | 540,010 |
| 202511 | 186,922 | 187,015 | -0.050% | 522,479 |
| 202512 | 188,214 | 188,370 | -0.083% | 540,038 |

**زمان اجرا** (۳ بار اجرا، از `system.query_log`):

| روش | کمترین | میانگین | ردیف خوانده‌شده | حجم خوانده‌شده | حافظه |
|---|---:|---:|---:|---:|---:|
| `uniqMerge` از `daily_customers` | 168 ms | 190 ms | 365 | 32.08 KiB | 101.60 MiB |
| `uniqExact` از `orders` | 95 ms | 96 ms | 9,999,950 | 85.83 MiB | 93.13 MiB |

**تحلیل:** `uniqMerge` فقط ۳۶۵ ردیف (۳۲ کیلوبایت) می‌خواند، ولی مقدار آن تقریبی است (خطای حداکثر ۰٫۲۶۳٪ در این داده). در این اندازه (۱۰ میلیون ردیف) `uniqExact` حتی سریع‌تر بود (۹۶ در برابر ۱۹۰ میلی‌ثانیه)، احتمالاً چون ادغام ۳۶۵ حالت ذخیره‌شده (هر کدام یک مجموعهٔ هش) هم هزینه دارد (علت را پروفایل نکردم)؛ مزیت حالت‌های ذخیره‌شده با بزرگ‌تر شدن جدول خام یا نبودن آن آشکار می‌شود، و این را اندازه‌گیری نکردم. **چرا نمی‌شود عدد یکتای روزها را جمع کرد؟** مشتری‌ای که چند روز در ماه خرید کرده، در هر روز یک بار شمرده می‌شود. جمع روزانهٔ ژانویه ۵۴۳٬۱۷۴ است، در حالی که تعداد درست ۱۸۸٬۱۴۶ است (حدود ۲٫۹ برابر بیشتر). مشتری‌های یکتا قابل جمع نیستند، ولی حالت‌های `uniqState` را می‌شود با `uniqMerge` ادغام کرد.

### سؤال ۱۱: JOIN با جدول PostgreSQL در برابر `dictGet`

```sql
-- JOIN با جدول موتور PostgreSQL
SELECT p.category, sum(toUInt64(o.quantity) * o.unit_price) AS revenue
FROM shop.orders AS o INNER JOIN shop.products_pg AS p ON o.product_id = p.product_id
WHERE o.status = 'delivered' GROUP BY p.category ORDER BY p.category;

-- با dictGet
SELECT dictGet('shop.products_dict', 'category', toUInt64(product_id)) AS category,
       sum(toUInt64(quantity) * unit_price) AS revenue
FROM shop.orders WHERE status = 'delivered' GROUP BY category ORDER BY category;
```

خروجی هر دو یکسان بود:

| category | revenue |
|---|---:|
| Book | 3,363,408,334,000 |
| Clothes | 3,363,415,023,000 |
| Food | 3,372,396,163,000 |
| Laptop | 3,366,874,794,000 |
| Mobile | 3,364,305,444,000 |
| Toys | 3,370,889,936,000 |

| روش | کمترین | میانگین (۳ اجرا) | ردیف خوانده‌شده | حافظه |
|---|---:|---:|---:|---:|
| JOIN با `products_pg` | 93 ms | 100 ms | 10,004,950 | 36.88 MiB |
| `dictGet` | 67 ms | 68 ms | 9,999,950 | 16.17 MiB |

۵۰۰۰ ردیف اضافهٔ JOIN همان جدول محصولات است که در هر اجرا از PostgreSQL از طریق شبکه خوانده می‌شود، ولی دیکشنری در حافظه است. برای گزارش‌های پرتکرار `dictGet` مناسب‌تر است (سریع‌تر، حافظهٔ کمتر و بدون بار روی PostgreSQL در هر کوئری)؛ هزینه‌اش داده‌ی کمی قدیمی در دیکشنری است.

**آزمایش تغییر نام محصول:** در PostgreSQL عنوان محصول ۱ را به `product-1-renamed` تغییر دادم و هر ۱۰ ثانیه مقدار را از دیکشنری خواندم:

```text
زمان           dict_title          last_update (دیکشنری)
01:46:14       product-1           01:45:14
01:46:24       product-1           01:45:14
01:46:34       product-1           01:45:14
01:46:44       product-1-renamed   01:46:39
...
01:48:05       product-1-renamed   01:47:59
```

جدول موتور PostgreSQL تغییر را **بلافاصله** دید، ولی دیکشنری تا بارگذاری مجدد بعدی (۰۱:۴۶:۳۹، حدود ۲۵ ثانیه بعد) همان نام قدیمی را داد. بارگذاری‌های مجدد دیکشنری در ۰۱:۴۵:۱۴، ۰۱:۴۶:۳۹ و ۰۱:۴۷:۵۹ رخ دادند (فاصله‌های ۸۵ و ۸۰ ثانیه، مطابق `LIFETIME(MIN 60 MAX 120)`). بنابراین تغییر در PostgreSQL حداکثر ۱۲۰ ثانیه بعد در دیکشنری دیده می‌شود. در پایان نام محصول را به `product-1` برگرداندم.

---

## ۶. بخش ۵: کوئری‌های تحلیلی

همهٔ کوئری‌ها در `sql/05_queries.sql` هستند. کوئری‌های ۱، ۲، ۵ و ۶ از جدول `daily_sales` (بخش ۴) و کوئری‌های ۳، ۴ و ۷ از `orders` خوانده می‌شوند، چون به ستون‌هایی مثل `customer_id` و وضعیت‌های غیر `delivered` نیاز دارند که در `daily_sales` نیست. درآمد همه‌جا فقط سفارش‌های `delivered` است.

### کوئری ۱: درآمد ماهانهٔ هر دستهٔ محصول در ۲۰۲۵ (`dictGet`)

```sql
SELECT toYYYYMM(day) AS month,
       dictGet('shop.products_dict', 'category', toUInt64(product_id)) AS category,
       sum(revenue) AS revenue
FROM shop.daily_sales
WHERE day >= '2025-01-01' AND day < '2026-01-01'
GROUP BY month, category
ORDER BY month, category;
```

خروجی (۷۲ ردیف خروجی واقعی، برای خوانایی به شکل جدول ماه × دسته آمده است):

| ماه | Book | Clothes | Food | Laptop | Mobile | Toys |
|---|---:|---:|---:|---:|---:|---:|
| 202501 | 286,409,080,000 | 288,098,425,000 | 287,038,349,000 | 286,971,320,000 | 285,392,618,000 | 289,006,759,000 |
| 202502 | 258,569,696,000 | 260,158,449,000 | 262,139,561,000 | 259,271,732,000 | 260,414,546,000 | 260,259,401,000 |
| 202503 | 286,096,833,000 | 285,012,945,000 | 287,328,678,000 | 285,486,785,000 | 286,078,403,000 | 288,056,499,000 |
| 202504 | 277,123,221,000 | 276,715,258,000 | 276,456,311,000 | 275,469,951,000 | 276,386,155,000 | 275,686,066,000 |
| 202505 | 283,329,585,000 | 285,358,831,000 | 285,147,237,000 | 286,729,937,000 | 287,338,513,000 | 283,598,451,000 |
| 202506 | 274,991,608,000 | 275,928,917,000 | 278,688,112,000 | 276,258,839,000 | 277,054,630,000 | 275,859,680,000 |
| 202507 | 286,332,316,000 | 286,196,671,000 | 285,606,072,000 | 286,194,140,000 | 284,071,658,000 | 286,674,693,000 |
| 202508 | 287,551,310,000 | 284,598,958,000 | 286,125,580,000 | 286,475,720,000 | 285,414,923,000 | 287,422,247,000 |
| 202509 | 278,221,915,000 | 277,489,982,000 | 276,415,709,000 | 277,333,954,000 | 275,976,617,000 | 277,330,687,000 |
| 202510 | 285,864,126,000 | 283,899,306,000 | 285,421,066,000 | 284,490,135,000 | 285,418,260,000 | 284,105,529,000 |
| 202511 | 273,340,555,000 | 276,561,222,000 | 275,508,549,000 | 276,448,255,000 | 275,437,062,000 | 276,863,094,000 |
| 202512 | 285,578,089,000 | 283,396,059,000 | 286,520,939,000 | 285,744,026,000 | 285,322,059,000 | 286,026,830,000 |

**توضیح:** دستهٔ هر محصول با `dictGet` از دیکشنری PostgreSQL در حافظه گرفته می‌شود و بدون JOIN است. ماه فوریه به دلیل ۲۸ روز بودن در همهٔ دسته‌ها کمترین درآمد را دارد؛ دسته‌ها به‌دلیل تصادفی بودن داده درآمدهای نزدیک به هم دارند.

### کوئری ۲: سه محصول پردرآمد هر دسته (`LIMIT 3 BY`)

```sql
SELECT category, product_id, revenue
FROM (SELECT dictGet('shop.products_dict', 'category', toUInt64(product_id)) AS category,
             product_id, sum(revenue) AS revenue
      FROM shop.daily_sales GROUP BY category, product_id)
ORDER BY category, revenue DESC
LIMIT 3 BY category;
```

| category | product_id | revenue |
|---|---:|---:|
| Book | 1898 | 4,450,950,000 |
| Book | 4892 | 4,441,506,000 |
| Book | 2666 | 4,435,239,000 |
| Clothes | 2661 | 4,468,178,000 |
| Clothes | 1893 | 4,455,848,000 |
| Clothes | 3615 | 4,450,910,000 |
| Food | 3700 | 4,521,591,000 |
| Food | 3772 | 4,435,051,000 |
| Food | 2314 | 4,393,988,000 |
| Laptop | 4087 | 4,543,218,000 |
| Laptop | 1831 | 4,434,593,000 |
| Laptop | 1123 | 4,416,483,000 |
| Mobile | 1236 | 4,573,288,000 |
| Mobile | 3588 | 4,516,782,000 |
| Mobile | 2190 | 4,485,412,000 |
| Toys | 1889 | 4,466,499,000 |
| Toys | 3149 | 4,457,657,000 |
| Toys | 4049 | 4,451,716,000 |

**توضیح:** `LIMIT 3 BY category` پس از مرتب‌سازی نزولی بر اساس درآمد، از هر دسته فقط ۳ ردیف اول را نگه می‌دارد و به زیرکوئری یا تابع پنجره نیاز ندارد.

### کوئری ۳: به‌ازای هر شهر درآمد، سفارش‌های لغوشده و درصد مرجوعی

```sql
SELECT city,
       sumIf(toUInt64(quantity) * unit_price, status = 'delivered') AS revenue,
       countIf(status = 'cancelled') AS cancelled_orders,
       round(100 * countIf(status = 'returned') / count(), 2) AS returned_pct
FROM shop.orders GROUP BY city ORDER BY revenue DESC;
```

| city | revenue | cancelled_orders | returned_pct |
|---|---:|---:|---:|
| Tehran | 7,567,227,657,000 | 624,258 | 16.68 |
| Isfahan | 2,529,908,054,000 | 207,487 | 16.69 |
| Tabriz | 2,529,122,201,000 | 207,645 | 16.69 |
| Shiraz | 2,525,297,011,000 | 209,170 | 16.63 |
| Karaj | 2,524,999,072,000 | 207,828 | 16.62 |
| Mashhad | 2,524,735,699,000 | 208,551 | 16.70 |

**توضیح:** با `sumIf` و `countIf` هر سه شاخص در یک بار اسکن جدول محاسبه شد. «درصد مرجوعی» را برابر سفارش‌های `returned` تقسیم بر همهٔ سفارش‌های همان شهر تعریف کردم. تهران چون در تولید داده سه برابر شهرهای دیگر وزن دارد، حدود سه برابر درآمد و لغوی دارد، ولی درصد مرجوعی همهٔ شهرها حدود ۱۶٫۷٪ است.

### کوئری ۴: ۱۰ مشتری با بیشترین خرید و گران‌ترین سفارش هر کدام (`argMax`)

```sql
SELECT customer_id, sum(amount) AS total_spent, count() AS delivered_orders,
       max(amount) AS max_order_amount, argMax(order_id, amount) AS most_expensive_order_id
FROM (SELECT customer_id, order_id, toUInt64(quantity) * unit_price AS amount
      FROM shop.orders WHERE status = 'delivered')
GROUP BY customer_id ORDER BY total_spent DESC LIMIT 10;
```

| customer_id | total_spent | delivered_orders | max_order_amount | most_expensive_order_id |
|---:|---:|---:|---:|---:|
| 2969 | 235,337,000 | 51 | 10,010,000 | 1,118,647 |
| 129696 | 219,507,000 | 55 | 9,350,000 | 4,623,213 |
| 169890 | 213,926,000 | 61 | 9,845,000 | 3,747,914 |
| 168854 | 208,024,000 | 56 | 9,980,000 | 8,068,800 |
| 190904 | 206,942,000 | 53 | 9,905,000 | 642,782 |
| 81924 | 203,994,000 | 53 | 9,930,000 | 1,646,786 |
| 114026 | 203,878,000 | 56 | 9,630,000 | 8,739,891 |
| 144151 | 203,175,000 | 61 | 8,690,000 | 421,865 |
| 106726 | 201,753,000 | 51 | 10,010,000 | 5,810,920 |
| 89166 | 199,600,000 | 50 | 9,660,000 | 9,319,527 |

**توضیح:** «بیشترین خرید» را مجموع مبلغ سفارش‌های `delivered` گرفتم. `argMax(order_id, amount)` شناسهٔ سفارشی را برمی‌گرداند که `amount` در آن بیشترین است، بدون نیاز به JOIN یا تابع پنجره.

### کوئری ۵: درآمد روزانه، درآمد تجمعی و میانگین متحرک ۷ روزه (Window Function)

```sql
SELECT day, revenue,
       sum(revenue) OVER (ORDER BY day ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_revenue,
       round(avg(revenue) OVER (ORDER BY day ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)) AS moving_avg_7d
FROM (SELECT day, sum(revenue) AS revenue FROM shop.daily_sales GROUP BY day)
ORDER BY day LIMIT 10;
```

خروجی (۱۰ روز اول؛ با حذف `LIMIT` کل سال خروجی می‌دهد):

| day | revenue | cumulative_revenue | moving_avg_7d |
|---|---:|---:|---:|
| 2025-01-01 | 56,915,523,000 | 56,915,523,000 | 56,915,523,000 |
| 2025-01-02 | 55,287,712,000 | 112,203,235,000 | 56,101,617,500 |
| 2025-01-03 | 55,295,593,000 | 167,498,828,000 | 55,832,942,667 |
| 2025-01-04 | 55,608,998,000 | 223,107,826,000 | 55,776,956,500 |
| 2025-01-05 | 56,744,122,000 | 279,851,948,000 | 55,970,389,600 |
| 2025-01-06 | 55,252,748,000 | 335,104,696,000 | 55,850,782,667 |
| 2025-01-07 | 54,417,041,000 | 389,521,737,000 | 55,645,962,429 |
| 2025-01-08 | 56,299,991,000 | 445,821,728,000 | 55,558,029,286 |
| 2025-01-09 | 55,510,313,000 | 501,332,041,000 | 55,589,829,429 |
| 2025-01-10 | 55,401,737,000 | 556,733,778,000 | 55,604,992,857 |

**توضیح:** قاب `UNBOUNDED PRECEDING` تا ردیف جاری درآمد تجمعی از اول سال را می‌دهد و قاب `6 PRECEDING` تا ردیف جاری میانگین ۷ روزه. در ۶ روز اول به‌خاطر نبودن ۷ روز قبل، میانگین روی روزهای موجود حساب می‌شود (مثلاً روز دوم میانگین دو روز است).

### کوئری ۶: رتبهٔ شهرها در هر ماه و درصد تغییر نسبت به ماه قبل (`rank` و `lagInFrame`)

```sql
SELECT month, city, revenue, city_rank, prev_revenue,
       round(100 * (revenue / prev_revenue - 1), 2) AS pct_change_vs_prev_month
FROM (
    SELECT month, city, revenue,
           rank() OVER (PARTITION BY month ORDER BY revenue DESC) AS city_rank,
           lagInFrame(toNullable(revenue), 1) OVER (
               PARTITION BY city ORDER BY month
               ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS prev_revenue
    FROM (SELECT toYYYYMM(day) AS month, city, sum(revenue) AS revenue
          FROM shop.daily_sales GROUP BY month, city)
)
ORDER BY month, city_rank LIMIT 18;
```

خروجی (سه ماه اول؛ با حذف `LIMIT` همهٔ ۱۲ ماه):

| month | city | revenue | city_rank | prev_revenue | pct_change_vs_prev_month |
|---|---|---:|---:|---:|---:|
| 202501 | Tehran | 643,857,206,000 | 1 | NULL | NULL |
| 202501 | Isfahan | 217,862,402,000 | 2 | NULL | NULL |
| 202501 | Tabriz | 216,273,408,000 | 3 | NULL | NULL |
| 202501 | Mashhad | 215,864,901,000 | 4 | NULL | NULL |
| 202501 | Shiraz | 215,444,698,000 | 5 | NULL | NULL |
| 202501 | Karaj | 213,613,936,000 | 6 | NULL | NULL |
| 202502 | Tehran | 584,325,228,000 | 1 | 643,857,206,000 | -9.25 |
| 202502 | Karaj | 195,893,301,000 | 2 | 213,613,936,000 | -8.30 |
| 202502 | Shiraz | 195,831,694,000 | 3 | 215,444,698,000 | -9.10 |
| 202502 | Isfahan | 195,813,402,000 | 4 | 217,862,402,000 | -10.12 |
| 202502 | Mashhad | 194,515,920,000 | 5 | 215,864,901,000 | -9.89 |
| 202502 | Tabriz | 194,433,840,000 | 6 | 216,273,408,000 | -10.10 |
| 202503 | Tehran | 643,457,816,000 | 1 | 584,325,228,000 | 10.12 |
| 202503 | Tabriz | 216,959,672,000 | 2 | 194,433,840,000 | 11.59 |
| 202503 | Shiraz | 215,688,469,000 | 3 | 195,831,694,000 | 10.14 |
| 202503 | Isfahan | 214,281,933,000 | 4 | 195,813,402,000 | 9.43 |
| 202503 | Karaj | 214,175,945,000 | 5 | 195,893,301,000 | 9.33 |
| 202503 | Mashhad | 213,496,308,000 | 6 | 194,515,920,000 | 9.76 |

**توضیح:** `rank()` شهرها را در هر ماه بر اساس درآمد رتبه می‌دهد و `lagInFrame` (با قاب کامل پارتیشن، چون پیش‌فرض قاب آن فقط تا ردیف جاری است) درآمد ماه قبل همان شهر را می‌آورد. `toNullable` باعث می‌شود برای ماه اول هر شهر مقدار `NULL` برگردد و درصد تغییر هم `NULL` شود، نه عدد ساختگی یا خطای تقسیم بر صفر.

### کوئری ۷: مشتری‌های جدید هر ماه

```sql
SELECT first_month AS month, count() AS new_customers
FROM (SELECT customer_id, toYYYYMM(min(created_at)) AS first_month FROM shop.orders GROUP BY customer_id)
GROUP BY first_month ORDER BY first_month;
```

| month | new_customers |
|---|---:|
| 202501 | 197,083 |
| 202502 | 2,851 |
| 202503 | 65 |

**توضیح:** هر مشتری در ماه اولین سفارشش (از هر وضعیتی) «جدید» حساب شد. با حدود ۲۰۰ هزار مشتری و حدود ۸۰۰ هزار سفارش در ماه، تقریباً همهٔ مشتری‌ها در ژانویه یک بار سفارش داده‌اند. به همین دلیل ماه‌های بعد تقریباً هیچ مشتری جدیدی ندارند و از ماه ۴ به بعد خروجی ردیفی نداشت (صفر مشتری جدید).

---

## ۷. بخش ۶: پیدا کردن کوئری کند و بهینه‌سازی

### ۱) اندازه‌گیری کوئری پشتیبانی از `system.query_log`

کوئری صورت پروژه ۵ بار با `log_comment = 'q6_before'` اجرا شد و متریک‌ها از `system.query_log` خوانده شد:

```sql
SELECT log_comment AS phase, query_duration_ms AS duration_ms, read_rows,
       formatReadableSize(read_bytes) AS read_bytes, formatReadableSize(memory_usage) AS memory_usage
FROM system.query_log
WHERE type = 'QueryFinish' AND log_comment IN ('q6_before', 'q6_after')
ORDER BY event_time_microseconds;
```

| اجرا | زمان | `read_rows` | `read_bytes` | `memory_usage` |
|---|---:|---:|---:|---:|
| ۱ (سرد) | 41 ms | 9,999,950 | 40.56 MiB | 10.18 MiB |
| ۲ تا ۵ | 8 ms | 335,872 | 4.19 MiB | حدود 380 KiB |

مشتری ۴۳۲۱ دارای **۴۲ سفارش** است. در اجراهای ۲ تا ۵ `read_rows` ناگهان ۳۳۵٬۸۷۲ (برابر ۴۱ گرانول) شد. علت **Query Condition Cache** است: ClickHouse نتیجهٔ شرط `WHERE` را برای هر گرانول به خاطر می‌سپارد و در اجرای بعدی گرانول‌های بی‌نتیجه را رد می‌کند. شواهد از `ProfileEvents`: اجرای اول `QueryConditionCacheMisses: 24` و اجراهای بعدی `Hits: 12, Misses: 12`. برای مقایسهٔ منصفانه هر دو جدول را با `use_query_condition_cache = 0` هم ۵ بار اجرا کردم:

| جدول | زمان اجراها (ms) | `read_rows` | `read_bytes` |
|---|---|---:|---:|
| `orders` (کش خاموش) | 15, 15, 13, 13, 13 | 9,999,950 | 40.56 MiB |
| `orders_by_customer` (کش خاموش) | 2, 2, 2, 2, 2 | 8,192 | 79.75 KiB |

### ۲) `EXPLAIN indexes = 1` روی جدول اصلی

```sql
EXPLAIN indexes = 1
SELECT order_id, product_id, status, quantity * unit_price AS amount, created_at
FROM shop.orders WHERE customer_id = 4321 ORDER BY created_at DESC;
```

```text
ReadFromMergeTree (shop.orders)    Parts: 12 | Granules: 1228
  Prewhere filter column:  customer_id = 4321
  Indexes:
    Min-Max     Condition: true   Parts: 12/12   Granules: 1228/1228
    Partition   Condition: true   Parts: 12/12   Granules: 1228/1228
    PrimaryKey  Condition: true   Parts: 12/12   Granules: 1228/1228
```

**چرا همهٔ گرانول‌ها خوانده می‌شوند:** کلید جدول `(city, created_at)` است و در شرط فقط `customer_id` آمده؛ بنابراین `PrimaryKey` شرط `true` دارد و هیچ گرانولی کنار نمی‌رود. شرط زمانی هم وجود ندارد که پارتیشن‌ها را حذف کند. هر ۱۲۲۸ گرانول (حدود ۱۰ میلیون ردیف) برای پیدا کردن ۴۲ ردیف اسکن می‌شود.

### ۳) بهینه‌سازی بدون تغییر `ORDER BY` جدول `orders`

یک جدول دوم با کلید مناسب و یک Materialized View برای پر شدن آن ساختم (و داده قبلی را backfill کردم):

```sql
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

CREATE MATERIALIZED VIEW orders_by_customer_mv TO orders_by_customer AS SELECT * FROM orders;
INSERT INTO orders_by_customer SELECT * FROM orders;   -- backfill
OPTIMIZE TABLE orders_by_customer FINAL;
```

پارتیشن‌بندی عمداً حذف شد، چون جست‌وجوی یک مشتری روی همهٔ ماه‌ها پخش است و ۱۲ پارتیشن یعنی باز کردن ۱۲ پارت به‌جای یکی.

`EXPLAIN indexes = 1` برای همان کوئری روی جدول جدید:

```text
ReadFromMergeTree (shop.orders_by_customer)   Read type: InReverseOrder   Parts: 1 | Granules: 1
  Indexes:
    PrimaryKey  Keys: customer_id
                Condition: (customer_id in [4321, 4321])
                Parts: 1/1   Granules: 1/1221   Search Algorithm: binary search
```

کلید `(customer_id, created_at)` با `binary search` فقط **۱ گرانول از ۱۲۲۱** را انتخاب کرد. ترتیب `created_at DESC` هم با خواندن معکوس (`InReverseOrder`) بدون مرتب‌سازی جداگانهٔ سنگین تأمین شد. نتیجهٔ هر دو جدول برای مشتری ۴۳۲۱ همان ۴۲ ردیف یکسان بود.

**هزینهٔ این راه‌حل:**

| جدول | پارت‌های فعال | ردیف | حجم روی دیسک |
|---|---:|---:|---:|
| `orders` | 12 | 9,999,950 | 116.35 MiB |
| `orders_by_customer` | 1 | 9,999,950 | 121.36 MiB |

یعنی یک نسخهٔ دوم از داده (حدود دو برابر شدن ذخیره‌سازی). همچنین Materialized View فقط INSERTهای بعدی را می‌بیند؛ `UPDATE` و `DELETE` بعدی روی `orders` به نسخهٔ دوم نمی‌رسند.

### جدول مقایسهٔ قبل و بعد (با کش شرط خاموش، ۵ اجرا)

| وضعیت | زمان اجرا | `read_rows` | `read_bytes` | گرانول‌های خوانده‌شده / کل |
|---|---:|---:|---:|---:|
| قبل از بهینه‌سازی (`orders`) | 13–15 ms | 9,999,950 | 40.56 MiB | 1228 / 1228 |
| بعد از بهینه‌سازی (`orders_by_customer`) | 2 ms | 8,192 | 79.75 KiB | 1 / 1221 |

بهبود: حدود **۷ برابر** سریع‌تر، حدود **۵۲۰ برابر** بایت کمتر و حدود **۱۲۲۰ برابر** ردیف کمتر.

### ۴) سه کوئری سنگین پروژه (بر اساس `read_bytes`)

```sql
SELECT formatReadableSize(max(read_bytes)) AS max_read_bytes, max(query_duration_ms) AS max_ms,
       formatReadableSize(max(memory_usage)) AS peak_memory, count() AS executions,
       any(substring(replaceRegexpAll(query, '\\s+', ' '), 1, 260)) AS query_start
FROM system.query_log
WHERE type = 'QueryFinish' AND query_kind = 'Select'
  AND has(databases, 'shop') AND NOT has(databases, 'system')
  AND log_comment NOT LIKE 'q6_%'
  AND query NOT LIKE 'EXPLAIN%' AND query NOT LIKE 'SYSTEM%'
GROUP BY normalized_query_hash ORDER BY max(read_bytes) DESC LIMIT 3 FORMAT Vertical;
```

(کوئری‌های `INSERT ... SELECT` بارگذاری و backfill را که سنگین‌تر بودند ولی کارهای یک‌باره‌اند، کنار گذاشتم و فقط `SELECT`ها را رتبه‌بندی کردم؛ از رتبه‌بندی، `EXPLAIN` و `SYSTEM` و کوئری‌های اندازه‌گیری خود این بخش هم حذف شدند.)

| # | کوئری | بیشترین حجم خوانده‌شده | زمان | حافظهٔ اوج |
|---|---|---:|---:|---:|
| ۱ | کوئری ۴ بخش ۵ (۱۰ مشتری برتر با `argMax`) | 133.51 MiB | 230 ms | 401.43 MiB |
| ۲ | کوئری اعتبارسنجی `daily_sales` (`uniqExact(day, city, product_id)` روی ۴٫۷ میلیون ردیف) | 94.30 MiB | 288 ms | 760.89 MiB |
| ۳ | مقایسهٔ `uniqMerge` و `uniqExact` (سؤال ۱۰) | 85.86 MiB | 307 ms | 102.13 MiB |

**پیشنهاد بهبود برای کوئری ۱** (این پیشنهاد اجرا و اندازه‌گیری نشده است): این کوئری ستون‌های `status`، `customer_id`، `quantity`، `unit_price` و `order_id` را برای همهٔ ۱۰ میلیون ردیف می‌خواند و جدول هش با ۲۰۰ هزار گروه می‌سازد. راه‌حل اول یک Materialized View به یک جدول `AggregatingMergeTree` با کلید `customer_id` است که برای سفارش‌های `delivered` حالت‌های `sumState(amount)`، `countState()`، `maxState(amount)` و `argMaxState(order_id, amount)` را نگه می‌دارد؛ آن‌وقت کوئری فقط حدود ۲۰۰ هزار ردیف پیش‌تجمیع‌شده را می‌خواند. راه‌حل سبک‌تر بدون جدول جدید این است که روی `orders_by_customer` که `customer_id` پیشوند کلیدش است، با تنظیم `optimize_aggregation_in_order = 1` اجرا کنیم تا گروه‌ها به ترتیب بیایند و نیاز به جدول هش بزرگ کم شود. برای دو کوئری دیگر که کوئری‌های اعتبارسنجی بودند پیشنهادی ندارم.

---

## ۸. جمع‌بندی و محدودیت‌ها

- **طراحی نهایی `orders`:** `ORDER BY (city, created_at)`، پارتیشن ماهانه، انواع داده کوچک، `LowCardinality`/`Enum8` و کدک‌های `T64` و `Delta`، با ۶۲٫۶٪ حجم کمتر از جدول ساده. طراحی با اندازه‌گیری چند نسخه انتخاب شد.
- **کوئری‌هایی که از کلید سود نمی‌برند** (فیلتر روی `customer_id`) با جدول دوم و Materialized View سریع شدند، به قیمت یک نسخهٔ دوم داده؛ بقیهٔ گزارش‌ها از جدول‌های تجمیعی بخش ۴ خوانده می‌شوند.
- **یافته‌های غیرمنتظره که گزارش شده‌اند:** پیش‌فرض بودن `async_insert=1` در این نسخه؛ سریع‌تر بودن `FINAL` از `argMax` در این اندازه؛ سریع‌تر بودن `uniqExact` از `uniqMerge` روی ۱۰ میلیون ردیف؛ و اثر Query Condition Cache روی اندازه‌گیری‌های تکراری.
- **محدودیت‌ها:** داده تصادفی است و اعداد با اجرای دیگر فرق می‌کنند؛ Materialized Viewها فقط INSERTهای آینده را می‌بینند (UPDATE/DELETE منتقل نمی‌شود)؛ پیشنهاد بهبود بخش ۶ اجرا نشده است. بخش‌های امتیازی (Kafka، MinIO، `CollapsingMergeTree`، موتور Merge) در این نسخهٔ گزارش نیست.

<!-- بخش امتیازی Kafka (سؤال‌های ۱۲ تا ۱۴) در صورت انجام اینجا اضافه شود -->
