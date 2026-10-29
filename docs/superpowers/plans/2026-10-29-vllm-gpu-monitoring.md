# vLLM GPU Monitoring & KEDA Scaling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Prometheus/Grafana/DCGM monitoring for vLLM on Docker and Kubernetes, first-class Helm knobs for `--max-num-seqs` and `--tensor-parallel-size`, and optional KEDA replica autoscaling from `vllm:num_requests_waiting`.

**Architecture:** Helm templates emit ServiceMonitor and ScaledObject only when enabled. Deployment omits `spec.replicas` when KEDA owns scaling. A self-contained Compose stack under `monitoring/` scrapes host vLLM plus DCGM/node-exporter and provisions the same Grafana dashboard.

**Tech Stack:** Helm, KEDA ScaledObject, Prometheus Operator ServiceMonitor, Docker Compose, Prometheus, Grafana, DCGM exporter, node-exporter, Bash helm-template tests.

**Spec:** `docs/superpowers/specs/2026-10-29-vllm-gpu-monitoring-design.md`

## Global Constraints

- `monitoring.enabled` default `false`; `autoscaling.enabled` default `false`.
- Do not vendor kube-prometheus-stack or KEDA as chart dependencies.
- Do not set Deployment `spec.replicas` when `autoscaling.enabled` is true.
- `maxNumSeqs` / `tensorParallelSize` default `null` (omit the vLLM flags).
- KEDA PromQL default: `sum(vllm:num_requests_waiting)` threshold `"5"`.
- ServiceMonitor scrapes named port `http` path `/metrics`.
- Do not change `src/run-vllm-k8s.sh` CLI; do not auto-wire `nvidia.com/gpu` from TP.
- Chart version becomes `0.2.0`.

## Review Focus

- Cluster without Prometheus Operator: default render must not include `ServiceMonitor` (Task 2).
- Cluster without KEDA: default render must not include `ScaledObject` (Task 3).
- Autoscaling on: Deployment must not contain `replicas:` so KEDA is the only controller (Task 3).
- Omni mode still passes `--max-num-seqs` / `--tensor-parallel-size` on the omni command args (Task 1).
- Compose scrape targets include both `8000` and `8091` so text and omni Docker launches are visible (Task 4).

## File structure

- Create: `tests/helm/test_chart.sh` — helm template assertions
- Create: `helm/vllm/templates/servicemonitor.yaml`
- Create: `helm/vllm/templates/scaledobject.yaml`
- Create: `monitoring/docker-compose.yml`
- Create: `monitoring/prometheus/prometheus.yml`
- Create: `monitoring/grafana/provisioning/datasources/datasource.yml`
- Create: `monitoring/grafana/provisioning/dashboards/dashboards.yml`
- Create: `monitoring/grafana/dashboards/vllm-capacity.json`
- Create: `monitoring/README.md`
- Modify: `helm/vllm/values.yaml`
- Modify: `helm/vllm/templates/deployment.yaml`
- Modify: `helm/vllm/Chart.yaml` (`version: 0.2.0`)
- Modify: `README.md`, `k8s/README.md`

---

### Task 1: Helm deploy-time knobs (`maxNumSeqs`, `tensorParallelSize`)

**Files:**
- Create: `tests/helm/test_chart.sh`
- Modify: `helm/vllm/values.yaml`
- Modify: `helm/vllm/templates/deployment.yaml` (args for both text and omni)
- Modify: `helm/vllm/Chart.yaml`

**Interfaces:**
- Consumes: existing `helm/vllm` chart (`gpuMemoryUtilization`, `extraArgs`, text vs omni args)
- Produces: values `maxNumSeqs` (default null), `tensorParallelSize` (default null); when set, both text and omni containers receive `--max-num-seqs <n>` and `--tensor-parallel-size <n>` immediately after the gpu-memory-utilization args; chart `version: 0.2.0`

- [ ] **Step 1: Write the failing tests in `tests/helm/test_chart.sh`**

Executable bash, `set -euo pipefail`, `helm template` into a temp file. Assert:

