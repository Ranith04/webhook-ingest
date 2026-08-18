# Webhook Ingest Solution

## What was broken, and why

1. **Duplicate Events & Race Condition:** Deduplication relied on an application-level Check-Then-Act (`EventExists`), lacking a database `UNIQUE` constraint on `event_id`. Under concurrent delivery or retries, multiple requests would pass the check and insert duplicates, double-counting `account_stats`. Furthermore, stats updates were not part of a transaction, meaning partial failures would leave the DB in an inconsistent state forever.
2. **Recording Failures:** The `processRecording` goroutine inherited the HTTP request's context. When the HTTP handler returned `200 OK` early, this context was immediately canceled, causing the recording update to silently fail with a context canceled error.
3. **Data Loss on Deploy:** During `main.go` shutdown, the HTTP server correctly waited for active HTTP requests, but simply exited without waiting for background goroutines (like `processRecording`) to finish.

I fixed these by moving deduplication logic to a strict `UNIQUE(event_id)` Postgres constraint bundled in a single `pgx.Tx` transaction, detaching the background context using `context.WithoutCancel`, and wrapping background tasks with a `sync.WaitGroup` connected to a graceful shutdown timeout. (I also fixed a concurrent map write data race in the `cache.Record` method).

## Deduplication Strategy Choices

I chose to rely completely on **PostgreSQL's `UNIQUE` constraint combined with `ON CONFLICT DO NOTHING`** within a single transaction.

**Alternatives Considered:**
- **Redis Distributed Locks (`SETNX`):** While Redis was available, using it for deduplication would introduce a second state system. Coordinating Redis state with PostgreSQL persistence would be overly complex. PostgreSQL already owns the durable event persistence, so its unique constraint provides a simpler and stronger source of truth.
- **Application-Level Deduplication (Check-Then-Act):** This is what the application initially tried, but this is inherently prone to race conditions and double-inserts. 

## Handling 10,000 webhooks/second

At 10,000 webhooks/sec, I would decouple HTTP ingestion from processing using a durable queue:

1. **Durable Ingestion Queue:** The HTTP endpoint would do minimal validation and push the raw payload to a fast, durable stream (e.g., Redis Streams, Kafka, or AWS SQS).
2. **Horizontally Scaled Workers:** Separate worker processes would consume from the queue, allowing independent scaling of ingestion and processing.
3. **Optimized Postgres Strategy:** We would keep PostgreSQL as the source of truth for idempotency using the `event_id` index, but instead of transactional single-inserts, workers would use batched `INSERT ... ON CONFLICT` operations to reduce connection overhead and improve database throughput.
4. **Resilient In-Memory Caching:** We would replace the naive localized `sync.RWMutex` cache with a distributed caching layer (like Redis) for `account_stats` to ensure accurate rate-limiting/dashboards across multiple instances without hammering the database.
