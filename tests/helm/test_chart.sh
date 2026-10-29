#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHART="${ROOT}/helm/vllm"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

command -v helm >/dev/null 2>&1 || fail "helm is required"

render_deploy() {
  helm template t "${CHART}" --show-only templates/deployment.yaml "$@"
}

default_deploy="$(render_deploy)"
printf '%s\n' "${default_deploy}" | grep -q -- '--max-num-seqs' && fail "default render must not contain --max-num-seqs"
printf '%s\n' "${default_deploy}" | grep -q -- '--tensor-parallel-size' && fail "default render must not contain --tensor-parallel-size"
pass "default omits maxNumSeqs and tensorParallelSize flags"

text_knobs="$(render_deploy --set maxNumSeqs=32 --set tensorParallelSize=2)"
printf '%s\n' "${text_knobs}" | grep -q -- '--max-num-seqs' || fail "text mode missing --max-num-seqs"
printf '%s\n' "${text_knobs}" | grep -q -- '32' || fail "text mode missing maxNumSeqs value 32"
printf '%s\n' "${text_knobs}" | grep -q -- '--tensor-parallel-size' || fail "text mode missing --tensor-parallel-size"
printf '%s\n' "${text_knobs}" | grep -q -- '2' || fail "text mode missing tensorParallelSize value 2"
pass "text mode renders maxNumSeqs=32 and tensorParallelSize=2"

omni_knobs="$(render_deploy --set mode=omni --set maxNumSeqs=32 --set tensorParallelSize=2)"
printf '%s\n' "${omni_knobs}" | grep -q -- '--max-num-seqs' || fail "omni mode missing --max-num-seqs"
printf '%s\n' "${omni_knobs}" | grep -q -- '32' || fail "omni mode missing maxNumSeqs value 32"
printf '%s\n' "${omni_knobs}" | grep -q -- '--tensor-parallel-size' || fail "omni mode missing --tensor-parallel-size"
printf '%s\n' "${omni_knobs}" | grep -q -- '2' || fail "omni mode missing tensorParallelSize value 2"
pass "omni mode renders maxNumSeqs=32 and tensorParallelSize=2"

render() {
  helm template t "${CHART}" "$@"
}

default_all="$(render)"
printf '%s\n' "${default_all}" | grep -q 'kind: ServiceMonitor' && fail "default render must not include ServiceMonitor"
pass "default omits ServiceMonitor"

monitored="$(render --set monitoring.enabled=true)"
printf '%s\n' "${monitored}" | grep -q 'kind: ServiceMonitor' || fail "monitoring.enabled=true missing kind: ServiceMonitor"
printf '%s\n' "${monitored}" | grep -q 'path: /metrics' || fail "ServiceMonitor missing path: /metrics"
printf '%s\n' "${monitored}" | grep -q 'port: http' || fail "ServiceMonitor missing port: http"
printf '%s\n' "${monitored}" | grep -q 'interval: 15s' || fail "ServiceMonitor missing interval: 15s"
pass "monitoring.enabled=true renders ServiceMonitor on /metrics"
