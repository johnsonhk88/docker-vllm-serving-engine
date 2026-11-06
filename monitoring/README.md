# vLLM GPU / CPU / Memory Monitoring

Prometheus scrapes vLLM's `/metrics` endpoint and stores the time series.
Grafana only visualizes what Prometheus stores. DCGM and node-exporter add GPU
and host health, so one Prometheus query layer covers serving and hardware.
Optionally, KEDA scales Kubernetes replicas from the same queue metric.

```text
vLLM /metrics :8000 / :8091 ─┐
DCGM exporter  :9400         ├──► Prometheus :9090 ──► Grafana :3000
node-exporter  :9100         ┘
```

| Component | Role |
| --- | --- |
| vLLM | Serves the model and exposes request, token, latency, and KV-cache metrics. |
| Prometheus | Scrapes `/metrics` every 15s, stores samples, evaluates PromQL and alert rules. |
| DCGM exporter | NVIDIA GPU utilization, framebuffer (VRAM), temperature, and power metrics. |
| node-exporter | Host CPU, memory, filesystem, and network metrics. |
| Grafana | Dashboards over the Prometheus data source. |

GPU knobs stay distinct:

| Knob | Helm value | When to change | Autoscaled? |
| --- | --- | --- | --- |
| Model split across GPUs | `tensorParallelSize` → `--tensor-parallel-size` | Model does not fit (or is too slow) on one GPU | No — rolls a new pod shape |
| More copies of the same model | `replicaCount` or KEDA | Queue (`num_requests_waiting`) grows | Yes, when `autoscaling.enabled` |
| Concurrency per copy | `maxNumSeqs` → `--max-num-seqs` | KV-cache / latency blows up before the queue | No — per copy, restart to apply |

## 1. Confirm vLLM exposes metrics

vLLM exposes Prometheus metrics on the OpenAI server's `/metrics` endpoint by
default. Unlike SGLang, there is no `--enable-metrics` flag to turn on.

Start vLLM with `src/run-vllm-docker.sh` (port `8000`) or
`src/run-vllm-omni-docker.sh` (port `8091`), then verify:

```bash
curl -s http://localhost:8000/metrics | grep -E 'vllm:(num_requests|kv_cache|prompt_tokens|generation_tokens)'
```

Expected output includes:

```text
vllm:num_requests_running{model_name="qwen-small"} 0.0
vllm:num_requests_waiting{model_name="qwen-small"} 0.0
vllm:kv_cache_usage_perc{model_name="qwen-small"} 0.0
vllm:prompt_tokens_total{model_name="qwen-small"} 0.0
vllm:generation_tokens_total{model_name="qwen-small"} 0.0
```

Use port `8091` for Omni. A 404 usually means the request is going to a
different server or a reverse proxy, not that metrics need a flag.

Most serving series carry a `model_name` label. Do not create a target label
with the same name.

## 2. Start Prometheus + Grafana (Docker Compose)

From the repository root:

```bash
docker compose -f monitoring/docker-compose.yml up -d
```

| Service | URL |
| --- | --- |
| Prometheus | http://localhost:9090 |
| Grafana (`admin` / `admin`) | http://localhost:3000 |
| vLLM dashboard | http://localhost:3000/d/vllm-capacity |
| DCGM exporter | http://localhost:9400/metrics |
| node-exporter | http://localhost:9100/metrics |

Grafana is optional. If you only need the Prometheus UI and API:

```bash
docker compose -f monitoring/docker-compose.yml up -d prometheus
```

The scrape jobs and alert rules live in
[`prometheus/prometheus.yml`](prometheus/prometheus.yml) and
[`prometheus/alerts.yml`](prometheus/alerts.yml):

```yaml
global:
  scrape_interval: 15s
  scrape_timeout: 10s

rule_files:
  - /etc/prometheus/alerts.yml

scrape_configs:
  - job_name: vllm
    metrics_path: /metrics
    static_configs:
      - targets:
          - host.docker.internal:8000
          - host.docker.internal:8091
  - job_name: dcgm
    static_configs:
      - targets: [dcgm-exporter:9400]
  - job_name: node
    static_configs:
      - targets: [node-exporter:9100]
```

`host.docker.internal` is mapped to the Docker host in
[`docker-compose.yml`](docker-compose.yml) via
`extra_hosts: host.docker.internal:host-gateway`. That lets the Prometheus
container scrape vLLM's published host port.

The stack scrapes both `8000` (text) and `8091` (Omni). If you launched only
one of them, the unused target shows as **DOWN** in Prometheus. That is
expected unless you remove the unused target.