```bash
# default: flags absent
helm template t ./helm/vllm --show-only templates/deployment.yaml
# must NOT contain --max-num-seqs or --tensor-parallel-size

# knobs on (text)
helm template t ./helm/vllm --set maxNumSeqs=32 --set tensorParallelSize=2 --show-only templates/deployment.yaml
# must contain --max-num-seqs, 32, --tensor-parallel-size, 2

# knobs on (omni)
helm template t ./helm/vllm --set mode=omni --set maxNumSeqs=32 --set tensorParallelSize=2 --show-only templates/deployment.yaml
# same four strings
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/helm/test_chart.sh`
Expected: FAIL (flags not rendered, or script missing)

- [ ] **Step 3: Implement values and deployment args**

`values.yaml`: `maxNumSeqs: null` and `tensorParallelSize: null`.
`deployment.yaml`: in both omni `command/args` and text `args`, after gpu-memory-utilization:

```yaml
{{- if not (or (empty .Values.maxNumSeqs) (eq (toString .Values.maxNumSeqs) "null")) }}
- "--max-num-seqs"
- {{ .Values.maxNumSeqs | quote }}
{{- end }}
{{- if not (or (empty .Values.tensorParallelSize) (eq (toString .Values.tensorParallelSize) "null")) }}
- "--tensor-parallel-size"
- {{ .Values.tensorParallelSize | quote }}
{{- end }}
```

`Chart.yaml`: `version: 0.2.0`

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/helm/test_chart.sh`
Expected: PASS (exit 0)

- [ ] **Step 5: Commit**

```bash
git add tests/helm/test_chart.sh helm/vllm/values.yaml helm/vllm/templates/deployment.yaml helm/vllm/Chart.yaml
git commit -m "feat(helm): add maxNumSeqs and tensorParallelSize values"
```

---

### Task 2: ServiceMonitor (opt-in)

**Files:**
- Create: `helm/vllm/templates/servicemonitor.yaml`
- Modify: `helm/vllm/values.yaml`
- Modify: `tests/helm/test_chart.sh`

**Interfaces:**
- Consumes: `vllm.labels`, `vllm.selectorLabels`, Service port name `http`
- Produces: values `monitoring.enabled` (false), `monitoring.serviceMonitor.{interval=15s,scrapeTimeout=10s,path=/metrics,labels={}}`; when enabled, `kind: ServiceMonitor` scraping port `http` path `/metrics`

- [ ] **Step 1: Extend `tests/helm/test_chart.sh` with failing assertions**

```bash
# default: helm template t ./helm/vllm | grep -c 'kind: ServiceMonitor'  →  0
# enabled: helm template t ./helm/vllm --set monitoring.enabled=true
#   must contain kind: ServiceMonitor, path: /metrics, port: http, interval: 15s
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/helm/test_chart.sh`
Expected: FAIL on ServiceMonitor assertions

- [ ] **Step 3: Implement `servicemonitor.yaml` and `monitoring` values**

Gate the whole file on `.Values.monitoring.enabled`.
`spec.selector.matchLabels` = `vllm.selectorLabels`.
Endpoint: port `http`, path/interval/scrapeTimeout from values.
Merge `monitoring.serviceMonitor.labels` onto metadata labels.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/helm/test_chart.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add helm/vllm/templates/servicemonitor.yaml helm/vllm/values.yaml tests/helm/test_chart.sh
git commit -m "feat(helm): add opt-in ServiceMonitor for /metrics"
```

---

### Task 3: KEDA ScaledObject (opt-in) and replica ownership

**Files:**
- Create: `helm/vllm/templates/scaledobject.yaml`
- Modify: `helm/vllm/templates/deployment.yaml` (`spec.replicas`)
- Modify: `helm/vllm/values.yaml`
- Modify: `tests/helm/test_chart.sh`

**Interfaces:**
- Consumes: Deployment name `vllm.fullname`, values `replicaCount`
- Produces: values `autoscaling.enabled` (false), `minReplicas=1`, `maxReplicas=4`, `pollingInterval=15`, `cooldownPeriod=60`, `prometheus.serverAddress=http://kube-prometheus-stack-prometheus.monitoring.svc:9090`, `prometheus.query=sum(vllm:num_requests_waiting)`, `prometheus.threshold="5"`; when enabled, ScaledObject targets the Deployment and Deployment has no `replicas:` field

- [ ] **Step 1: Extend `tests/helm/test_chart.sh` with failing assertions**

