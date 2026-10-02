# aws/ — cost and egress guardrails

`guardrails.sh` converges six guardrails on AWS account 814665782451 (us-east-1) so that a runaway
data-transfer bill is caught within a day. It exists because an hourly sync client looped for five
weeks and moved ~150 GB/day out of msens1 (~$450 of EC2 `DataTransfer-Out-Bytes`: $55.60 in August,
$397.70 in September) while the only budget was $20/month against a ~$187/month baseline, so it sat
permanently in ALARM and nobody was told.

| # | guardrail | what it is | threshold (env var) |
|---|---|---|---|
| 1 | SNS topic | `msens-alerts` + an email subscription | `ALERT_EMAIL` |
| 2 | network alarms | `msens1-network-out-hour` / `-day`: EC2 `NetworkOut` Sum over msens1 | 3 GB/hour (`NET_OUT_HOUR_GB`), 15 GB/day (`NET_OUT_DAY_GB`) |
| 3 | cost anomaly detection | monitor `msens-services` (DIMENSIONAL/SERVICE) + DAILY email subscription `msens-anomaly-daily` | total impact >= $5 (`ANOMALY_MIN_USD`) |
| 4 | budgets | `msens-monthly-total` (80 % / 100 % actual, 100 % forecast) and `msens-data-transfer-out` (usage type `DataTransfer-Out-Bytes`, 100 % actual) | $230 (`BUDGET_TOTAL_USD`), $10 (`BUDGET_EGRESS_USD`) |
| 5 | S3 request metrics | config `marine-atlas` (prefix `marine-atlas/`) on `oceanmetrics.io-public` + alarm `s3-marine-atlas-bytes-downloaded-day` | 20 GB/day (`S3_DL_DAY_GB`) |
| 6 | S3 access logging | private bucket `oceanmetrics.io-logs` (all public access blocked, writable only by S3 log delivery for the source bucket and account, objects expire after 90 days) + logging on `oceanmetrics.io-public` | `LOG_DAYS` |

GB means 10^9 bytes. Everything alarms to the one email address.

## Apply

```bash
cd server
ALERT_EMAIL=you@example.org aws/guardrails.sh --plan    # the exact aws commands; runs none
ALERT_EMAIL=you@example.org aws/guardrails.sh --apply   # converge (idempotent), then re-checks itself
# 1. open the "AWS Notification - Subscription Confirmation" email, COPY the Confirm subscription
#    link (do not click it) and confirm from here:
aws/guardrails.sh --confirm '<the link>'                # confirmed so that only AWS credentials can unsubscribe
aws/guardrails.sh --test-alarm                          # forces the hourly alarm to ALARM: one email must arrive
aws/guardrails.sh --check                               # read-only; exits non-zero unless all six are ok
```

Why `--confirm` and not a click: every alert email carries an "unsubscribe" link that works for anyone
who follows it, including a mail scanner. On the day this was first applied the subscription was
`Deleted` within minutes of being confirmed, the test alarm published into nothing, and `--check` still
said `ok`. `--check` now counts only a CONFIRMED subscription (`PendingConfirmation` is DRIFT, an
unsubscribed one is MISSING), and `--apply` subscribes again when it is gone.

`--check` prints one line per guardrail (`ok` / `MISSING` / `DRIFT` / `ERROR`). `--test-alarm` changes nothing durable: the alarm returns to OK by itself at its next
evaluation. Re-run `--check` from cron or a calendar reminder; DRIFT means someone edited a guardrail by hand.

Credentials: the IAM user needs SNS, CloudWatch alarms, Cost Explorer anomaly, Budgets and S3
(bucket policy / lifecycle / logging / metrics) permissions. `--check` needs only the read side.

## The old $20 budget

"AWS Monthly Cost Budget" ($20) is permanently in ALARM, so its emails are noise. `--check` flags it as
`unrealistic (limit < baseline)`; the script never deletes anything. Delete it by hand once
`msens-monthly-total` is ok:

```bash
aws budgets delete-budget --account-id 814665782451 --budget-name "AWS Monthly Cost Budget"
```

The account also has a legacy CloudWatch alarm `BillingAlarm` (EstimatedCharges, threshold 10) that
publishes to an older SNS topic `NotifyMe`; it is not touched either.

## S3 access logs

Server access logs are delivered (best effort, typically within a few hours) as
`s3://oceanmetrics.io-logs/s3-access/oceanmetrics.io-public/<YYYY-MM-DD-HH-MM-SS-ID>`, one text file
per batch, space-delimited. Bytes per day and per user-agent, with DuckDB (run after the `aws s3 sync` in the first
comment; tested on two synthetic log lines in the documented format, not yet on real delivered logs):

```sql
-- aws s3 sync s3://oceanmetrics.io-logs/s3-access/oceanmetrics.io-public/ logs/
SELECT
  strftime(strptime(regexp_extract(line, '\[([^\]]+)\]', 1), '%d/%b/%Y:%H:%M:%S %z'), '%Y-%m-%d') AS day,
  regexp_extract(line, '"[^"]*" "([^"]*)"', 1)               AS user_agent,
  count(*)                                                    AS requests,
  round(sum(try_cast(regexp_extract(line, '" \d{3} \S+ (\d+|-) ', 1) AS BIGINT)) / 1e9, 2) AS gb
FROM read_csv('logs/*', columns = {'line': 'VARCHAR'}, delim = '\x01', header = false, quote = '')
WHERE regexp_matches(line, 'REST\.GET\.OBJECT')
GROUP BY ALL
ORDER BY day DESC, gb DESC;
```

The access-log format is positional, so the regexes above pick out the bracketed timestamp, the final
quoted user-agent and the bytes-sent field after the HTTP status; check them against one real line
before trusting the numbers. Treat log analysis as forensics: the alarms are the detection.

## What the guardrails cost

Roughly **$1-6 per month**, small next to a ~$187 baseline. Prices checked on the AWS CloudWatch page
(2026-10-02); the S3 metrics count is from memory, so confirm on the first bill.

- CloudWatch alarms: $0.10 per standard alarm per month, first 10 free in the free tier. Three alarms: $0 to $0.30.
- S3 request metrics: S3 bills these at the CloudWatch custom-metric rate, $0.30 per metric per month.
  A filter publishes up to 16 metrics, so at most ~$4.80/month, less if only some report data. (Unsure of the exact
  count: look at "Request metrics" in the bucket's Metrics tab after a day.)
- S3 access logs: no feature fee; you pay normal storage ($0.023/GB-month) and the PUTs that deliver them.
  A million requests a day is a few hundred MB a day, so about 25 GB held at the 90-day expiry: well under $1/month.
- Budgets without actions, Cost Anomaly Detection and SNS email: free. Cost Explorer API calls made by `--check`
  and `--apply` are about $0.01 each.