### Confirm Prometheus is scraping

Open http://localhost:9090/targets and check that the `vllm` target you are
using is **UP**. Or query the Prometheus API:

```bash
curl -sG http://localhost:9090/api/v1/query \
  --data-urlencode 'query=up{job="vllm"}'
```

A healthy target returns `"value": [<timestamp>, "1"]`. A value of `"0"` means
the scrape failed; open the target's **Last error** in the UI for the reason.

Validate the Prometheus configuration before restarting:

```bash
docker run --rm \
  -v "$PWD/monitoring/prometheus:/etc/prometheus:ro" \
  --entrypoint promtool prom/prometheus:v2.54.1 \
  check config /etc/prometheus/prometheus.yml

docker run --rm \
  -v "$PWD/monitoring/prometheus:/etc/prometheus:ro" \
  --entrypoint promtool prom/prometheus:v2.54.1 \
  check rules /etc/prometheus/alerts.yml
```

Stop the stack with:

```bash
docker compose -f monitoring/docker-compose.yml down
```

## 3. Generate load

Counters stay flat until requests arrive. A quick load test with the official
vLLM image (set the model name to the one vLLM serves):

```bash
docker run --rm --network host --entrypoint vllm vllm/vllm-openai:v0.17.0 \
  bench serve --backend openai-chat \
  --base-url http://localhost:8000 \
  --model qwen-small \
  --num-prompts 32 \
  --max-concurrency 4
```

For Omni, use `--base-url http://localhost:8091`. Then re-run the `curl`
command from section 1 or open the Grafana dashboard.

## 4. Point Prometheus at another vLLM host or port

Edit `scrape_configs` and restart Prometheus:

```yaml
scrape_configs:
  - job_name: vllm
    metrics_path: /metrics
    scheme: http
    scrape_interval: 15s
    scrape_timeout: 10s
    static_configs:
      - targets:
          - 192.168.1.50:8000
        labels:
          env: prod
```

Multiple replicas can share one job. Prometheus adds `instance` and `job`
labels automatically:

```yaml
    static_configs:
      - targets:
          - gpu-1:8000
          - gpu-2:8000
        labels:
          env: prod
```

Apply changes to the Compose stack:

```bash
docker compose -f monitoring/docker-compose.yml restart prometheus
```

Notes:

- Test reachability from the Prometheus container, not just from your laptop.
- If vLLM is on Kubernetes `ClusterIP`, run `./src/run-vllm-k8s.sh --port-forward`
  before starting the Compose stack, or the `vllm` target stays DOWN.
- Do not add a target label called `model_name`; vLLM already exports it.

## 5. PromQL for day-to-day monitoring

Open http://localhost:9090, paste a query, and use the **Graph** tab. Use
`rate()` for counters. At a 15s scrape interval, `[1m]` is four samples and
`[5m]` is steadier for alerts.

### Health and traffic

| Question | PromQL |
| --- | --- |
| Is Prometheus scraping vLLM? | `up{job="vllm"}` |
| Running requests | `sum(vllm:num_requests_running)` |
| Queued / waiting requests | `sum(vllm:num_requests_waiting)` |
| Prompt tokens/s | `sum(rate(vllm:prompt_tokens_total[1m]))` |
| Generation tokens/s | `sum(rate(vllm:generation_tokens_total[1m]))` |
| Total tokens/s | `sum(rate(vllm:prompt_tokens_total[1m])) + sum(rate(vllm:generation_tokens_total[1m]))` |
| Finished requests/s | `sum(rate(vllm:request_success_total[1m]))` |

For multiple replicas, group by `instance` to see which one is unhealthy:

```promql
sum by (instance) (vllm:num_requests_waiting)
```

### Latency and cache

| Question | PromQL |
| --- | --- |
| TTFT p50 | `histogram_quantile(0.50, sum by (le) (rate(vllm:time_to_first_token_seconds_bucket[5m])))` |
| TTFT p95 | `histogram_quantile(0.95, sum by (le) (rate(vllm:time_to_first_token_seconds_bucket[5m])))` |
| Inter-token latency p95 | `histogram_quantile(0.95, sum by (le) (rate(vllm:inter_token_latency_seconds_bucket[5m])))` |
| End-to-end latency p95 | `histogram_quantile(0.95, sum by (le) (rate(vllm:e2e_request_latency_seconds_bucket[5m])))` |
| KV-cache fill | `avg(vllm:kv_cache_usage_perc)` |
| Prefix-cache hit rate | `sum(rate(vllm:prefix_cache_hits_total[5m])) / clamp_min(sum(rate(vllm:prefix_cache_queries_total[5m])), 1)` |
| Preemptions/s | `sum(rate(vllm:num_preemptions_total[5m]))` |

