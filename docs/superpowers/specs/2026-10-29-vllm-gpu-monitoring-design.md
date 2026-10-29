# vLLM GPU/CPU/Memory Monitoring & Replica Scaling Design

## Intent

Measure vLLM serving load (throughput, token rate, queue) and hardware
(GPU, CPU, RAM) on Docker and Kubernetes, then automatically add or remove
**copies of the same deployment** when the waiting-request queue grows.

Tensor-parallel size and `--max-num-seqs` are **deploy-time knobs** set from
that study. They are not live-mutated by autoscaling.

## Why

This repo already runs vLLM on Docker and Kubernetes (Helm + manifests) with
one replica and one GPU. There is no metrics history, so operators cannot
decide whether to lower concurrency, add GPUs, or split a model. vLLM already
exposes Prometheus `/metrics`; hardware GPU/CPU/RAM should come from DCGM and
node exporters, not a custom `nvidia-smi` Python loop.

## Goals

- Scrape vLLM `/metrics` (running/waiting requests, prompt & generation
  toks/s, KV-cache %, latencies).
- GPU via DCGM; CPU/RAM via node-exporter (and container stats on Docker).
- Grafana dashboards for capacity study and scale decisions.
- KEDA scales Helm replicas from Prometheus `vllm:num_requests_waiting`.
- Same metric names and dashboard on Compose (local) and Kubernetes (MicroK8s).
- First-class Helm values: `maxNumSeqs`, `tensorParallelSize`,
  `autoscaling.minReplicas`, `autoscaling.maxReplicas`.

## Non-goals

- Custom Python as the policy engine (optional later `watch` CLI only).
- Inference gateway / llm-d / smart GPU routing.
- Autoscaling tensor-parallel size or hot-reloading `--max-num-seqs`.
- Multi-cluster or cost billing.
- Vendoring kube-prometheus-stack or KEDA as chart dependencies.

## Anti-goals

- `nvidia-smi` loops as source of truth.
- Two controllers fighting (`replicaCount` vs KEDA) on the same Deployment.
- Enabling ServiceMonitor/ScaledObject by default (clusters without those CRDs
  must keep working).

## Constraints

- Existing `helm/vllm`, `k8s/` manifests, `src/run-vllm-docker.sh`,
  `src/run-vllm-k8s.sh`.
- MicroK8s + NVIDIA GPU addon; default is 1 replica, 1 GPU, ClusterIP.
- vLLM HTTP port already serves Prometheus at `/metrics`.
- Chart must not require Prometheus Operator or KEDA unless the operator
  explicitly enables `monitoring.enabled` / `autoscaling.enabled`.
- Do not vendor kube-prometheus-stack; document cluster addons + optional Helm.
- KEDA is a cluster addon, not a subchart of vLLM.
- Docker Compose monitoring stack is self-contained under `monitoring/`.

## Approaches

Considered:

1. **Prometheus + Grafana + DCGM + KEDA** — scrape vLLM `/metrics` and
   hardware exporters; KEDA scales replica count from waiting requests.
2. Custom Python sidecar scraping `nvidia-smi` and calling `kubectl scale`.
3. Inference gateway (llm-d / Envoy / Gateway API) for smart routing.

**Picked: 1.** Measurement and replica scale-out share one pipeline. Python is
not the control plane. A gateway waits until multiple copies already exist.

## Architecture

```text
Docker:  vLLM :8000/:8091 ──► Prometheus ──► Grafana
         DCGM + node-exporter ──▲

K8s:     vLLM Service (port http) ──► ServiceMonitor ──► Prometheus
         DCGM (GPU addon) + node-exporter ─────────────▲
                              │
                              └── PromQL ──► KEDA ScaledObject ──► Deployment replicas

Deploy-time (Helm values, pod restart on change):
  tensorParallelSize  →  --tensor-parallel-size   (one copy split across GPUs)
  maxNumSeqs          →  --max-num-seqs           (concurrency per copy)
  resources.limits.nvidia.com/gpu  (must match TP; not auto-wired)
```

Two GPU knobs stay distinct:

- **Tensor parallel** (`tensorParallelSize`): packing a model onto N GPUs
  inside one process. Changing it rolls a new pod shape. Not HPA'd.
- **Copies** (`replicaCount` or KEDA): more processes of that same shape.
  Existing ClusterIP Service round-robins. This is the scaling policy.

`--max-num-seqs` stays per copy: if GPU cache or latency blows up before the
queue does, lower concurrency instead of adding hardware.

## Helm values (contract)

