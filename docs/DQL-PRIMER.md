# DQL Primer — Dynatrace Query Language for dt-pilot

DQL (Dynatrace Query Language) is the read-side companion to Monaco. Monaco writes configuration; DQL queries Grail (Dynatrace's data lakehouse) for logs, metrics, traces, events, problems, vulnerabilities, and security findings.

This primer covers what you need to read and write DQL competently inside this harness. It is intentionally short — DQL has a deep surface and we lean on the Dynatrace MCP server (PR&nbsp;5) to do the heavy lifting (`generate_dql_from_natural_language`, `verify_dql`, `explain_dql_in_natural_language`).

> Authoritative reference: [docs.dynatrace.com — Dynatrace Query Language](https://docs.dynatrace.com/docs/discover-dynatrace/references/dynatrace-query-language). When this primer and the docs disagree on syntax, the docs win.

---

## 1. Mental model

- DQL is **pipeline-style**, not SQL-style. You start with a `fetch`, then chain commands that transform the stream.
- **Schema-on-read.** Grail doesn't require an up-front schema. Fields are addressed by name; missing fields are `null`.
- **Time ranges are out-of-band.** You don't `WHERE timestamp > ...` in the query — time is passed as a separate parameter when you execute the query (via the UI time picker or the MCP `execute_dql` tool's `defaultTimeframeStart` / `defaultTimeframeEnd` arguments).
- **Buckets are the storage primitive.** `fetch logs`, `fetch events`, `fetch metric.series`, `fetch dt.entity.host`, etc. Each is a bucket Grail knows how to scan.

---

## 2. Core commands

| Command | Role |
|---|---|
| `fetch <bucket>` | The source. Every pipeline starts here. |
| `filter <expr>` | Drop rows that don't match the boolean expression. |
| `summarize <agg> by: { <fields> }` | Group + aggregate (analogous to SQL `GROUP BY ... SELECT agg(...)`). |
| `fields <list>` | Project just the listed fields (analogous to SQL `SELECT`). |
| `fieldsAdd <expr>` | Compute a new field from existing fields. |
| `fieldsRemove <list>` | Drop specific fields. |
| `sort <field> asc\|desc` | Order results. |
| `limit <n>` | Cap row count. Always include for ad-hoc queries — Grail will happily stream millions of rows otherwise. |
| `parse <field>, "<pattern>"` | Pull structured fields out of an unstructured string (logs especially). |
| `dedup [by: { <fields> }]` | Deduplicate. |
| `lookup [...], sourceField:..., lookupField:...` | Join with another bucket. |

---

## 3. Five representative examples

### 3.1 Log search — recent errors from a specific service

```dql
fetch logs
| filter k8s.namespace.name == "checkout" and loglevel == "ERROR"
| fields timestamp, content, k8s.pod.name
| sort timestamp desc
| limit 50
```

Reads: scan the `logs` bucket, drop everything except `ERROR` lines from the `checkout` namespace, project three fields, newest first, top 50.

### 3.2 Davis problem listing — open problems in the last 24h

```dql
fetch dt.davis.problems
| filter event.status == "OPEN"
| fields timestamp, display_id, event.name, affected_entity_ids
| sort timestamp desc
| limit 100
```

Use this as the live source of "what's broken right now" before suggesting a Monaco-managed alerting tweak.

### 3.3 Host inventory — hosts grouped by management zone

```dql
fetch dt.entity.host
| summarize hosts = count(), by: { management_zones }
| sort hosts desc
```

`summarize` is the workhorse for inventory and capacity questions. `count()` is the most common aggregator; `sum()`, `avg()`, `min()`, `max()`, `percentile(field, 0.95)` all work.

### 3.4 Span query — slowest endpoints in the last hour

```dql
fetch spans
| filter span.kind == "SERVER"
| summarize p95 = percentile(duration, 0.95), by: { endpoint.name }
| sort p95 desc
| limit 20
```

`duration` is in nanoseconds — divide by `1000000` to get milliseconds, or use the built-in `toUnit(duration, "ms")` where available.

### 3.5 Metric aggregation — error rate by service

```dql
timeseries error_rate = sum(dt.service.request.failure_count) / sum(dt.service.request.count), by: { dt.entity.service }, filter: { dt.service.request.count > 0 }
| sort arrayAvg(error_rate) desc
| limit 10
```

`timeseries` is the metric-specific entry point (an alternative to `fetch metric.series`). It returns one array per series — the `arrayAvg` reduces the array to a scalar for sorting.

---

## 4. Practical patterns

### Counting unique values

```dql
fetch logs
| summarize uniques = countDistinctApprox(k8s.pod.name)
```

`countDistinctApprox` is a HyperLogLog approximation — fast and cheap. Use `countDistinct` only when you need an exact count and accept the cost.

### Parsing structured info out of a log line

```dql
fetch logs
| filter contains(content, "user_id=")
| parse content, "LD 'user_id=' LD:user_id"
| summarize hits = count(), by: { user_id }
| sort hits desc
| limit 25
```

The `parse` mini-language uses tokens like `LD` (lazy data), `INT`, `IPADDR`, `TIMESTAMP`, etc. Capture into a named field with `:name`.

### Joining metrics with entities

```dql
fetch dt.entity.host
| lookup [
    timeseries cpu = avg(dt.host.cpu.usage), by: { dt.entity.host }
  ], sourceField: id, lookupField: dt.entity.host
| fields entity.name, cpu
| sort arrayAvg(cpu) desc
| limit 10
```

Use `lookup` when the data you want lives in two buckets — entities + metrics, problems + entities, etc.

---

## 5. Time, dates, and ranges

- **Don't filter on `timestamp` directly** in the query. Pass the time range via the execution context.
- **MCP execution:** `execute_dql` accepts `defaultTimeframeStart` and `defaultTimeframeEnd` as ISO-8601 strings or as relative shorthands (`now-24h`, `now-7d`).
- **Inside the query** you can still operate on timestamps for bucketing: `summarize by: { interval = bin(timestamp, 5m) }`.

---

## 6. Cost discipline

Grail bills by scanned data. Five habits keep DQL cheap:

1. **Narrow the bucket.** `fetch logs` is the most expensive starting point; prefer `fetch dt.davis.problems` or `fetch dt.entity.host` if you can answer the question without raw logs.
2. **Filter early.** Put your most selective filter first — Grail can push some filters to storage.
3. **Always `limit` ad-hoc queries.** A missing `limit` plus a wide time range is the classic accidental five-figure query.
4. **Use `summarize` instead of `fields + sort + limit`** when you genuinely want an aggregate. `summarize` ships less data over the wire.
5. **Respect the per-environment query budget.** The Dynatrace MCP server's `DT_GRAIL_QUERY_BUDGET_GB` env var (default 1000 GB) is a hard ceiling; the MCP server rejects queries that would exceed it. That's a feature, not a bug.

---

## 7. When to delegate to MCP rather than hand-writing DQL

| Situation | Tool |
|---|---|
| You know what you want in English, not in DQL | `generate_dql_from_natural_language` |
| You have a DQL string and want to know if it's syntactically valid | `verify_dql` |
| You have a DQL string and want a plain-English explanation | `explain_dql_in_natural_language` |
| You want to actually run the query | `execute_dql` |
| You want the agent to debug a failed problem investigation | `chat_with_davis_copilot` |

The agent should default to MCP for any non-trivial DQL. Hand-write DQL only when you're verifying behavior locally, in a doc, or in a CI assertion — never as the load-bearing path of a chat response.

---

## 8. Anti-patterns

- **Hard-coding tenant URLs or entity IDs in committed DQL.** Tenant URLs go in `manifest.yaml`'s `environments` block. Entity IDs change across environments — parameterize or resolve at query time.
- **`fetch logs` without a `filter` and without a `limit`** in any committed query or CI assertion. Combined with a wide time range, this is the textbook cost incident.
- **Building DQL by string-concatenation in scripts.** Use `verify_dql` to validate the assembled string before sending it. Prefer parameterized queries through the MCP server.
- **Mixing `timeseries` and `fetch metric.series` in the same pipeline.** Pick one entry point per query. `timeseries` is friendlier for aggregations; `fetch metric.series` is friendlier for raw inspection.
- **Treating `null` as `false` in filters.** A field that doesn't exist is `null`, not `false` — explicit null checks (`isNotNull(x)`) avoid surprise.

---

## 9. Further reading

- [Dynatrace Query Language overview](https://docs.dynatrace.com/docs/discover-dynatrace/references/dynatrace-query-language)
- [DQL commands reference](https://docs.dynatrace.com/docs/discover-dynatrace/references/dynatrace-query-language/dql-commands)
- [DQL functions reference](https://docs.dynatrace.com/docs/discover-dynatrace/references/dynatrace-query-language/dql-functions)
- [Grail buckets and data sources](https://docs.dynatrace.com/docs/discover-dynatrace/references/grail-storage)
