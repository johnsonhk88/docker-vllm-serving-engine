#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

cd "${ROOT}"

grep -q 'docker compose -f monitoring/docker-compose.yml up -d' monitoring/README.md README.md \
  || fail "compose bring-up command missing from monitoring/README.md or README.md"
grep -q 'monitoring.enabled' k8s/README.md monitoring/README.md \
  || fail "monitoring.enabled missing from k8s/README.md or monitoring/README.md"
grep -q 'autoscaling.enabled' k8s/README.md monitoring/README.md \
  || fail "autoscaling.enabled missing from k8s/README.md or monitoring/README.md"
grep -q 'num_requests_waiting' monitoring/README.md \
  || fail "num_requests_waiting missing from monitoring/README.md"
grep -q 'KEDA' monitoring/README.md k8s/README.md \
  || fail "KEDA missing from monitoring/README.md or k8s/README.md"
grep -q 'microk8s enable' monitoring/README.md \
  || fail "microk8s enable missing from monitoring/README.md"
grep -q 'tensorParallelSize' k8s/README.md \
  || fail "tensorParallelSize missing from k8s/README.md"
grep -q 'maxNumSeqs' k8s/README.md \
  || fail "maxNumSeqs missing from k8s/README.md"
pass "operator documentation contains required monitoring contracts"
