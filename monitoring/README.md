# vLLM GPU / CPU / Memory Monitoring

Prometheus + Grafana + DCGM for capacity study, plus optional KEDA replica
autoscaling on Kubernetes. vLLM already exposes `/metrics`; this stack scrapes
it. Hardware GPU/CPU/RAM come from DCGM and node-exporter — not a custom
`nvidia-smi` script.

Two GPU knobs stay distinct:

| Knob | Helm value | When to change | Autoscaled? |
| --- | --- | --- | --- |
| Model split across GPUs | `tensorParallelSize` → `--tensor-parallel-size` | Model does not fit (or is too slow) on one GPU | No — rolls a new pod shape |
| More copies of the same model | `replicaCount` or KEDA | Queue (`num_requests_waiting`) grows | Yes, when `autoscaling.enabled` |
| Concurrency per copy | `maxNumSeqs` → `--max-num-seqs` | KV-cache / latency blows up before the queue | No — per copy, restart to apply |

## Docker (local study)

Start vLLM with `src/run-vllm-docker.sh` or `src/run-vllm-omni-docker.sh`
(ports `8000` / `8091`). Then:

```bash
docker compose -f monitoring/docker-compose.yml up -d
```

| Service | URL |
| --- | --- |
| Grafana (`admin` / `admin`) | http://localhost:3000 |
| Prometheus | http://localhost:9090 |
| DCGM exporter | http://localhost:9400/metrics |
| node-exporter | http://localhost:9100/metrics |

Dashboard **vLLM Capacity** is provisioned automatically (left sidebar, or
http://localhost:3000/d/vllm-capacity). Prometheus scrapes
`host.docker.internal:8000` and `:8091` at `/metrics`. If you only launched
text **or** omni vLLM, the unused port shows as down in Prometheus — that is
expected.

### What the dashboard shows

| Panel | Metric | How to use it |
| --- | --- | --- |
| Requests running / waiting | `vllm:num_requests_running`, `vllm:num_requests_waiting` | Queue growing → add **copies** (KEDA) or raise `--max-num-seqs` if GPU cache is still low. |
| Token throughput | `vllm:avg_prompt_throughput_toks_per_s`, `vllm:avg_generation_throughput_toks_per_s` | Prompt vs generation tokens/s — the capacity number for “do we need more GPUs?”. |
| GPU KV-cache usage | `vllm:gpu_cache_usage_perc` | High cache and rising wait → lower `maxNumSeqs` on each copy before buying hardware. |
| DCGM GPU utilization | `DCGM_FI_DEV_GPU_UTIL` | GPU busy pattern over time. |
| DCGM GPU framebuffer used | `DCGM_FI_DEV_FB_USED` | VRAM in use. Near full at load → more GPU, tensor parallel, or a smaller model. |
| Node CPU | `node_cpu_seconds_total` | Host CPU busy. |
| Node memory available | `node_memory_MemAvailable_bytes` | Host RAM left. |

Raw serving metrics without Grafana:

```bash
curl -s http://localhost:8000/metrics | grep -E 'vllm:(num_requests_|avg_|gpu_cache)'
```

(Use port `8091` for Omni.)

Stop:

```bash
docker compose -f monitoring/docker-compose.yml down
```

## Kubernetes

This chart does **not** install Prometheus Operator, DCGM, or KEDA. Enable
them on the cluster, then opt in with Helm values.

### Cluster addons (MicroK8s)

```bash
microk8s enable gpu
microk8s enable observability   # Prometheus Operator + Grafana; or: microk8s enable prometheus
# KEDA is a cluster addon, not a subchart of vLLM:
microk8s enable community keda  # or: helm install keda kedacore/keda --namespace keda --create-namespace
```

Override `autoscaling.prometheus.serverAddress` to the in-cluster Prometheus
(for example `http://kube-prometheus-stack-prometheus.monitoring.svc:9090` or
the observability-namespace service on MicroK8s). kube-prometheus-stack only
scrapes ServiceMonitors whose labels match `release: <helm release>` — set
`monitoring.serviceMonitor.labels` or Prometheus never sees vLLM. An empty query
(wrong metric name, or nothing scraped) is treated as 0, so KEDA stays at
`minReplicas` with no error and **will not scale**.

With default `minReplicas: 1`, `cooldownPeriod` is mapped to the HPA scale-down
stabilization window (KEDA's own cooldown only applies when scaling to zero).
`pollingInterval` still feeds the Prometheus trigger.

### Scrape vLLM `/metrics`

```bash
helm upgrade --install vllm ./helm/vllm \
  --set monitoring.enabled=true \
  --set monitoring.serviceMonitor.labels.release=kube-prometheus-stack
```

### Autoscale copies from the waiting-request queue

```bash
helm upgrade --install vllm ./helm/vllm \
  --set monitoring.enabled=true \
  --set monitoring.serviceMonitor.labels.release=kube-prometheus-stack \
  --set autoscaling.enabled=true \
  --set autoscaling.prometheus.serverAddress=http://kube-prometheus-stack-prometheus.monitoring.svc:9090
```

KEDA uses `sum(vllm:num_requests_waiting)` with threshold `5` (override
`autoscaling.prometheus.query` / `threshold`). Desired replicas is about
`ceil(sum / threshold)` (KEDA default `AverageValue`). When
`autoscaling.enabled` is true, KEDA owns replica count — do not also set
`replicaCount` as a second controller.

If the running image emits underscored metric names instead of `vllm:…`,
change `autoscaling.prometheus.query` and the Grafana PromQL. Do not add a
Python scraper.

### Deploy-time packing (not HPA)

```bash
helm upgrade --install vllm ./helm/vllm \
  --set maxNumSeqs=32 \
  --set tensorParallelSize=2 \
  --set resources.limits."nvidia\.com/gpu"=2 \
  --set resources.requests."nvidia\.com/gpu"=2
```

`tensorParallelSize` is **not** auto-wired to `nvidia.com/gpu`. Match them
yourself. Changing TP or `maxNumSeqs` restarts the pod.

Import `monitoring/grafana/dashboards/vllm-capacity.json` into cluster Grafana
if it is not already provisioned.
