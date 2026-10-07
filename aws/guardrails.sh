#!/usr/bin/env bash
# guardrails.sh — converge the cost / egress guardrails on the MarineSensitivity AWS account
# so that a runaway data-transfer bill is caught within a day, not at the end of the month.
#
# WHY: the BOEM internal mirror (prod/sync-pull.sh) looped hourly for five weeks and moved
# ~150 GB/day out of msens1 (EC2 `DataTransfer-Out-Bytes`: $55.60 in August, $397.70 in
# September, ~$450 all told). Nobody was told: the only budget was "AWS Monthly Cost Budget" at
# $20/month against a ~$187/month baseline (July 2026), so it was permanently in ALARM and its
# emails were noise; there was no anomaly monitor, no network alarm, and the shared public
# bucket had no request metrics and no access logs to say who was downloading what.
#
#   aws/guardrails.sh --check        # DEFAULT. read-only: one line per guardrail
#                                    #   ok | MISSING | DRIFT | ERROR; exits non-zero unless all ok
#   aws/guardrails.sh --plan         # print the exact `aws` commands --apply would run; runs none
#   aws/guardrails.sh --apply        # converge: create what is missing, update what drifted
#   aws/guardrails.sh --confirm '<link>'  # confirm the SNS email subscription from here (paste the link
#                                    #   from the AWS email) so that only AWS credentials can unsubscribe it
#   aws/guardrails.sh --test-alarm   # seeded fault: force the hourly network alarm to ALARM so one
#                                    #   email arrives (proves the whole alarm -> SNS -> inbox path)
#
# --plan and --apply need ALERT_EMAIL. Every call is idempotent (put-/create-if-absent), so the
# script is safe to re-run; --apply ends with a --check of its own. It never deletes anything:
# the old $20 budget is reported as unrealistic and left for a human to delete (aws/README.md).
#
# THE SIX GUARDRAILS (names are the idempotency key -- do not rename by hand):
#   1  sns topic        msens-alerts + a CONFIRMED email subscription (PendingConfirmation is
#                       DRIFT, an unsubscribed one is MISSING: neither delivers anything)
#   2  network alarms   msens1-network-out-hour / -day: EC2 NetworkOut Sum over the instance
#   3  cost anomalies   DIMENSIONAL/SERVICE monitor msens-services + a DAILY email subscription
#   4  budgets          msens-monthly-total (80 % / 100 % actual, 100 % forecast) and
#                       msens-data-transfer-out (usage type DataTransfer-Out-Bytes, 100 % actual)
#   5  s3 request metrics   config `marine-atlas` (prefix marine-atlas/) + BytesDownloaded alarm
#   6  s3 access logging    private log bucket + put-bucket-logging on the public bucket
#
# ENV (defaults in brackets; GB means 10^9 bytes):
#   ALERT_EMAIL        required for --plan / --apply: where every alarm, budget and anomaly goes
#   AWS_REGION         [us-east-1]       (AWS_PROFILE etc. are honoured as usual)
#   ACCOUNT_ID         [814665782451]    refuse to run against any other account
#   INSTANCE_ID        [i-0692d15b330da30b6]   msens1
#   SRC_BUCKET         [oceanmetrics.io-public]  shared: marine-atlas/ gazetteer/ backups/ issues/
#   LOG_BUCKET         [oceanmetrics.io-logs]    private bucket that receives the access logs
#   LOG_DAYS           [90]              expire access logs after this many days
#   NET_OUT_HOUR_GB    [1]               hourly alarm: instance bytes out per hour
#   NET_OUT_DAY_GB     [5]               daily alarm: instance bytes out per day
#                                        (3 / 15 until 2026-10-07: set before the baseline was known; with the
#                                        mirror loop gone msens1 sends 0.03-0.06 GB/day, Sept was ~158 GB/day)
#   ANOMALY_MIN_USD    [5]               anomaly emails only when total impact >= this
#   BUDGET_TOTAL_USD   [230]             monthly total (baseline ~$187 + headroom)
#   BUDGET_EGRESS_USD  [10]              monthly DataTransfer-Out-Bytes
#   S3_DL_DAY_GB       [20]              marine-atlas/ BytesDownloaded per day
#   BASELINE_USD       [187]             a non-msens-* monthly budget below this is flagged "unrealistic"
set -euo pipefail

say() { echo "[guardrails] $*"; }
die() { echo "[guardrails] $*" >&2; exit 1; }

ALERT_EMAIL=${ALERT_EMAIL:-}
REGION=${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}
ACCOUNT_ID=${ACCOUNT_ID:-814665782451}
INSTANCE_ID=${INSTANCE_ID:-i-0692d15b330da30b6}
SRC_BUCKET=${SRC_BUCKET:-oceanmetrics.io-public}
LOG_BUCKET=${LOG_BUCKET:-oceanmetrics.io-logs}
LOG_DAYS=${LOG_DAYS:-90}
NET_OUT_HOUR_GB=${NET_OUT_HOUR_GB:-1}
NET_OUT_DAY_GB=${NET_OUT_DAY_GB:-5}
ANOMALY_MIN_USD=${ANOMALY_MIN_USD:-5}
BUDGET_TOTAL_USD=${BUDGET_TOTAL_USD:-230}
BUDGET_EGRESS_USD=${BUDGET_EGRESS_USD:-10}
S3_DL_DAY_GB=${S3_DL_DAY_GB:-20}
BASELINE_USD=${BASELINE_USD:-187}
export AWS_DEFAULT_REGION=$REGION AWS_PAGER=""