```bash
# default render: no 'kind: ScaledObject'; deployment.yaml contains 'replicas:'
# --set autoscaling.enabled=true:
#   contains kind: ScaledObject
#   contains minReplicaCount: 1
#   contains maxReplicaCount: 4
#   contains sum(vllm:num_requests_waiting)
#   contains threshold: "5"  (or threshold: "5" / '5')
#   --show-only templates/deployment.yaml must NOT match '^  replicas:'
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/helm/test_chart.sh`
Expected: FAIL on ScaledObject / replicas assertions

- [ ] **Step 3: Implement ScaledObject and conditional replicas**

`deployment.yaml`: set `replicas:` only when `not .Values.autoscaling.enabled`.
`scaledobject.yaml`: `apiVersion: keda.sh/v1alpha1`, `scaleTargetRef.name` = fullname, trigger type `prometheus` with serverAddress/query/threshold from values.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/helm/test_chart.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add helm/vllm/templates/scaledobject.yaml helm/vllm/templates/deployment.yaml helm/vllm/values.yaml tests/helm/test_chart.sh
git commit -m "feat(helm): add opt-in KEDA ScaledObject for replica scaling"
```

---

### Task 4: Docker Compose monitoring stack

**Files:**
- Create: `monitoring/docker-compose.yml`
- Create: `monitoring/prometheus/prometheus.yml`
- Create: `tests/monitoring/test_stack.sh`

**Interfaces:**
- Consumes: host vLLM on ports 8000 and 8091 (`/metrics`)
- Produces: compose services `prometheus`, `grafana`, `dcgm-exporter`, `node-exporter`; Prometheus jobs scraping `host.docker.internal:8000`, `host.docker.internal:8091`, `dcgm-exporter:9400`, `node-exporter:9100`

- [ ] **Step 1: Write failing `tests/monitoring/test_stack.sh`**

```bash
grep -q 'job_name: vllm' monitoring/prometheus/prometheus.yml
grep -q 'host.docker.internal:8000' monitoring/prometheus/prometheus.yml
grep -q 'host.docker.internal:8091' monitoring/prometheus/prometheus.yml
grep -q 'metrics_path: /metrics' monitoring/prometheus/prometheus.yml
grep -q 'dcgm-exporter:9400' monitoring/prometheus/prometheus.yml
grep -q 'node-exporter:9100' monitoring/prometheus/prometheus.yml
grep -q 'prometheus:' monitoring/docker-compose.yml
grep -q 'grafana:' monitoring/docker-compose.yml
grep -q 'dcgm-exporter:' monitoring/docker-compose.yml
grep -q 'node-exporter:' monitoring/docker-compose.yml
grep -q '9090:9090' monitoring/docker-compose.yml
grep -q '3000:3000' monitoring/docker-compose.yml
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/monitoring/test_stack.sh`
Expected: FAIL (files missing)

- [ ] **Step 3: Implement compose + Prometheus config**

Pin images: `prom/prometheus:v2.54.1`, `grafana/grafana:11.2.2`, `nvidia/dcgm-exporter:3.3.8-3.6.0-ubuntu22.04`, `prom/node-exporter:v1.8.2`.
Prometheus extra_hosts `host.docker.internal:host-gateway`.
dcgm-exporter: `gpus: all` (compose device reservation).
Grafana provision paths mounted in Task 5; for this task mount `./grafana/provisioning` and `./grafana/dashboards` even if dashboard JSON lands next task — create empty dashboards dir if needed.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/monitoring/test_stack.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add monitoring/docker-compose.yml monitoring/prometheus/prometheus.yml tests/monitoring/test_stack.sh
git commit -m "feat(monitoring): add Compose Prometheus/DCGM/node-exporter stack"
```

---

### Task 5: Grafana dashboard and provisioning

**Files:**
- Create: `monitoring/grafana/provisioning/datasources/datasource.yml`
- Create: `monitoring/grafana/provisioning/dashboards/dashboards.yml`
- Create: `monitoring/grafana/dashboards/vllm-capacity.json`
- Modify: `tests/monitoring/test_stack.sh`

