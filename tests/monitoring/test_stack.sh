#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROM="${ROOT}/monitoring/prometheus/prometheus.yml"
RULE="${ROOT}/monitoring/prometheus/alerts.yml"
COMPOSE="${ROOT}/monitoring/docker-compose.yml"
DASH="${ROOT}/monitoring/grafana/dashboards/vllm-capacity.json"
DS="${ROOT}/monitoring/grafana/provisioning/datasources/datasource.yml"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

[[ -f "${PROM}" ]] || fail "missing ${PROM}"
[[ -f "${RULE}" ]] || fail "missing ${RULE}"
[[ -f "${COMPOSE}" ]] || fail "missing ${COMPOSE}"

grep -q 'job_name: vllm' "${PROM}" || fail "prometheus.yml missing job_name: vllm"
grep -q 'host.docker.internal:8000' "${PROM}" || fail "prometheus.yml missing host.docker.internal:8000"
grep -q 'host.docker.internal:8091' "${PROM}" || fail "prometheus.yml missing host.docker.internal:8091"
grep -q 'metrics_path: /metrics' "${PROM}" || fail "prometheus.yml missing metrics_path: /metrics"
grep -q 'dcgm-exporter:9400' "${PROM}" || fail "prometheus.yml missing dcgm-exporter:9400"
grep -q 'node-exporter:9100' "${PROM}" || fail "prometheus.yml missing node-exporter:9100"
grep -q 'rule_files:' "${PROM}" || fail "prometheus.yml missing rule_files"
grep -q '/etc/prometheus/alerts.yml' "${PROM}" || fail "prometheus.yml missing alerts.yml rule file"
pass "prometheus.yml scrape jobs and rule file"

grep -q 'prometheus:' "${COMPOSE}" || fail "compose missing prometheus service"
grep -q 'grafana:' "${COMPOSE}" || fail "compose missing grafana service"
grep -q 'dcgm-exporter:' "${COMPOSE}" || fail "compose missing dcgm-exporter service"
grep -q 'node-exporter:' "${COMPOSE}" || fail "compose missing node-exporter service"
grep -q '9090:9090' "${COMPOSE}" || fail "compose missing 9090:9090"
grep -q '3000:3000' "${COMPOSE}" || fail "compose missing 3000:3000"
grep -q 'alerts.yml:/etc/prometheus/alerts.yml:ro' "${COMPOSE}" || fail "compose missing alerts.yml mount"
pass "compose services, ports, and alert mount"

for alert in VLLMMetricsDown VLLMQueueBacklog VLLMHighTTFT \
    VLLMHighInterTokenLatency VLLMKVCacheSaturated DCGMTargetDown NodeExporterDown; do
    grep -q "alert: ${alert}" "${RULE}" || fail "alerts.yml missing ${alert}"
done
grep -q 'vllm:num_requests_waiting' "${RULE}" || fail "alerts.yml missing waiting-request alert"
grep -q 'vllm:kv_cache_usage_perc' "${RULE}" || fail "alerts.yml missing KV-cache alert"
grep -q 'vllm:time_to_first_token_seconds_bucket' "${RULE}" || fail "alerts.yml missing TTFT alert"
grep -q 'vllm:inter_token_latency_seconds_bucket' "${RULE}" || fail "alerts.yml missing ITL alert"
pass "alerts.yml rules"

python3 -m json.tool "${DASH}" >/dev/null || fail "dashboard JSON is invalid"
grep -q '"uid": "vllm-capacity"' "${DASH}" || fail "dashboard missing uid vllm-capacity"
grep -q 'vLLM Capacity' "${DASH}" || fail "dashboard missing title vLLM Capacity"
grep -q 'vllm:num_requests_waiting' "${DASH}" || fail "dashboard missing vllm:num_requests_waiting"
grep -q 'vllm:num_requests_running' "${DASH}" || fail "dashboard missing vllm:num_requests_running"
grep -q 'vllm:prompt_tokens_total' "${DASH}" || fail "dashboard missing prompt token counter"
grep -q 'vllm:generation_tokens_total' "${DASH}" || fail "dashboard missing generation token counter"
grep -q 'vllm:kv_cache_usage_perc' "${DASH}" || fail "dashboard missing kv_cache_usage_perc"
grep -q 'vllm:time_to_first_token_seconds_bucket' "${DASH}" || fail "dashboard missing TTFT histogram"
grep -q 'vllm:inter_token_latency_seconds_bucket' "${DASH}" || fail "dashboard missing ITL histogram"
grep -q 'vllm:e2e_request_latency_seconds_bucket' "${DASH}" || fail "dashboard missing E2E histogram"
grep -q 'DCGM_FI_DEV_GPU_UTIL' "${DASH}" || fail "dashboard missing DCGM_FI_DEV_GPU_UTIL"
grep -q 'DCGM_FI_DEV_FB_USED' "${DASH}" || fail "dashboard missing DCGM_FI_DEV_FB_USED"
grep -Fq 'DCGM_FI_DEV_FB_USED * 1024 * 1024' "${DASH}" || fail "FB_USED is megabytes; convert to bytes before unit bytes"
if grep -q 'avg_prompt_throughput_toks_per_s' "${DASH}"; then
    fail "dashboard still uses the removed vLLM throughput gauge"
fi
if grep -q 'avg_generation_throughput_toks_per_s' "${DASH}"; then
    fail "dashboard still uses the removed vLLM throughput gauge"
fi
if grep -q 'gpu_cache_usage_perc' "${DASH}"; then
    fail "dashboard still uses the renamed gpu_cache_usage_perc metric"
fi
if grep -q 'decbytes' "${DASH}"; then
    fail "do not use decbytes for DCGM_FI_DEV_FB_USED (values are already MB)"
fi
grep -q 'type: prometheus' "${DS}" || fail "datasource missing type: prometheus"
grep -q 'http://prometheus:9090' "${DS}" || fail "datasource missing http://prometheus:9090"
pass "grafana dashboard, latency panels, and datasource"
