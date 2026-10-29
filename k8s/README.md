# Kubernetes Deployment for vLLM & vLLM-Omni

This directory provides production-ready Kubernetes manifests and a Helm Chart to deploy **vLLM** (Text LLMs) and **vLLM-Omni** (Multimodal & Diffusion models) on a Kubernetes cluster with GPU acceleration.

## Architecture & Features

- **Production-Ready Networking**: Uses `ClusterIP` by default to shield the serving engine inside the cluster private network.
- **Shared Memory Volume (`/dev/shm`)**: Mounts an in-memory `emptyDir` at `/dev/shm` required for PyTorch tensor parallelism.
- **Cache Persistence**: Mounts the host cache (`~/.cache/huggingface`) via `hostPath` so models already downloaded are instantly reused.
- **Probes**: Configured with Readiness (`/v1/models`) and Liveness (`/health`) probes so Kubernetes only routes traffic once model weights are fully loaded into VRAM.
- **Automated GPU Scheduling**: Requests `nvidia.com/gpu: 1`.
- **Optional Prometheus ServiceMonitor**: `--set monitoring.enabled=true` scrapes vLLM `/metrics`.
- **Optional KEDA replica autoscaling**: `--set autoscaling.enabled=true` scales copies from `vllm:num_requests_waiting`.

---

## 1. Prerequisites (MicroK8s / Kubernetes)

### Enable GPU Support
If you are running MicroK8s on this machine (`ray-head`), ensure the NVIDIA GPU addon is enabled:

```bash
microk8s enable gpu
```

Verify that the node lists `nvidia.com/gpu` under allocatable resources:

```bash
kubectl get node -o custom-columns=NAME:.metadata.name,GPUS:.status.allocatable."nvidia\.com/gpu"
```

### Set Hugging Face Token (Optional)
If your model requires authentication, create the secret:

```bash
kubectl create secret generic hf-token-secret \
  --from-literal=HF_TOKEN="hf_your_token_here"
```
*(The helper script `./src/run-vllm-k8s.sh` automatically creates this secret if your token is defined in `.env`)*.

---

## 2. Quickstart via CLI Helper Script (`src/run-vllm-k8s.sh`)

The script provides parity with the Docker launchers (`run-vllm-docker.sh` and `run-vllm-omni-docker.sh`):

### Deploy Text LLM (`ClusterIP`)
```bash
./src/run-vllm-k8s.sh --model Qwen/Qwen3-0.6B --name qwen-small
```

### Deploy Omni / Multimodal Model (`ClusterIP`)
```bash
./src/run-vllm-k8s.sh --omni --model Qwen/Qwen-Image --name qwen-image
```

### Monitor & Stream Logs
```bash
# Check pod & service status
./src/run-vllm-k8s.sh --status

# Stream download and server logs
./src/run-vllm-k8s.sh --logs
```

### Port-Forward & Test Locally
Because the service uses production `ClusterIP`, forward the port to your local machine:

```bash
# Starts port-forwarding in the foreground
./src/run-vllm-k8s.sh --port-forward
```

In another terminal, test the endpoint:
```bash
curl http://localhost:8000/v1/models
# Or for Omni:
curl http://localhost:8091/v1/models
```

---

## 3. Deploying via Helm (`helm/vllm/`)

The repository includes a Helm Chart at `helm/vllm/`.

### Install Text LLM
```bash
helm upgrade --install vllm ./helm/vllm \
  --set mode=text \
  --set model=Qwen/Qwen3-0.6B \
  --set servedModelName=qwen-small \
  --set service.type=ClusterIP
```

### Install Omni / Multimodal Model
```bash
helm upgrade --install vllm ./helm/vllm \
  --set mode=omni \
  --set model=Qwen/Qwen-Image \
  --set servedModelName=qwen-image \
  --set service.type=ClusterIP
```

### Optional: Use NodePort for Direct LAN Access
If you want to access the server directly across your local network without running `kubectl port-forward`:

```bash
helm upgrade --install vllm ./helm/vllm \
  --set service.type=NodePort \
  --set service.nodePort=30080
```
Then access directly via `http://<node-ip>:30080/v1/models`.

### Uninstall Helm Release
```bash
helm uninstall vllm
```

### Monitoring, concurrency, and replica scaling