# fixed names: the idempotency keys
TOPIC_NAME=msens-alerts
ALARM_HOUR=msens1-network-out-hour
ALARM_DAY=msens1-network-out-day
MONITOR_NAME=msens-services
SUB_NAME=msens-anomaly-daily
BUDGET_TOTAL=msens-monthly-total
BUDGET_EGRESS=msens-data-transfer-out
METRICS_ID=marine-atlas
METRICS_PREFIX=marine-atlas/
ALARM_S3=s3-marine-atlas-bytes-downloaded-day
LOG_PREFIX="s3-access/$SRC_BUCKET/"
LOG_RULE=expire-s3-access-logs
LOG_SID=S3ServerAccessLogsPolicy
USAGE_TYPE=DataTransfer-Out-Bytes
NOTIFS_TOTAL=$'ACTUAL 80\nACTUAL 100\nFORECASTED 100'
NOTIFS_EGRESS='ACTUAL 100'

# ---- arguments ---------------------------------------------------------------
MODE=check
case "${1:-}" in
  ""|--check)  MODE=check ;;
  --plan)      MODE=plan ;;
  --apply)     MODE=apply ;;
  --test-alarm) MODE=test-alarm ;;
  --confirm)   MODE=confirm; CONFIRM_ARG=${2:-} ;;
  -h|--help)   sed -n '2,/^set -euo/p' "$0" | sed '$d'; exit 0 ;;
  *)           die "unknown argument: $1 (see the header of this script)" ;;
esac

need() { command -v "$1" >/dev/null || die "missing: $1"; }
need aws; need jq; need awk

if [ "$MODE" = plan ] || [ "$MODE" = apply ]; then
  [ -n "$ALERT_EMAIL" ] || die "set ALERT_EMAIL (see the header of this script)"
fi
if [ -n "$ALERT_EMAIL" ]; then
  printf '%s' "$ALERT_EMAIL" | grep -Eq '^[^@[:space:]"\\]+@[^@[:space:]"\\]+$' \
    || die "ALERT_EMAIL does not look like an email address: $ALERT_EMAIL"
fi

acct=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || die "no usable AWS credentials (try: aws sts get-caller-identity)"
[ "$acct" = "$ACCOUNT_ID" ] || die "this is account $acct, not $ACCOUNT_ID — refusing (set ACCOUNT_ID to override)"
TOPIC_ARN="arn:aws:sns:$REGION:$acct:$TOPIC_NAME"

# --confirm '<link or token>': confirm the email subscription FROM HERE instead of by clicking the
# link, with AuthenticateOnUnsubscribe. A link click confirms too, but then the "unsubscribe" link in
# every later alert email works for anyone -- including a mail scanner that follows links -- and an
# unsubscribed topic delivers nothing, silently. Confirmed this way, unsubscribing needs AWS
# credentials. Paste the whole "Confirm subscription" URL from the AWS email (quoted), or its Token.
if [ "$MODE" = confirm ]; then
  [ -n "${CONFIRM_ARG:-}" ] || die "usage: aws/guardrails.sh --confirm '<the Confirm subscription link from the AWS email, or its Token>'"
  # a link copied out of a mail client may arrive wrapped and percent-encoded (…url?q=…%26Token%3D…)
  token=$(printf '%s' "$CONFIRM_ARG" | sed -e 's/%3[Dd]/=/g' -e 's/%26/\&/g' -e 's/%3[Ff]/?/g' \
            | sed -E 's/.*[?&]Token=([0-9a-fA-F]+).*/\1/')
  printf '%s' "$token" | grep -Eq '^[0-9a-f]{64,}$' || die "that does not contain an SNS confirmation token"
  aws sns confirm-subscription --topic-arn "$TOPIC_ARN" --token "$token" \
    --authenticate-on-unsubscribe true --query SubscriptionArn --output text >/dev/null \
    || die "confirm-subscription failed (a token is single-use and expires after 3 days: re-run --apply for a new email)"
  say "subscription confirmed; unsubscribing now needs AWS credentials. next: aws/guardrails.sh --test-alarm"
  exit 0
fi

# plan lines go to fd 3 (the terminal) so `$(run ...)` can still capture a command's own output
exec 3>&1

# ---- helpers -----------------------------------------------------------------
# aws_try <args...>: run an aws read; fills OUT (stdout) and ERR (stderr); returns its status
OUT=""; ERR=""
aws_try() {
  local errf rc=0
  errf=$(mktemp)
  OUT=$(aws "$@" 2>"$errf") || rc=$?
  ERR=$(cat "$errf"); rm -f "$errf"
  return $rc
}
# a failed read is a legitimate "does not exist" only when the error says so
is_absent() { printf '%s' "$ERR" | grep -qiE 'NotFound|NoSuch|Not Found|does not exist|\(404\)'; }

# show <args...>: print a command with shell quoting where needed
show() {
  local a q out=""
  for a in "$@"; do
    case $a in
      ""|*[!A-Za-z0-9_./:=@,+%-]*) q=$(printf '%s' "$a" | sed "s/'/'\\\\''/g"); out="$out '$q'" ;;
      *) out="$out $a" ;;
    esac
  done
  echo "${out# }"
}
# run <cmd...>: --plan prints it (and proves every JSON argument parses); --apply prints and runs it
run() {
  local a
  if [ "$MODE" = plan ]; then
    for a in "$@"; do
      case $a in
        '{'*|'['*) printf '%s' "$a" | jq -e . >/dev/null || die "invalid JSON argument: $a" ;;
      esac
    done
    show "$@" >&3
    return 0
  fi
  echo "  \$ $(show "$@")" >&3
  "$@"
}

gb_bytes() { awk -v g="$1" 'BEGIN { printf "%.0f", g * 1e9 }'; }
num_eq()   { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 == b + 0) }'; }
has_email() {   # has_email <list>: the wanted address when ALERT_EMAIL is set, any address otherwise
  if [ -n "$ALERT_EMAIL" ]; then printf '%s' "$1" | tr ',\t ' '\n\n\n' | grep -qxF "$ALERT_EMAIL"
  else [ -n "$(printf '%s' "$1" | tr -d ',\t ')" ]; fi
}

