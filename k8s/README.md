# Kubernetes Deployment for vLLM & vLLM-Omni

This directory provides production-ready Kubernetes manifests and a Helm Chart to deploy **vLLM** (Text LLMs) and **vLLM-Omni** (Multimodal & Diffusion models) on a Kubernetes cluster with GPU acceleration.

## Architecture & Features

- **Production-Ready Networking**: Uses `ClusterIP` by default to shield the serving engine inside the cluster private network.
- **Shared Memory Volume (`/dev/shm`)**: Mounts an in-memory `emptyDir` at `/dev/shm` required for PyTorch tensor parallelism.
- **Cache Persistence**: Mounts the host cache (`~/.cache/huggingface`) via `hostPath` so models already downloaded are instantly reused.
- **Probes**: Configured with Readiness (`/v1/models`) and Liveness (`/health`) probes so Kubernetes only routes traffic once model weights are fully loaded into VRAM.
- **Automated GPU Scheduling**: Requests `nvidia.com/gpu: 1`.

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

## 5. Testing with the Python Suite

With port-forwarding active (`./src/run-vllm-k8s.sh --port-forward`), run the test runner:

```bash
python3 src/test-vllm-omni.py --url http://localhost:8091/v1 --mode all
```