**Interfaces:**
- Consumes: Prometheus at `http://prometheus:9090`
- Produces: datasource type prometheus named `Prometheus`; dashboard UID `vllm-capacity`, title `vLLM Capacity`, with PromQL for `vllm:num_requests_waiting`, `vllm:num_requests_running`, `vllm:avg_prompt_throughput_toks_per_s`, `vllm:avg_generation_throughput_toks_per_s`, `vllm:gpu_cache_usage_perc`, `DCGM_FI_DEV_GPU_UTIL`, `DCGM_FI_DEV_FB_USED`

- [ ] **Step 1: Extend `tests/monitoring/test_stack.sh` with failing assertions**

```bash
python3 -m json.tool monitoring/grafana/dashboards/vllm-capacity.json > /dev/null
grep -q '"uid": "vllm-capacity"' monitoring/grafana/dashboards/vllm-capacity.json
grep -q 'vLLM Capacity' monitoring/grafana/dashboards/vllm-capacity.json
grep -q 'vllm:num_requests_waiting' monitoring/grafana/dashboards/vllm-capacity.json
grep -q 'vllm:num_requests_running' monitoring/grafana/dashboards/vllm-capacity.json
grep -q 'vllm:avg_prompt_throughput_toks_per_s' monitoring/grafana/dashboards/vllm-capacity.json
grep -q 'vllm:avg_generation_throughput_toks_per_s' monitoring/grafana/dashboards/vllm-capacity.json
grep -q 'vllm:gpu_cache_usage_perc' monitoring/grafana/dashboards/vllm-capacity.json
grep -q 'DCGM_FI_DEV_GPU_UTIL' monitoring/grafana/dashboards/vllm-capacity.json
grep -q 'DCGM_FI_DEV_FB_USED' monitoring/grafana/dashboards/vllm-capacity.json
grep -q 'type: prometheus' monitoring/grafana/provisioning/datasources/datasource.yml
grep -q 'http://prometheus:9090' monitoring/grafana/provisioning/datasources/datasource.yml
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/monitoring/test_stack.sh`
Expected: FAIL on dashboard assertions

- [ ] **Step 3: Implement datasource, dashboard provider, and JSON dashboard**

Datasource default, `access: proxy`. Dashboard provider path `/var/lib/grafana/dashboards`. Compose already mounts these dirs.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/monitoring/test_stack.sh && bash tests/helm/test_chart.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add monitoring/grafana tests/monitoring/test_stack.sh
git commit -m "feat(monitoring): add vLLM Capacity Grafana dashboard"
```

---

### Task 6: Operator documentation

**Files:**
- Create: `monitoring/README.md`
- Modify: `k8s/README.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: compose file path, Helm value keys, cluster addon names from the spec
- Produces: docs that name `docker compose -f monitoring/docker-compose.yml up -d`, `monitoring.enabled`, `autoscaling.enabled`, `sum(vllm:num_requests_waiting)`, `microk8s enable observability` (or prometheus), KEDA as cluster addon, and that TP/`maxNumSeqs` are not autoscaled

- [ ] **Step 1: Write failing `tests/docs/test_docs.sh`**

```bash
grep -q 'docker compose -f monitoring/docker-compose.yml up -d' monitoring/README.md README.md
grep -q 'monitoring.enabled' k8s/README.md monitoring/README.md
grep -q 'autoscaling.enabled' k8s/README.md monitoring/README.md
grep -q 'num_requests_waiting' monitoring/README.md
grep -q 'KEDA' monitoring/README.md k8s/README.md
grep -q 'microk8s enable' monitoring/README.md
grep -q 'tensorParallelSize' k8s/README.md
grep -q 'maxNumSeqs' k8s/README.md
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/docs/test_docs.sh`
Expected: FAIL

- [ ] **Step 3: Write `monitoring/README.md` and add a Monitoring section to `README.md` and `k8s/README.md`**

Include: Compose bring-up; Helm `--set monitoring.enabled=true`; Helm `--set autoscaling.enabled=true` plus `autoscaling.prometheus.serverAddress`; cluster prereqs (Prometheus Operator, DCGM, KEDA — not vendored); TP vs replica knobs; `--max-num-seqs` is per copy.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/docs/test_docs.sh && bash tests/helm/test_chart.sh && bash tests/monitoring/test_stack.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add monitoring/README.md k8s/README.md README.md tests/docs/test_docs.sh
git commit -m "docs: document vLLM Prometheus monitoring and KEDA scaling"
```