# a guardrail is a set of parts; its status is the worst of them (ok < DRIFT < MISSING < ERROR)
G_RANK=0; G_DETAIL=""; FAILS=0
gstart() { G_RANK=0; G_DETAIL=""; }
part() {   # part <ok|DRIFT|MISSING|ERROR> <detail>
  local r=3
  case $1 in ok) r=0 ;; DRIFT) r=1 ;; MISSING) r=2 ;; esac
  if [ "$r" -gt "$G_RANK" ]; then G_RANK=$r; fi
  G_DETAIL="${G_DETAIL:+$G_DETAIL; }$2"
}
report() {  # report <n> <title>
  local s=ok
  case $G_RANK in 1) s=DRIFT ;; 2) s=MISSING ;; 3) s=ERROR ;; esac
  printf '%-4s %-22s %-8s %s\n' "[$1]" "$2" "$s" "$G_DETAIL"
  if [ "$G_RANK" -ne 0 ]; then FAILS=$((FAILS + 1)); fi
}
acting() { [ "$MODE" = plan ] || [ "$MODE" = apply ]; }

# ---- 1. sns topic + email subscription ----------------------------------------
S1_TOPIC=0; S1_SUB=0
chk_1() {
  gstart; S1_TOPIC=0; S1_SUB=0
  if aws_try sns get-topic-attributes --topic-arn "$TOPIC_ARN" --query Attributes.TopicArn --output text; then
    S1_TOPIC=1
  elif is_absent; then
    part MISSING "topic $TOPIC_NAME does not exist"; return 0
  else
    part ERROR "sns get-topic-attributes: $ERR"; return 0
  fi
  if ! aws_try sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" \
        --query "Subscriptions[?Protocol=='email'].[Endpoint,SubscriptionArn]" --output text; then
    part ERROR "sns list-subscriptions-by-topic: $ERR"; return 0
  fi
  # ONLY a confirmed subscription delivers. SNS lists two other states under the same endpoint, and
  # neither may read as ok: `PendingConfirmation` (nobody clicked the link) and `Deleted` (someone
  # -- or a mail scanner following every link in the alert email -- hit "unsubscribe"; the row
  # lingers for days). On 2026-10-02 the first --test-alarm published fine and this check printed
  # `ok ... subscribers: ben@…` while the subscription was `Deleted` and no alert could arrive.
  local subs=$OUT live pend emails
  subs=$(printf '%s\n' "$subs" | awk -F'\t' '$2 != "Deleted"')
  if [ -n "$ALERT_EMAIL" ]; then
    subs=$(printf '%s\n' "$subs" | awk -F'\t' -v e="$ALERT_EMAIL" '$1 == e')
  fi
  live=$(printf '%s\n' "$subs" | awk -F'\t' '$2 ~ /^arn:aws:sns:/ { printf "%s%s", (n++ ? "," : ""), $1 }')
  pend=$(printf '%s\n' "$subs" | awk -F'\t' '$2 == "PendingConfirmation" { printf "%s%s", (n++ ? "," : ""), $1 }')
  emails=${ALERT_EMAIL:-an email address}
  if [ -n "$live" ]; then
    S1_SUB=1; part ok "topic $TOPIC_NAME; confirmed subscriber(s): $live"
  elif [ -n "$pend" ]; then
    # present (so --apply does not subscribe again) but NOT ok: nothing is delivered yet
    S1_SUB=1; part DRIFT "topic $TOPIC_NAME; $pend is PendingConfirmation — no alert can reach it; confirm with: aws/guardrails.sh --confirm '<the link in the AWS email>'"
  else
    part MISSING "topic $TOPIC_NAME has no live email subscription for $emails (none, or unsubscribed)"
  fi
}
fix_1() {
  if [ "$S1_TOPIC" = 0 ]; then run aws sns create-topic --name "$TOPIC_NAME"; fi
  if [ "$S1_SUB" = 0 ]; then
    run aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol email --notification-endpoint "$ALERT_EMAIL"
    say "AWS emails $ALERT_EMAIL a confirmation link — click it, or nothing below can reach you"
  fi
}