Defaults keep current behavior (`monitoring.enabled: false`,
`autoscaling.enabled: false`). New keys:

| Key | Default | Meaning |
| --- | --- | --- |
| `maxNumSeqs` | `null` | If set, pass `--max-num-seqs`. Omit flag when null. |
| `tensorParallelSize` | `null` | If set, pass `--tensor-parallel-size`. Omit flag when null. |
| `monitoring.enabled` | `false` | Emit ServiceMonitor. |
| `monitoring.serviceMonitor.interval` | `15s` | Scrape interval. |
| `monitoring.serviceMonitor.scrapeTimeout` | `10s` | Scrape timeout. |
| `monitoring.serviceMonitor.path` | `/metrics` | Metrics path. |
| `monitoring.serviceMonitor.labels` | `{}` | Extra labels for Prometheus Operator selectors. |
| `autoscaling.enabled` | `false` | Emit KEDA ScaledObject; omit Deployment `spec.replicas`. |
| `autoscaling.minReplicas` | `1` | KEDA min. |
| `autoscaling.maxReplicas` | `4` | KEDA max. |
| `autoscaling.pollingInterval` | `15` | Seconds. |
| `autoscaling.cooldownPeriod` | `60` | Seconds. |
| `autoscaling.prometheus.serverAddress` | `http://kube-prometheus-stack-prometheus.monitoring.svc:9090` | Override per cluster. |
| `autoscaling.prometheus.query` | `sum(vllm:num_requests_waiting)` | PromQL. |
| `autoscaling.prometheus.threshold` | `"5"` | Scale out when query exceeds this. |

When `autoscaling.enabled` is false, Deployment uses `replicaCount` as today.
When true, KEDA owns replica count; do not set `spec.replicas`.

ServiceMonitor selects the existing Service via `vllm.selectorLabels` and
scrapes named port `http` at `monitoring.serviceMonitor.path`.

## Docker Compose (contract)

Self-contained stack in `monitoring/`:

- Prometheus (`:9090`) scrapes `host.docker.internal:8000` and `:8091`
  (`/metrics`), plus `dcgm-exporter:9400` and `node-exporter:9100`.
- Grafana (`:3000`) with provisioned Prometheus datasource and the in-repo
  dashboard.
- `dcgm-exporter` with NVIDIA GPU access.
- `node-exporter` for host CPU/RAM.

Bring-up: `docker compose -f monitoring/docker-compose.yml up -d`.
vLLM itself stays launched by `src/run-vllm-docker.sh` (not in this compose).

## Metrics (pinned)

Use these names in the dashboard and KEDA query. If a running image emits
underscored names instead, override `autoscaling.prometheus.query` and the
dashboard PromQL — do not invent a Python scraper.

- `vllm:num_requests_running`
- `vllm:num_requests_waiting`
- `vllm:gpu_cache_usage_perc`
- `vllm:avg_prompt_throughput_toks_per_s`
- `vllm:avg_generation_throughput_toks_per_s`
- DCGM: `DCGM_FI_DEV_GPU_UTIL`, `DCGM_FI_DEV_FB_USED`
- node-exporter: `node_cpu_seconds_total`, `node_memory_MemAvailable_bytes`

## Grafana dashboard

In-repo JSON, UID `vllm-capacity`, title `vLLM Capacity`. Panels:

- Requests running / waiting
- Prompt and generation token rates
- GPU KV-cache %
- DCGM GPU utilization and framebuffer used
- Node CPU and memory

Provisioned in Compose; imported on cluster Grafana from the same file.

## Cluster prerequisites (documented, not installed by this chart)

- Prometheus Operator (MicroK8s `observability` / `prometheus`, or
  kube-prometheus-stack). Set `monitoring.serviceMonitor.labels` to match
  the operator's ServiceMonitor selector.
- NVIDIA DCGM exporter (MicroK8s GPU addon / gpu-operator).
- KEDA (MicroK8s community addon or `helm install keda kedacore/keda`).
- Override `autoscaling.prometheus.serverAddress` to the in-cluster Prometheus.

## What's left to the builder

- Exact image tags for Prometheus, Grafana, DCGM exporter, node-exporter
  (pin them).
- Helm template conditionals and label plumbing.
- Chart version bump to `0.2.0`.
- Helm template tests for the contracts above.
- Wording of README / `k8s/README.md` / `monitoring/README.md`.

Do not add an inference gateway. Do not change `run-vllm-k8s.sh` CLI in this
project. Do not auto-set `nvidia.com/gpu` from `tensorParallelSize`.
