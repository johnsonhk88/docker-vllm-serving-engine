#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROM="${ROOT}/monitoring/prometheus/prometheus.yml"
COMPOSE="${ROOT}/monitoring/docker-compose.yml"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

[[ -f "${PROM}" ]] || fail "missing ${PROM}"
[[ -f "${COMPOSE}" ]] || fail "missing ${COMPOSE}"

grep -q 'job_name: vllm' "${PROM}" || fail "prometheus.yml missing job_name: vllm"
grep -q 'host.docker.internal:8000' "${PROM}" || fail "prometheus.yml missing host.docker.internal:8000"
grep -q 'host.docker.internal:8091' "${PROM}" || fail "prometheus.yml missing host.docker.internal:8091"
grep -q 'metrics_path: /metrics' "${PROM}" || fail "prometheus.yml missing metrics_path: /metrics"
grep -q 'dcgm-exporter:9400' "${PROM}" || fail "prometheus.yml missing dcgm-exporter:9400"
grep -q 'node-exporter:9100' "${PROM}" || fail "prometheus.yml missing node-exporter:9100"
pass "prometheus.yml scrape jobs"

grep -q 'prometheus:' "${COMPOSE}" || fail "compose missing prometheus service"
grep -q 'grafana:' "${COMPOSE}" || fail "compose missing grafana service"
grep -q 'dcgm-exporter:' "${COMPOSE}" || fail "compose missing dcgm-exporter service"
grep -q 'node-exporter:' "${COMPOSE}" || fail "compose missing node-exporter service"
grep -q '9090:9090' "${COMPOSE}" || fail "compose missing 9090:9090"
grep -q '3000:3000' "${COMPOSE}" || fail "compose missing 3000:3000"
pass "compose services and ports"