# ---- 2. cloudwatch alarms -------------------------------------------------------
# alarm_eval <state var> <name> <ns> <metric> <dims "K=V,K=V" sorted by key> <period> <threshold bytes> <gb>
alarm_eval() {
  local var=$1 name=$2 ns=$3 metric=$4 dims=$5 period=$6 thr=$7 gb=$8
  local g_ns g_metric g_stat g_period g_thr g_cmp g_ep g_tmd g_act g_dims d=""
  if ! aws_try cloudwatch describe-alarms --alarm-names "$name" --output text --query \
        "MetricAlarms[0].[Namespace,MetricName,Statistic,Period,Threshold,ComparisonOperator,EvaluationPeriods,TreatMissingData,join(',',AlarmActions),join(',',sort_by(Dimensions,&Name)[].join('=',[Name,Value]))]"; then
    part ERROR "alarm $name: $ERR"; printf -v "$var" '%s' ERROR; return 0
  fi
  if [ "$OUT" = None ]; then
    part MISSING "alarm $name"; printf -v "$var" '%s' MISSING; return 0
  fi
  IFS=$'\t' read -r g_ns g_metric g_stat g_period g_thr g_cmp g_ep g_tmd g_act g_dims <<<"$OUT"
  [ "$g_ns" = "$ns" ]                     || d="$d namespace=$g_ns"
  [ "$g_metric" = "$metric" ]             || d="$d metric=$g_metric"
  [ "$g_stat" = Sum ]                     || d="$d statistic=$g_stat"
  [ "$g_period" = "$period" ]             || d="$d period=$g_period"
  num_eq "$g_thr" "$thr"                  || d="$d threshold=$(awk -v t="$g_thr" 'BEGIN { printf "%.0f", t }') (want $thr)"
  [ "$g_cmp" = GreaterThanThreshold ]     || d="$d comparison=$g_cmp"
  [ "$g_ep" = 1 ]                         || d="$d evaluation_periods=$g_ep"
  [ "$g_tmd" = notBreaching ]             || d="$d treat_missing_data=$g_tmd"
  case ",$g_act," in *",$TOPIC_ARN,"*) ;; *) d="$d alarm_action=$g_act (want $TOPIC_ARN)" ;; esac
  [ "$g_dims" = "$dims" ]                 || d="$d dimensions=$g_dims (want $dims)"
  if [ -n "$d" ]; then
    part DRIFT "alarm $name:$d"; printf -v "$var" '%s' DRIFT
  else
    part ok "$name Sum/${period}s > $gb GB"; printf -v "$var" '%s' ok
  fi
}
alarm_fix() {   # alarm_fix <state> <name> <description> <ns> <metric> <dims> <period> <threshold bytes>
  local st=$1 name=$2 desc=$3 ns=$4 metric=$5 dims=$6 period=$7 thr=$8 kv dargs=""
  [ "$st" != ok ] || return 0
  # shellcheck disable=SC2086  # dimension pairs are word-split on purpose, one arg per K=V
  for kv in $(printf '%s' "$dims" | tr ',' ' '); do dargs="$dargs Name=${kv%%=*},Value=${kv#*=}"; done
  # shellcheck disable=SC2086
  run aws cloudwatch put-metric-alarm --alarm-name "$name" --alarm-description "$desc" \
    --namespace "$ns" --metric-name "$metric" --dimensions $dargs \
    --statistic Sum --period "$period" --evaluation-periods 1 --threshold "$thr" \
    --comparison-operator GreaterThanThreshold --treat-missing-data notBreaching \
    --alarm-actions "$TOPIC_ARN"
}
S2_HOUR=""; S2_DAY=""
chk_2() {
  gstart
  alarm_eval S2_HOUR "$ALARM_HOUR" AWS/EC2 NetworkOut "InstanceId=$INSTANCE_ID" 3600  "$(gb_bytes "$NET_OUT_HOUR_GB")" "$NET_OUT_HOUR_GB"
  alarm_eval S2_DAY  "$ALARM_DAY"  AWS/EC2 NetworkOut "InstanceId=$INSTANCE_ID" 86400 "$(gb_bytes "$NET_OUT_DAY_GB")"  "$NET_OUT_DAY_GB"
}
fix_2() {
  alarm_fix "$S2_HOUR" "$ALARM_HOUR" "msens1 sent more than $NET_OUT_HOUR_GB GB out in one hour (the 2026-08 sync loop was ~6 GB/hour)" \
    AWS/EC2 NetworkOut "InstanceId=$INSTANCE_ID" 3600 "$(gb_bytes "$NET_OUT_HOUR_GB")"
  alarm_fix "$S2_DAY" "$ALARM_DAY" "msens1 sent more than $NET_OUT_DAY_GB GB out in one day (the 2026-08 sync loop was ~150 GB/day)" \
    AWS/EC2 NetworkOut "InstanceId=$INSTANCE_ID" 86400 "$(gb_bytes "$NET_OUT_DAY_GB")"
}