### GPU and host

| Question | PromQL |
| --- | --- |
| GPU utilization | `DCGM_FI_DEV_GPU_UTIL` |
| GPU VRAM used | `DCGM_FI_DEV_FB_USED * 1024 * 1024` |
| GPU VRAM free | `DCGM_FI_DEV_FB_FREE * 1024 * 1024` |
| GPU temperature | `DCGM_FI_DEV_GPU_TEMP` |
| GPU power draw | `DCGM_FI_DEV_POWER_USAGE` |
| Host CPU busy | `1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m]))` |
| Host memory available | `node_memory_MemAvailable_bytes` |

`DCGM_FI_DEV_FB_USED` and `DCGM_FI_DEV_FB_FREE` are in MiB, so multiply by
`1024 * 1024` before displaying them as bytes.

### Optional MFU (requires `--enable-mfu-metrics`)

Average TFLOPS per GPU:

```promql
rate(vllm:estimated_flops_per_gpu_total[1m]) / 1e12
```

Estimated memory bandwidth in GB/s:

```promql
(rate(vllm:estimated_read_bytes_per_gpu_total[1m]) +
 rate(vllm:estimated_write_bytes_per_gpu_total[1m])) / 1e9
```

These are modeled estimates, not direct hardware counters.

## 6. Metric reference

vLLM exposes the `vllm:` prefix. Counter names end in `_total`; histogram
series end in `_bucket`, `_count`, and `_sum`.

| Metric | Type | Meaning |
| --- | --- | --- |
| `vllm:num_requests_running` | Gauge | Requests currently executing. |
| `vllm:num_requests_waiting` | Gauge | Requests waiting in the scheduler queue. |
| `vllm:kv_cache_usage_perc` | Gauge | KV-cache fill ratio, 0 to 1. |
| `vllm:prompt_tokens_total` | Counter | Prefill (input) tokens processed. |
| `vllm:generation_tokens_total` | Counter | Generation (output) tokens produced. |
| `vllm:request_success_total` | Counter | Finished requests, split by `finished_reason`. |
| `vllm:time_to_first_token_seconds` | Histogram | Time from request creation to first token. |
| `vllm:inter_token_latency_seconds` | Histogram | Time per output token after the first token. |
| `vllm:e2e_request_latency_seconds` | Histogram | End-to-end request latency. |
| `vllm:prefix_cache_queries_total` | Counter | Prefix-cache queries in tokens. |
| `vllm:prefix_cache_hits_total` | Counter | Prefix-cache hits in tokens. |
| `vllm:num_preemptions_total` | Counter | Requests preempted by the scheduler. |
| `vllm:estimated_flops_per_gpu_total` | Counter | Estimated FLOPs per GPU (MFU metrics enabled). |
| `vllm:estimated_read_bytes_per_gpu_total` | Counter | Estimated GPU read bytes (MFU metrics enabled). |
| `vllm:estimated_write_bytes_per_gpu_total` | Counter | Estimated GPU write bytes (MFU metrics enabled). |
| `DCGM_FI_DEV_GPU_UTIL` | Gauge | GPU busy percentage. |
| `DCGM_FI_DEV_FB_USED` | Gauge | Framebuffer (VRAM) used, MiB. |
| `DCGM_FI_DEV_FB_FREE` | Gauge | Framebuffer (VRAM) free, MiB. |
| `DCGM_FI_DEV_GPU_TEMP` | Gauge | GPU temperature, °C. |
| `DCGM_FI_DEV_POWER_USAGE` | Gauge | GPU power draw, W. |

Metric names can change between vLLM releases. After an image upgrade, compare
the dashboard against `curl -s http://localhost:8000/metrics` before changing
queries.

The current dashboard targets vLLM 0.17 names. Older releases used
`vllm:gpu_cache_usage_perc` instead of `vllm:kv_cache_usage_perc`, and exposed
the `vllm:avg_prompt_throughput_toks_per_s` /
`vllm:avg_generation_throughput_toks_per_s` gauges. vLLM 0.17 removed those
gauges; throughput now comes from the token counters and `rate()`. If you run a
different image, update the dashboard PromQL and the alert expressions — do not
add a Python scraper.

## 7. Alerting

Prometheus evaluates the rules in
[`prometheus/alerts.yml`](prometheus/alerts.yml) independently of Grafana. The
Compose file mounts the rule file next to the main config.