Deploy-time knobs (restart the pod; **not** autoscaled):

| Value | vLLM flag | Purpose |
| --- | --- | --- |
| `maxNumSeqs` | `--max-num-seqs` | Max concurrent sequences **per copy**. Lower this if KV-cache or latency blows up before the queue grows. |
| `tensorParallelSize` | `--tensor-parallel-size` | Split **one** model across GPUs. Match `resources.limits.nvidia.com/gpu` yourself; the chart does not auto-wire GPU count. |

```bash
helm upgrade --install vllm ./helm/vllm \
  --set maxNumSeqs=32 \
  --set tensorParallelSize=2 \
  --set resources.limits."nvidia\.com/gpu"=2 \
  --set resources.requests."nvidia\.com/gpu"=2
```

Scrape metrics (requires Prometheus Operator on the cluster — not vendored):

```bash
helm upgrade --install vllm ./helm/vllm \
  --set monitoring.enabled=true \
  --set monitoring.serviceMonitor.labels.release=kube-prometheus-stack
```

Autoscale **copies** with KEDA (cluster addon, not a subchart). KEDA owns
`spec.replicas` when this is on:

```bash
helm upgrade --install vllm ./helm/vllm \
  --set monitoring.enabled=true \
  --set monitoring.serviceMonitor.labels.release=kube-prometheus-stack \
  --set autoscaling.enabled=true \
  --set autoscaling.prometheus.serverAddress=http://kube-prometheus-stack-prometheus.monitoring.svc:9090
```

Default PromQL is `sum(vllm:num_requests_waiting)` with threshold `5`. Tensor
parallel size is not HPA'd.

Import [`monitoring/grafana/dashboards/vllm-capacity.json`](../monitoring/grafana/dashboards/vllm-capacity.json)
into cluster Grafana for GPU/CPU/RAM, KV-cache, waiting-request queue, and
token throughput (prompt and generation toks/s). Panel-by-panel usage:
[`monitoring/README.md`](../monitoring/README.md).

---

## 4. Deploying via Raw Manifests (`k8s/`)

If you prefer raw declarative manifests:

```bash
# Deploy Text LLM
kubectl apply -f k8s/vllm-text.yaml

# Deploy Omni Multimodal
kubectl apply -f k8s/vllm-omni.yaml

# Or apply both via Kustomize
kubectl apply -k k8s/
```

To delete:
```bash
kubectl delete -f k8s/vllm-text.yaml
```

---

## 5. Automated Testing Runner (`src/test-k8s.sh`)

The repository provides an automated end-to-end test runner `src/test-k8s.sh` that validates cluster GPU availability, manages deployment, polls pod readiness, handles background port-forwarding safely with trap handlers, and asserts OpenAI-compatible API responses:

```bash
# 1. Run automated test suite for Text LLM (Qwen/Qwen3-0.6B)
./src/test-k8s.sh

# 2. Test an already deployed vLLM pod/service
./src/test-k8s.sh --skip-deploy

# 3. Test Omni Multimodal model with deep Python/LiteLLM assertions
./src/test-k8s.sh --mode omni --python

# 4. Check cluster preflight readiness only
./src/test-k8s.sh --preflight-only

# 5. Run test and automatically clean up resources on completion
./src/test-k8s.sh --cleanup
```

---

## 6. Manual Testing with the Python Suite

With port-forwarding active (`./src/run-vllm-k8s.sh --port-forward`), you can also run manual queries via the test runner:

```bash
python3 src/test-vllm-omni.py --url http://localhost:8091/v1 --mode all
```

---

## 7. Serving & Usage Guide

For a complete guide on how to integrate client applications, switch models, use NodePort for LAN serving, and execute curl / Python / LiteLLM requests:

- **[k8s/USAGE.md](USAGE.md)**: Serving workflows, client access methods (ClusterIP, NodePort, In-Cluster), and API examples.

---

## 8. Troubleshooting & Debugging

For detailed analysis of known deployment errors (such as the `VLLM_PORT` URI collision, Helm connectivity without KUBECONFIG, containerd caching, and TLS certificate IP mismatches), see the comprehensive guide:

- **[k8s/DEBUG_GUIDE.md](DEBUG_GUIDE.md)**: Real-world failure modes, root causes, fixes, and diagnostic cheat sheet.