# ---- 3. cost anomaly detection --------------------------------------------------
S3_MON=""; S3_SUB=""; S3_SUBARN=""; MONITOR_ARN=""
threshold_expr() {
  jq -nc --arg v "$ANOMALY_MIN_USD" \
    '{Dimensions: {Key: "ANOMALY_TOTAL_IMPACT_ABSOLUTE", MatchOptions: ["GREATER_THAN_OR_EQUAL"], Values: [$v]}}'
}
chk_3() {
  gstart; S3_MON=MISSING; S3_SUB=MISSING; S3_SUBARN=""; MONITOR_ARN=""
  local mtype mdim f_arn f_freq f_key f_match f_val f_subs f_mons d=""
  if ! aws_try ce get-anomaly-monitors --output text \
        --query "AnomalyMonitors[?MonitorName=='$MONITOR_NAME'].[MonitorArn,MonitorType,MonitorDimension] | [0]"; then
    part ERROR "ce get-anomaly-monitors: $ERR"; S3_MON=ERROR; S3_SUB=ERROR; return 0
  fi
  if [ -z "$OUT" ] || [ "$OUT" = None ]; then
    part MISSING "monitor $MONITOR_NAME"
  else
    IFS=$'\t' read -r MONITOR_ARN mtype mdim <<<"$OUT"
    if [ "$mtype" = DIMENSIONAL ] && [ "$mdim" = SERVICE ]; then
      S3_MON=ok; part ok "monitor $MONITOR_NAME (DIMENSIONAL/SERVICE)"
    else
      # a monitor's type cannot be updated, only deleted and recreated
      S3_MON=DRIFT; part DRIFT "monitor $MONITOR_NAME is $mtype/$mdim, want DIMENSIONAL/SERVICE (delete it by hand, then --apply)"
    fi
  fi
  if ! aws_try ce get-anomaly-subscriptions --output text --query \
        "AnomalySubscriptions[?SubscriptionName=='$SUB_NAME'].[SubscriptionArn,Frequency,ThresholdExpression.Dimensions.Key,ThresholdExpression.Dimensions.MatchOptions[0],ThresholdExpression.Dimensions.Values[0],join(',',Subscribers[].Address),join(',',MonitorArnList)] | [0]"; then
    part ERROR "ce get-anomaly-subscriptions: $ERR"; S3_SUB=ERROR; return 0
  fi
  if [ -z "$OUT" ] || [ "$OUT" = None ]; then
    part MISSING "subscription $SUB_NAME"; return 0
  fi
  IFS=$'\t' read -r S3_SUBARN f_freq f_key f_match f_val f_subs f_mons <<<"$OUT"
  [ "$f_freq" = DAILY ]                          || d="$d frequency=$f_freq"
  [ "$f_key" = ANOMALY_TOTAL_IMPACT_ABSOLUTE ]   || d="$d threshold_key=$f_key"
  [ "$f_match" = GREATER_THAN_OR_EQUAL ]         || d="$d match=$f_match"
  num_eq "${f_val:-x}" "$ANOMALY_MIN_USD" 2>/dev/null || d="$d threshold=\$$f_val (want \$$ANOMALY_MIN_USD)"
  has_email "$f_subs"                            || d="$d subscribers=$f_subs"
  if [ -n "$MONITOR_ARN" ]; then
    case ",$f_mons," in *",$MONITOR_ARN,"*) ;; *) d="$d does not watch monitor $MONITOR_NAME" ;; esac
  fi
  if [ -n "$d" ]; then S3_SUB=DRIFT; part DRIFT "subscription $SUB_NAME:$d"
  else S3_SUB=ok; part ok "subscription $SUB_NAME DAILY, total impact >= \$$ANOMALY_MIN_USD, to $f_subs"; fi
}
fix_3() {
  if [ "$S3_MON" = DRIFT ]; then die "monitor $MONITOR_NAME has the wrong type; delete it by hand (aws ce delete-anomaly-monitor) and re-run"; fi
  if [ "$S3_MON" = MISSING ]; then
    MONITOR_ARN=$(run aws ce create-anomaly-monitor --query MonitorArn --output text --anomaly-monitor \
      "$(jq -nc --arg n "$MONITOR_NAME" '{MonitorName: $n, MonitorType: "DIMENSIONAL", MonitorDimension: "SERVICE"}')")
    [ -n "$MONITOR_ARN" ] || MONITOR_ARN="<arn of monitor $MONITOR_NAME, printed by the create above>"
  fi
  if [ "$S3_SUB" = MISSING ]; then
    run aws ce create-anomaly-subscription --anomaly-subscription "$(jq -nc \
      --arg n "$SUB_NAME" --arg m "$MONITOR_ARN" --arg e "$ALERT_EMAIL" --argjson t "$(threshold_expr)" \
      '{SubscriptionName: $n, MonitorArnList: [$m], Subscribers: [{Address: $e, Type: "EMAIL"}],
        Frequency: "DAILY", ThresholdExpression: $t}')"
  elif [ "$S3_SUB" = DRIFT ]; then
    run aws ce update-anomaly-subscription --subscription-arn "$S3_SUBARN" --frequency DAILY \
      --monitor-arn-list "$MONITOR_ARN" --subscribers "Address=$ALERT_EMAIL,Type=EMAIL" \
      --threshold-expression "$(threshold_expr)"
  fi
}

# ---- 4. budgets ---------------------------------------------------------------
budget_json() {   # budget_json <name> <limit usd> <usage type or "">
  # CostTypes mirror the legacy budget, so the two are comparable (credits excluded, tax/support included)
  jq -nc --arg n "$1" --arg l "$2" --arg u "$3" '
    {BudgetName: $n, BudgetLimit: {Amount: $l, Unit: "USD"}, TimeUnit: "MONTHLY", BudgetType: "COST",
     CostTypes: {IncludeTax: true, IncludeSubscription: true, UseBlended: false, IncludeRefund: false,
                 IncludeCredit: false, IncludeUpfront: true, IncludeRecurring: true,
                 IncludeOtherSubscription: true, IncludeSupport: true, IncludeDiscount: true,
                 UseAmortized: false}}
    + (if $u == "" then {} else {CostFilters: {UsageType: [$u]}} end)'
}
notif_json() {    # notif_json <ACTUAL|FORECASTED> <percent>
  jq -nc --arg t "$1" --argjson p "$2" \
    '{NotificationType: $t, ComparisonOperator: "GREATER_THAN", Threshold: $p, ThresholdType: "PERCENTAGE"}'
}
subscribers_json() { jq -nc --arg e "$ALERT_EMAIL" '[{SubscriptionType: "EMAIL", Address: $e}]'; }
nws_json() {      # nws_json <"TYPE PCT" lines> -> --notifications-with-subscribers
  local t p items=""
  while read -r t p; do
    [ -n "$t" ] || continue
    items="$items$(jq -nc --argjson n "$(notif_json "$t" "$p")" --argjson s "$(subscribers_json)" '{Notification: $n, Subscribers: $s}')"$'\n'
  done <<<"$1"
  printf '%s' "$items" | jq -sc .
}