| Alert | Fires when |
| --- | --- |
| `VLLMMetricsDown` | No target in job `vllm` is reachable for 2 minutes. |
| `VLLMQueueBacklog` | Waiting requests stay above 20 for 10 minutes. |
| `VLLMHighTTFT` | TTFT p95 stays above 2s for 10 minutes. |
| `VLLMHighInterTokenLatency` | Inter-token latency p95 stays above 100ms for 10 minutes. |
| `VLLMKVCacheSaturated` | KV-cache fill is above 90% while requests are waiting. |
| `DCGMTargetDown` | Prometheus cannot scrape DCGM for 2 minutes. |
| `NodeExporterDown` | Prometheus cannot scrape node-exporter for 5 minutes. |

`VLLMMetricsDown` uses `max(up{job="vllm"})`, so the unused `8000` or `8091`
target does not create a permanent alert. Tune the queue, latency, and
KV-cache thresholds for your model and traffic.

Check rule state at http://localhost:9090/rules and firing alerts at
http://localhost:9090/alerts. Prometheus only evaluates rules; connect
Alertmanager if you want notifications in Slack, email, or PagerDuty.

For Kubernetes, copy the `groups` block from `alerts.yml` into a
`PrometheusRule` and adjust the `job` label to match the ServiceMonitor:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: vllm
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: vllm
      rules:
        - alert: VLLMMetricsDown
          expr: max(up{job=~".*vllm.*"}) == 0
          for: 2m
          labels:
            severity: critical
```

## 8. Grafana dashboard

The **vLLM Capacity** dashboard is provisioned automatically
(http://localhost:3000/d/vllm-capacity). Panels:

| Panel | Metric | How to use it |
| --- | --- | --- |
| Requests running / waiting | `vllm:num_requests_running`, `vllm:num_requests_waiting` | Queue growing → add copies (KEDA) or raise `--max-num-seqs` if GPU cache is still low. |
| Token throughput | `rate(vllm:prompt_tokens_total[1m])`, `rate(vllm:generation_tokens_total[1m])` | Prompt vs generation tokens/s — the capacity number for “do we need more GPUs?”. |
| GPU KV-cache usage | `vllm:kv_cache_usage_perc` | High cache and rising wait → lower `maxNumSeqs` on each copy before buying hardware. |
| TTFT p95 | `vllm:time_to_first_token_seconds` | First-token latency under load. Rising TTFT with stable ITL points at prefill capacity. |
| Inter-token latency p95 | `vllm:inter_token_latency_seconds` | Decode speed after the first token. Rising ITL with high GPU utilization points at decode capacity. |
| End-to-end latency p95 | `vllm:e2e_request_latency_seconds` | Full request latency, including queueing and generation. |
| DCGM GPU utilization | `DCGM_FI_DEV_GPU_UTIL` | GPU busy pattern over time. |
| DCGM GPU framebuffer used | `DCGM_FI_DEV_FB_USED` | VRAM in use. Near full at load → more GPU, tensor parallel, or a smaller model. |
| Node CPU | `node_cpu_seconds_total` | Host CPU busy. |
| Node memory available | `node_memory_MemAvailable_bytes` | Host RAM left. |

Raw serving metrics without Grafana:

```bash
curl -s http://localhost:8000/metrics | grep -E 'vllm:(prompt_tokens|generation_tokens|num_requests|kv_cache|time_to_first_token|inter_token_latency|e2e_request)'
```

(Use port `8091` for Omni.)

## 9. Kubernetes

This chart does **not** install Prometheus Operator, DCGM, or KEDA. Enable them
on the cluster, then opt in with Helm values.

### Cluster addons (MicroK8s)

```bash
microk8s enable gpu
microk8s enable observability   # Prometheus Operator + Grafana; or: microk8s enable prometheus
# KEDA is a cluster addon, not a subchart of vLLM:
microk8s enable community keda  # or: helm install keda kedacore/keda --namespace keda --create-namespace
```

### Scrape vLLM `/metrics`

```bash
helm upgrade --install vllm ./helm/vllm \
  --set monitoring.enabled=true \
  --set monitoring.serviceMonitor.labels.release=kube-prometheus-stack