# budget_eval <key> <name> <limit> <usage type or ""> <notification lines>
# sets BST_<key> (ok|DRIFT|MISSING|ERROR), BM_<key> (missing notification lines), BS_<key> (notifications lacking the email)
budget_eval() {
  local key=$1 name=$2 limit=$3 ut=$4 notifs=$5 st=ok miss="" nosub="" d=""
  local b_amt b_unit b_tu b_bt b_filt t p got subs
  if ! aws_try budgets describe-budget --account-id "$acct" --budget-name "$name" --output text \
        --query 'Budget.[BudgetLimit.Amount,BudgetLimit.Unit,TimeUnit,BudgetType,join(`,`,CostFilters.UsageType||`[]`)]'; then
    if is_absent; then part MISSING "budget $name"; st=MISSING; miss=$notifs
    else part ERROR "budgets describe-budget $name: $ERR"; st=ERROR; fi
  else
    IFS=$'\t' read -r b_amt b_unit b_tu b_bt b_filt <<<"$OUT"
    num_eq "$b_amt" "$limit"  || d="$d limit=\$$b_amt (want \$$limit)"
    [ "$b_unit" = USD ]       || d="$d unit=$b_unit"
    [ "$b_tu" = MONTHLY ]     || d="$d time_unit=$b_tu"
    [ "$b_bt" = COST ]        || d="$d type=$b_bt"
    [ "${b_filt:-}" = "$ut" ] || d="$d usage_type_filter='${b_filt:-}' (want '$ut')"
    if aws_try budgets describe-notifications-for-budget --account-id "$acct" --budget-name "$name" --output text \
         --query "Notifications[].[NotificationType,ComparisonOperator,Threshold,ThresholdType||'PERCENTAGE']"; then
      got=$OUT
    else
      got=""
    fi
    while read -r t p; do
      [ -n "$t" ] || continue
      if printf '%s\n' "$got" | awk -F'\t' -v t="$t" -v p="$p" \
           '$1 == t && $2 == "GREATER_THAN" && $3 + 0 == p + 0 && $4 == "PERCENTAGE" { f = 1 } END { exit !f }'; then
        aws_try budgets describe-subscribers-for-notification --account-id "$acct" --budget-name "$name" \
          --notification "$(notif_json "$t" "$p")" --query 'Subscribers[].Address' --output text || true
        subs=$OUT
        has_email "$subs" || nosub="$nosub$t $p"$'\n'
      else
        miss="$miss$t $p"$'\n'
      fi
    done <<<"$notifs"
    [ -z "$miss" ]  || d="$d missing notifications: $(printf '%s' "$miss" | tr '\n' ',' | sed 's/,$//')"
    [ -z "$nosub" ] || d="$d notifications without $ALERT_EMAIL: $(printf '%s' "$nosub" | tr '\n' ',' | sed 's/,$//')"
    if [ -n "$d" ]; then st=DRIFT; part DRIFT "budget $name:$d"
    else part ok "budget $name \$$limit/month${ut:+ ($ut)}, notifications $(printf '%s' "$notifs" | tr '\n' ',' | sed 's/,$//')"; fi
  fi
  printf -v "BST_$key" '%s' "$st"; printf -v "BM_$key" '%s' "$miss"; printf -v "BS_$key" '%s' "$nosub"
}
budget_fix() {    # budget_fix <key> <name> <limit> <usage type or ""> <notification lines>
  local key=$1 name=$2 limit=$3 ut=$4 notifs=$5 st miss nosub t p
  local v
  v="BST_$key"; st=${!v}; v="BM_$key"; miss=${!v}; v="BS_$key"; nosub=${!v}
  case $st in
    MISSING)
      run aws budgets create-budget --account-id "$acct" --budget "$(budget_json "$name" "$limit" "$ut")" \
        --notifications-with-subscribers "$(nws_json "$notifs")"
      return 0 ;;
    DRIFT)
      run aws budgets update-budget --account-id "$acct" --new-budget "$(budget_json "$name" "$limit" "$ut")" ;;
    *) return 0 ;;
  esac
  while read -r t p; do
    [ -n "$t" ] || continue
    run aws budgets create-notification --account-id "$acct" --budget-name "$name" \
      --notification "$(notif_json "$t" "$p")" --subscribers "$(subscribers_json)"
  done <<<"$miss"
  while read -r t p; do
    [ -n "$t" ] || continue
    run aws budgets create-subscriber --account-id "$acct" --budget-name "$name" \
      --notification "$(notif_json "$t" "$p")" --subscriber "$(jq -nc --arg e "$ALERT_EMAIL" '{SubscriptionType: "EMAIL", Address: $e}')"
  done <<<"$nosub"
}
BST_total=""; BST_egress=""; BM_total=""; BM_egress=""; BS_total=""; BS_egress=""
chk_4() {
  gstart
  budget_eval total  "$BUDGET_TOTAL"  "$BUDGET_TOTAL_USD"  ""            "$NOTIFS_TOTAL"
  budget_eval egress "$BUDGET_EGRESS" "$BUDGET_EGRESS_USD" "$USAGE_TYPE" "$NOTIFS_EGRESS"
}
fix_4() {
  budget_fix total  "$BUDGET_TOTAL"  "$BUDGET_TOTAL_USD"  ""            "$NOTIFS_TOTAL"
  budget_fix egress "$BUDGET_EGRESS" "$BUDGET_EGRESS_USD" "$USAGE_TYPE" "$NOTIFS_EGRESS"
}
# an old monthly budget far below the baseline is permanently in ALARM, so its emails are noise
warn_legacy() {
  local name amt found=0
  aws_try budgets describe-budgets --account-id "$acct" --output text --query \
    "Budgets[?BudgetType=='COST' && TimeUnit=='MONTHLY'].[BudgetName,BudgetLimit.Amount]" || return 0
  while IFS=$'\t' read -r name amt; do
    [ -n "$name" ] || continue
    case $name in msens-*) continue ;; esac
    if awk -v a="$amt" -v b="$BASELINE_USD" 'BEGIN { exit !(a + 0 < b + 0) }'; then
      printf '%-4s %-22s %-8s %s\n' "[4]" "legacy budget" WARN \
        "\"$name\" is unrealistic (limit \$$(awk -v a="$amt" 'BEGIN { printf "%.0f", a }') < baseline \$$BASELINE_USD/month): permanently in ALARM, so its emails are noise; delete it by hand (aws/README.md)"
      found=1
    fi
  done <<<"$OUT"
  return 0
}