```

kube-prometheus-stack only scrapes ServiceMonitors whose labels match
`release: <helm release>` — set `monitoring.serviceMonitor.labels` or Prometheus
never sees vLLM. Verify:

```bash
kubectl get servicemonitor -l app.kubernetes.io/name=vllm
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
# open http://localhost:9090/targets and search for vllm
```

If no target appears:

- `monitoring.serviceMonitor.labels.release` must equal the Helm release name of
  kube-prometheus-stack (`kube-prometheus-stack` above).
- The ServiceMonitor must be in a namespace watched by the Prometheus CR
  (`serviceMonitorNamespaceSelector`).
- The endpoint `port` must match the Service port name. The chart uses `http`.
- The pod must be serving `/metrics` on its vLLM port.

For the raw manifests (`k8s/vllm-text.yaml` / `k8s/vllm-omni.yaml`), add a
ServiceMonitor manually. The text Service is labelled `app: vllm`,
`component: text-llm`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: vllm-text
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app: vllm
      component: text-llm
  endpoints:
    - port: http
      path: /metrics
      interval: 15s
      scrapeTimeout: 10s
```

### GPU metrics on Kubernetes

The GPU Operator (installed by `microk8s enable gpu`) usually includes a DCGM
exporter. Find it and confirm Prometheus scrapes it:

```bash
kubectl get pods -A | grep -i dcgm
kubectl get svc -A | grep -i dcgm
# Query Prometheus:
# DCGM_FI_DEV_GPU_UTIL
```

If the exporter exists but no GPU series appear, label its ServiceMonitor (or
add a scrape config) so it matches your Prometheus selector. The Compose DCGM
container is not used inside Kubernetes.

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

An empty query (wrong metric name, or nothing scraped) is treated as 0, so KEDA
stays at `minReplicas` with no error and **will not scale**.

With default `minReplicas: 1`, `cooldownPeriod` is mapped to the HPA scale-down
stabilization window (KEDA's own cooldown only applies when scaling to zero).
`pollingInterval` still feeds the Prometheus trigger.

Import `monitoring/grafana/dashboards/vllm-capacity.json` into cluster Grafana
if it is not already provisioned.

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

## 10. Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `/metrics` returns 404 | Request is reaching a different server or proxy; vLLM serves `/metrics` on its OpenAI port by default. Check the port and path. |
| Prometheus target DOWN, `connection refused` | Nothing is listening on the target host/port, or vLLM was stopped. |
| Prometheus target DOWN, `context deadline exceeded` | Firewall, wrong host/port, DNS failure, or vLLM bound to loopback only. |
| Target `host.docker.internal:8000` DOWN | vLLM is on Kubernetes `ClusterIP` with no port-forward, or the Compose stack was not used (so `host.docker.internal` is unresolved). |
| One of `8000` / `8091` is DOWN | The other vLLM mode is not running. Remove the unused target or ignore it. |
| Grafana panels empty but Prometheus works | Datasource should be `http://prometheus:9090`; check metric names in `/metrics` after a vLLM upgrade. |
| Throughput or KV-cache panels empty | Older/newer vLLM metric names. Compare the dashboard PromQL against `/metrics`; vLLM 0.17 uses `kv_cache_usage_perc` and token counters. |
| Counters stay at 0 | No requests yet — run the load test in section 3. |
| ServiceMonitor is ignored | Its labels must match the Prometheus `serviceMonitorSelector`; its namespace must match `serviceMonitorNamespaceSelector`. |
| KEDA does not scale | Prometheus address is wrong, the query is empty, or the threshold is too high. Check the ScaledObject status and Prometheus. |
| DCGM container exits or GPU panels are empty | Docker lacks GPU access. Verify `docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi`; check `docker logs` for the exporter. |
| Port 9090 or 3000 already allocated | Stop the conflicting service or change the host port in `docker-compose.yml`. |

Prometheus scrapes vLLM from inside its own container. A target that works from
your laptop with `curl` can still be DOWN in Prometheus; test from the
Prometheus container when debugging:

```bash
docker compose -f monitoring/docker-compose.yml exec prometheus \
  wget -qO- http://host.docker.internal:8000/metrics | head
```

## Production notes

- The Prometheus UI/API has no authentication or TLS by default. Keep port 9090
  on a private network or put it behind a reverse proxy.
- Change Grafana's `admin` password before exposing it.
- 15s scraping is a good default. Raise `scrape_timeout` if the metrics endpoint
  is slow under load.
- Set retention explicitly for long-running deployments:
  `--storage.tsdb.retention.time=30d`. Use `remote_write` if you need long-term
  storage or HA.
- Alert on symptoms operators can act on: target down, queue growth, TTFT, ITL,
  and KV-cache saturation.
- DCGM emits per-GPU series. Keep the scrape interval and retention in mind on
  large multi-GPU hosts.