# ---- 5. s3 request metrics + download alarm -------------------------------------
S5_CFG=""; S5_ALARM=""
chk_5() {
  gstart; S5_CFG=MISSING
  local c_id c_prefix
  if aws_try s3api get-bucket-metrics-configuration --bucket "$SRC_BUCKET" --id "$METRICS_ID" --output text \
       --query 'MetricsConfiguration.[Id,Filter.Prefix]'; then
    IFS=$'\t' read -r c_id c_prefix <<<"$OUT"
    if [ "$c_prefix" = "$METRICS_PREFIX" ]; then S5_CFG=ok; part ok "metrics config $METRICS_ID on $SRC_BUCKET (prefix $METRICS_PREFIX)"
    else S5_CFG=DRIFT; part DRIFT "metrics config $METRICS_ID has prefix '$c_prefix', want '$METRICS_PREFIX'"; fi
  elif is_absent; then
    part MISSING "metrics config $METRICS_ID on $SRC_BUCKET"
  else
    S5_CFG=ERROR; part ERROR "s3api get-bucket-metrics-configuration: $ERR"
  fi
  alarm_eval S5_ALARM "$ALARM_S3" AWS/S3 BytesDownloaded "BucketName=$SRC_BUCKET,FilterId=$METRICS_ID" 86400 \
    "$(gb_bytes "$S3_DL_DAY_GB")" "$S3_DL_DAY_GB"
}
fix_5() {
  if [ "$S5_CFG" != ok ]; then
    run aws s3api put-bucket-metrics-configuration --bucket "$SRC_BUCKET" --id "$METRICS_ID" \
      --metrics-configuration "$(jq -nc --arg i "$METRICS_ID" --arg p "$METRICS_PREFIX" '{Id: $i, Filter: {Prefix: $p}}')"
  fi
  alarm_fix "$S5_ALARM" "$ALARM_S3" "$METRICS_PREFIX of $SRC_BUCKET served more than $S3_DL_DAY_GB GB in one day" \
    AWS/S3 BytesDownloaded "BucketName=$SRC_BUCKET,FilterId=$METRICS_ID" 86400 "$(gb_bytes "$S3_DL_DAY_GB")"
}

# ---- 6. s3 server access logging ------------------------------------------------
S6_BUCKET=0; S6_PAB=MISSING; S6_POL=MISSING; S6_LC=MISSING; S6_LOG=MISSING; S6_POLICY=""; S6_LCJSON=""
log_statement() {
  jq -nc --arg sid "$LOG_SID" --arg res "arn:aws:s3:::$LOG_BUCKET/$LOG_PREFIX*" \
    --arg src "arn:aws:s3:::$SRC_BUCKET" --arg acct "$acct" '
    {Sid: $sid, Effect: "Allow", Principal: {Service: "logging.s3.amazonaws.com"}, Action: "s3:PutObject",
     Resource: $res, Condition: {ArnLike: {"aws:SourceArn": $src}, StringEquals: {"aws:SourceAccount": $acct}}}'
}
log_rule() {
  jq -nc --arg id "$LOG_RULE" --arg p "s3-access/" --argjson d "$LOG_DAYS" \
    '{ID: $id, Status: "Enabled", Filter: {Prefix: $p}, Expiration: {Days: $d},
      AbortIncompleteMultipartUpload: {DaysAfterInitiation: 7}}'
}
chk_6() {
  gstart; S6_BUCKET=0; S6_PAB=MISSING; S6_POL=MISSING; S6_LC=MISSING; S6_LOG=MISSING; S6_POLICY=""; S6_LCJSON=""
  local want f
  if aws_try s3api head-bucket --bucket "$LOG_BUCKET"; then
    S6_BUCKET=1; part ok "log bucket $LOG_BUCKET exists"
  elif is_absent; then
    part MISSING "log bucket $LOG_BUCKET"
  else
    part ERROR "s3api head-bucket $LOG_BUCKET: $ERR"
  fi
  if [ "$S6_BUCKET" = 1 ]; then
    # block public access: all four true
    if aws_try s3api get-public-access-block --bucket "$LOG_BUCKET" --output text \
         --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]'; then
      if [ "$OUT" = "True	True	True	True" ]; then S6_PAB=ok; part ok "log bucket blocks all public access"
      else S6_PAB=DRIFT; part DRIFT "log bucket public-access-block is not all-true: $OUT"; fi
    elif is_absent; then part MISSING "log bucket public-access-block"
    else S6_PAB=ERROR; part ERROR "s3api get-public-access-block: $ERR"; fi
    # bucket policy: our statement present and exact; other statements are left alone
    if aws_try s3api get-bucket-policy --bucket "$LOG_BUCKET" --query Policy --output text; then
      S6_POLICY=$OUT; want=$(log_statement)
      if printf '%s' "$S6_POLICY" | jq -e --argjson w "$want" '.Statement | map(select(. == $w)) | length == 1' >/dev/null; then
        S6_POL=ok; part ok "log bucket policy lets logging.s3.amazonaws.com write $LOG_PREFIX only for $SRC_BUCKET/$acct"
      elif printf '%s' "$S6_POLICY" | jq -e --arg s "$LOG_SID" '.Statement | map(select(.Sid == $s)) | length > 0' >/dev/null; then
        S6_POL=DRIFT; part DRIFT "log bucket policy statement $LOG_SID differs from the expected one"
      else
        part MISSING "log bucket policy lacks statement $LOG_SID"
      fi
    elif is_absent; then part MISSING "log bucket policy"
    else S6_POL=ERROR; part ERROR "s3api get-bucket-policy: $ERR"; fi
    # lifecycle: our rule present, enabled, expiring at LOG_DAYS under s3-access/
    if aws_try s3api get-bucket-lifecycle-configuration --bucket "$LOG_BUCKET" --output json; then
      S6_LCJSON=$OUT
      f=$(printf '%s' "$OUT" | jq -r --arg id "$LOG_RULE" '[.Rules[] | select(.ID == $id)] | if length == 0 then "none"
            else .[0] | "\(.Status) \(.Expiration.Days // "none") \(.Filter.Prefix // "none")" end')
      if [ "$f" = none ]; then part MISSING "log bucket lifecycle lacks rule $LOG_RULE"
      elif [ "$f" = "Enabled $LOG_DAYS s3-access/" ]; then S6_LC=ok; part ok "log objects expire after $LOG_DAYS days"
      else S6_LC=DRIFT; part DRIFT "lifecycle rule $LOG_RULE is '$f', want 'Enabled $LOG_DAYS s3-access/'"; fi
    elif is_absent; then part MISSING "log bucket lifecycle (expire after $LOG_DAYS days)"
    else S6_LC=ERROR; part ERROR "s3api get-bucket-lifecycle-configuration: $ERR"; fi
  fi
  # logging on the source bucket
  if aws_try s3api get-bucket-logging --bucket "$SRC_BUCKET" --output text \
       --query 'LoggingEnabled.[TargetBucket,TargetPrefix]'; then
    if [ "$OUT" = "$LOG_BUCKET	$LOG_PREFIX" ]; then S6_LOG=ok; part ok "$SRC_BUCKET logs to $LOG_BUCKET/$LOG_PREFIX"
    elif [ "$OUT" = None ] || [ -z "$OUT" ]; then part MISSING "access logging on $SRC_BUCKET is off"
    else S6_LOG=DRIFT; part DRIFT "$SRC_BUCKET logs to '$OUT', want '$LOG_BUCKET $LOG_PREFIX'"; fi
  else
    S6_LOG=ERROR; part ERROR "s3api get-bucket-logging: $ERR"
  fi
}
fix_6() {
  local stmt policy rules empty='{}'
  if [ "$S6_BUCKET" = 0 ]; then
    if [ "$REGION" = us-east-1 ]; then run aws s3api create-bucket --bucket "$LOG_BUCKET"
    else run aws s3api create-bucket --bucket "$LOG_BUCKET" --create-bucket-configuration "LocationConstraint=$REGION"; fi
  fi
  if [ "$S6_PAB" != ok ]; then
    run aws s3api put-public-access-block --bucket "$LOG_BUCKET" --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  fi
  if [ "$S6_POL" != ok ]; then
    # put-bucket-policy replaces the whole policy, so merge: keep every other statement
    stmt=$(log_statement)
    policy=$(printf '%s' "${S6_POLICY:-$empty}" | jq -c --argjson s "$stmt" --arg sid "$LOG_SID" \
      '{Version: (.Version // "2012-10-17"), Statement: ((.Statement // []) | map(select(.Sid != $sid)) + [$s])}')
    run aws s3api put-bucket-policy --bucket "$LOG_BUCKET" --policy "$policy"
  fi
  if [ "$S6_LC" != ok ]; then
    # put-bucket-lifecycle-configuration also replaces everything: keep every other rule
    rules=$(printf '%s' "${S6_LCJSON:-$empty}" | jq -c --argjson r "$(log_rule)" --arg id "$LOG_RULE" \
      '{Rules: ((.Rules // []) | map(select(.ID != $id)) + [$r])}')
    run aws s3api put-bucket-lifecycle-configuration --bucket "$LOG_BUCKET" --lifecycle-configuration "$rules"
  fi
  if [ "$S6_LOG" != ok ]; then
    run aws s3api put-bucket-logging --bucket "$SRC_BUCKET" --bucket-logging-status \
      "$(jq -nc --arg b "$LOG_BUCKET" --arg p "$LOG_PREFIX" '{LoggingEnabled: {TargetBucket: $b, TargetPrefix: $p}}')"
  fi
}

# ---- main -----------------------------------------------------------------------
TITLES_1="sns topic"; TITLES_2="network alarms"; TITLES_3="cost anomaly"
TITLES_4="budgets"; TITLES_5="s3 request metrics"; TITLES_6="s3 access logging"

if [ "$MODE" = test-alarm ]; then
  aws_try cloudwatch describe-alarms --alarm-names "$ALARM_HOUR" --query 'length(MetricAlarms)' --output text \
    || die "cloudwatch describe-alarms: $ERR"
  [ "$OUT" = 1 ] || die "alarm $ALARM_HOUR does not exist — run --apply first"
  aws cloudwatch set-alarm-state --alarm-name "$ALARM_HOUR" --state-value ALARM \
    --state-reason "guardrails.sh --test-alarm: seeded fault to prove the alert path; not a real network event"
  say "forced $ALARM_HOUR to ALARM: one email should reach the SNS subscriber(s) within a minute or two"
  say "nothing to clean up — the alarm returns to OK by itself at its next evaluation (the instance is not above the threshold)"
  say "no email? check that the subscription is confirmed:  $0 --check"
  exit 0
fi

run_checks() {
  local n t
  for n in 1 2 3 4 5 6; do
    "chk_$n"
    t="TITLES_$n"
    report "$n" "${!t}"
    if [ "$n" = 4 ]; then warn_legacy; fi
    if acting && [ "$1" = fix ]; then "fix_$n"; fi
  done
}

if [ "$MODE" = check ]; then
  run_checks nofix
  if [ "$FAILS" -ne 0 ]; then say "$FAILS guardrail(s) not ok — fix with: ALERT_EMAIL=you@example.org $0 --apply"; exit 1; fi
  say "all six guardrails ok"
  exit 0
fi

if [ "$MODE" = plan ]; then say "plan only — nothing below is run; reads were the only calls made"; fi
run_checks fix
if [ "$MODE" = plan ]; then say "end of plan"; exit 0; fi

# apply: prove the result, do not assume it
say "re-checking"
FAILS=0; MODE=check
run_checks nofix
if [ "$FAILS" -ne 0 ]; then say "$FAILS guardrail(s) still not ok after --apply"; exit 1; fi
say "converged; confirm the SNS email, then run: $0 --test-alarm"
