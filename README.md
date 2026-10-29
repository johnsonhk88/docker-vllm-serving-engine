# vLLM Serving Engine

Scripts for running and testing vLLM and vLLM-Omni with Docker, the CLI, and Python.

## Available Launchers

| Launcher / Interface | Deployment Target | Default Port | Primary Endpoints |
| --- | --- | --- | --- |
| `src/run-vllm-docker.sh` | Docker (Text LLMs) | `8000` | `/v1/chat/completions` |
| `src/run-vllm-omni-docker.sh` | Docker (Omni, Audio, Video, Image, Diffusion) | `8091` | `/v1/chat/completions`, `/v1/images/generations`, `/v1/audio/speech` |
| `src/run-vllm-k8s.sh` | Kubernetes / MicroK8s (Helm & Manifests) | `8000` / `8091` | Production `ClusterIP` (with port-forward) or `NodePort` |
| `src/test-k8s.sh` | Kubernetes Automated Test Runner | `8000` / `8091` | Preflight, Pod Readiness, API Assertions, & Teardown |
| `helm/vllm/` | Production Helm Chart | Configurable | Parameterized K8s Deployment & Service |
| `k8s/` | Raw Declarative K8s Manifests | Configurable | Standalone YAML & Kustomize manifests |
| `monitoring/` | Docker Compose Prometheus/Grafana/DCGM | `9090` / `3000` | vLLM `/metrics`, GPU, CPU, RAM |

Both scripts:
- Pass arbitrary vLLM parameters through to the serving engine.
- Re-execute under Bash automatically when called via `sh`.
- Map container ports and mount the local Hugging Face model cache (`~/.cache/huggingface`).
- Forward `HF_TOKEN` from the shell environment.

---

## Prerequisites

Install and verify the following before starting either launcher:

1. **NVIDIA GPU** with compatible NVIDIA drivers.
2. **Docker Engine**.
3. **NVIDIA Container Toolkit**, ensuring Docker supports `--gpus all`.
4. **Hugging Face Account & Token** for gated/private models.

Export your Hugging Face token in your terminal:

```bash
export HF_TOKEN="hf_your_token_here"
```

Verify Docker GPU acceleration:

```bash
docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
```

---

## 1. Text LLM Serving (`run-vllm-docker.sh`)

Use this script for standard text-based autoregressive models.

### Step-by-Step Quickstart

#### Step 1: Start a Model

```bash
./src/run-vllm-docker.sh \
  --model Qwen/Qwen3-0.6B \
  --name qwen-small \
  --gpu-memory-utilization 0.2
```

*(You can also run via `bash src/run-vllm-docker.sh ...` or `sh src/run-vllm-docker.sh ...`)*

#### Step 2: Verify Server Readiness

In another terminal, check the models endpoint:

```bash
curl http://localhost:8000/v1/models
```

#### Step 3: Send a Chat Request

```bash
curl -X POST "http://localhost:8000/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen-small",
    "messages": [
      {"role": "user", "content": "What is the capital of France?"}
    ]
  }'
```

### Options Reference

```text
Usage:
  run-vllm-docker.sh --model MODEL [launcher options] [vLLM options...]
```

| Option | Default | Description |
| --- | --- | --- |
| `--model MODEL` | Required | Hugging Face model ID or local model path. |
| `--name NAME` | vLLM default | API-visible name (passed to vLLM as `--served-model-name`). |
| `--hf-token TOKEN` | `$HF_TOKEN` | Hugging Face access token for authenticated high-speed downloads (alias: `--token`). |
| `--image IMAGE` | `vllm/vllm-openai:v0.17.0` | Docker image to run. |
| `--port PORT` | `8000` | Host and container port mapping. |
| `-h`, `--help` | None | Show usage help. |

All remaining arguments (e.g. `--gpu-memory-utilization`, `--max-model-len`, `--tensor-parallel-size`) are passed directly to `vllm` inside the container.

---

## 2. Omni-Modality & Diffusion Serving (`run-vllm-omni-docker.sh`)

Use this script for models supported by **vLLM-Omni** (`vllm-project/vllm-omni`), including:
- **Omni Models** (Audio, video, image, and text chat: e.g. `Qwen/Qwen3-Omni`, `openbmb/MiniCPM-o-2_6`, `Cosmos3`).
- **Diffusion / Text-to-Image** (DiT models: e.g. `Qwen/Qwen-Image`, `MiniMax-H3`, `LTX-2.5`).
- **TTS Models** (Speech generation: e.g. `Qwen/Qwen3-TTS`, `CosyVoice3`).

The container runs `vllm serve "$model" --omni --port "$port"` using the `vllm/vllm-omni:latest` Docker image.

### Step-by-Step Quickstart

### Example A: Omni Multimodal Chat (Text + Image + Audio + Video)

#### Step 1: Launch an Omni Model

```bash
./src/run-vllm-omni-docker.sh \
  --model Qwen/Qwen3-Omni-30B-A3B-Instruct \
  --name qwen3-omni \
  --tensor-parallel-size 2 \
  --gpu-memory-utilization 0.9
```

#### Step 2: Check Server Readiness

```bash
curl http://localhost:8091/v1/models
```

#### Step 3: Send a Multimodal Chat Request (with an Image)

```bash
curl -X POST "http://localhost:8091/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3-omni",
    "messages": [
      {
        "role": "user",
        "content": [
          {"type": "text", "text": "Describe this image in detail:"},
          {
            "type": "image_url",
            "image_url": {
              "url": "https://upload.wikimedia.org/wikipedia/commons/thumb/d/dd/Gfp-wisconsin-madison-the-nature-boardwalk.jpg/2560px-Gfp-wisconsin-madison-the-nature-boardwalk.jpg"
            }
          }
        ]
      }
    ]
  }'
```

---

### Example B: Diffusion / Text-to-Image Generation

#### Step 1: Launch a Diffusion Model

```bash
./src/run-vllm-omni-docker.sh \
  --model Qwen/Qwen-Image \
  --name qwen-image \
  --gpu-memory-utilization 0.8
```

#### Step 2: Generate an Image via the API

vLLM-Omni routes diffusion models to the OpenAI-compatible `/v1/images/generations` endpoint:

```bash
curl -X POST "http://localhost:8091/v1/images/generations" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen-image",
    "prompt": "A cinematic shot of a golden retriever wearing astronaut gear on Mars",
    "n": 1,
    "size": "1024x1024"
  }' | jq -r '.data[0].b64_json' | base64 -d > mars_dog.png
```

---

### Options Reference for `run-vllm-omni-docker.sh`

```text
Usage:
  run-vllm-omni-docker.sh --model MODEL [launcher options] [vLLM options...]
```

| Option | Default | Description |
| --- | --- | --- |
| `--model MODEL` | Required | Hugging Face model ID or path (e.g. `Qwen/Qwen3-Omni-30B-A3B-Instruct`, `Qwen/Qwen-Image`). |
| `--name NAME` | vLLM default | API-visible model alias (passed as `--served-model-name`). |
| `--hf-token TOKEN` | `$HF_TOKEN` | Hugging Face access token for authenticated high-speed downloads (alias: `--token`). |
| `--image IMAGE` | `vllm/vllm-omni:latest` | Docker image (e.g. `vllm/vllm-omni:v0.30.0` or `vllm/vllm-omni:nightly`). |
| `--port PORT` | `8091` | Host and container port mapping. |
| `-h`, `--help` | None | Show usage help. |

Any other parameters (e.g., `--deploy-config`, `--gpu-memory-utilization`, `--tensor-parallel-size`) are forwarded directly to `vllm serve`.

---

## 3. Python & LiteLLM Testing Tools

Testing tools are provided as both a CLI script and a Jupyter Notebook. They support **LiteLLM** (and automatically fall back to direct HTTP requests if LiteLLM is not installed).

Install LiteLLM (recommended):
```bash
pip install litellm requests
```

### Option 1: Python CLI Runner (`src/test-vllm-omni.py`)

A versatile testing script supporting automated checks and custom prompts:

```bash
# 1. Health check & model listing
python3 src/test-vllm-omni.py --mode models

# 2. Test Vision Chat (passes an image URL + prompt)
python3 src/test-vllm-omni.py --mode chat --model qwen3-omni

# 3. Test Audio Understanding (passes sample audio clip)
python3 src/test-vllm-omni.py --mode audio --model minicpm-o

# 4. Test Text-to-Image Diffusion (saves output to output.png)
python3 src/test-vllm-omni.py --mode image --model qwen-image --prompt "A red panda in space" --output panda.png

# 5. Auto-detect model and run appropriate tests
python3 src/test-vllm-omni.py --mode all
```

Use `python3 src/test-vllm-omni.py --help` for all options.

### Option 2: Interactive Jupyter Notebook (`src/test-vllm-omni-python.ipynb`)

Following the pattern of `src/test-vllm-python.ipynb`, this notebook provides interactive cells for:
- Pre- and post-run GPU VRAM checks (`!nvidia-smi`).
- Server discovery and active model retrieval.
- Multimodal Vision and Audio testing with LiteLLM.
- Diffusion image generation with inline display via `IPython.display.Image`.

Open in Jupyter Lab or VS Code:
```bash
jupyter notebook src/test-vllm-omni-python.ipynb
```

### Option 3: LiteLLM Code Snippets

```python
import litellm

# Multimodal Vision Chat (port 8091)
response = litellm.completion(
    model="openai/qwen3-omni",
    api_base="http://localhost:8091/v1",
    api_key="none",
    messages=[
        {
            "role": "user",
            "content": [
                {"type": "text", "text": "Describe this image:"},
                {"type": "image_url", "image_url": {"url": "https://example.com/photo.jpg"}},
            ],
        }
    ],
)
print(response.choices[0].message.content)

# Text-to-Image Diffusion (port 8091)
img_resp = litellm.image_generation(
    model="openai/qwen-image",
    api_base="http://localhost:8091/v1",
    api_key="none",
    prompt="A serene mountain lake at sunrise with reflections",
    size="1024x1024",
)
print("Image URL or base64 data received!")
```

---

## 4. Kubernetes Deployment (`k8s/` & `helm/vllm/`)

Production-ready Kubernetes deployment supporting both raw manifests and a full Helm chart.

### Prerequisite: Enable GPU (MicroK8s)
If using MicroK8s on this machine, enable GPU support first:
```bash
microk8s enable gpu
```

### Quickstart via Helper Script (`src/run-vllm-k8s.sh`)
Uses production `ClusterIP` by default:

```bash
# 1. Deploy Text LLM
./src/run-vllm-k8s.sh --model Qwen/Qwen3-0.6B --name qwen-small

# 2. Deploy Omni Multimodal model
./src/run-vllm-k8s.sh --omni --model Qwen/Qwen-Image --name qwen-image

# 3. Check status & stream pod logs
./src/run-vllm-k8s.sh --status
./src/run-vllm-k8s.sh --logs

# 4. Port-forward ClusterIP service to local port
./src/run-vllm-k8s.sh --port-forward
```

### Deploying via Helm
```bash
# Install Text LLM
helm upgrade --install vllm ./helm/vllm --set mode=text --set model=Qwen/Qwen3-0.6B

# Install Omni model
helm upgrade --install vllm ./helm/vllm --set mode=omni --set model=Qwen/Qwen-Image
```

### Step-by-Step Kubernetes Testing Guide

You can test your Kubernetes vLLM deployment either using the automated test runner (`src/test-k8s.sh`) or manually step-by-step.

#### Option A: Automated Testing Runner (`src/test-k8s.sh`)

The automated script handles preflight GPU verification, deployment, readiness polling, background port-forwarding with exit traps, and OpenAI API assertions:

```bash
# 1. Run cluster and GPU preflight checks only
./src/test-k8s.sh --preflight-only

# 2. Run automated test suite for Text LLM (Qwen/Qwen3-0.6B)
./src/test-k8s.sh

# 3. Test with deep Python/LiteLLM assertions enabled
./src/test-k8s.sh --python

# 4. Automated test suite for Omni / Multimodal model
./src/test-k8s.sh --mode omni --python

# 5. Test an existing deployment without re-deploying
./src/test-k8s.sh --skip-deploy

# 6. Run test and automatically clean up resources on completion
./src/test-k8s.sh --cleanup
```

#### Option B: Manual Step-by-Step Testing

##### Step 1: Ensure Cluster GPU Support
If running MicroK8s, enable the GPU addon:
```bash
microk8s enable gpu
```
Verify that `nvidia.com/gpu` appears in the node's allocatable resources:
```bash
kubectl get node -o custom-columns=NAME:.metadata.name,GPUS:.status.allocatable."nvidia\.com/gpu"
```

##### Step 2: Deploy vLLM
Deploy a lightweight model for verification:
```bash
./src/run-vllm-k8s.sh --model Qwen/Qwen3-0.6B --name qwen-small
```

##### Step 3: Monitor Pod Readiness & Logs
```bash
# Check pod status (wait for Running and 1/1 Ready)
./src/run-vllm-k8s.sh --status

# Stream engine loading logs
./src/run-vllm-k8s.sh --logs
```

##### Step 4: Port-Forward Service
Since the deployment uses `ClusterIP`, forward the service port to localhost:
```bash
./src/run-vllm-k8s.sh --port-forward
```

##### Step 5: Test Endpoints via curl
In a separate terminal, execute API assertions:
```bash
# Check health probe
curl http://localhost:8000/health

# Check model discovery
curl http://localhost:8000/v1/models

# Send a chat completion request
curl -X POST "http://localhost:8000/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen-small",
    "messages": [
      {"role": "user", "content": "What is the capital of France?"}
    ]
  }'
```

##### Step 6: Test with the Python Test Suite
Run the automated Python test runner against the forwarded port:
```bash
python3 src/test-vllm-omni.py --url http://localhost:8000/v1 --mode all
```

See [`k8s/USAGE.md`](k8s/USAGE.md) for complete serving options, client integration examples, and network configuration. Detailed cluster manifests and Helm parameters are documented in [`k8s/README.md`](k8s/README.md).

---

## 5. GPU / CPU / Memory Monitoring

Capacity study uses Prometheus + Grafana + DCGM. Replica autoscaling on Kubernetes uses KEDA. Full operator guide: [`monitoring/README.md`](monitoring/README.md).

### Docker (next to a running vLLM container)

```bash
docker compose -f monitoring/docker-compose.yml up -d
```

Grafana is at http://localhost:3000 (`admin` / `admin`). Prometheus scrapes
host ports `8000` and `8091` (`/metrics`) plus DCGM and node-exporter.

### Kubernetes

Opt-in Helm flags (off by default so clusters without the CRDs keep working):

```bash
helm upgrade --install vllm ./helm/vllm \
  --set monitoring.enabled=true \
  --set autoscaling.enabled=true \
  --set autoscaling.prometheus.serverAddress=http://kube-prometheus-stack-prometheus.monitoring.svc:9090
```

KEDA scales copies from `vllm:num_requests_waiting`. `tensorParallelSize` and
`maxNumSeqs` are deploy-time knobs, not autoscaled. See [`k8s/README.md`](k8s/README.md)
and [`monitoring/README.md`](monitoring/README.md).

---

## Troubleshooting

### `set: Illegal option -o pipefail`
Both launchers feature an automatic Bash self-reexec guard at the top. You can run them via:
- `./src/run-vllm-docker.sh ...`
- `bash src/run-vllm-docker.sh ...`
- `sh src/run-vllm-docker.sh ...`

### Flag Syntax Tip: Avoid Spaces in `--name`
- **Correct**: `--name qwen-small`
- **Incorrect**: `-- name qwen-small` (in shell syntax, `--` terminates options, treating subsequent words as unknown arguments).

### GPU Out-of-Memory (OOM)
If you hit CUDA OOM errors during model loading or generation:
- Lower `--gpu-memory-utilization` (e.g. `0.7` or `0.8`).
- Lower `--max-model-len` (e.g. `2048` or `4096`).
- For large Omni models (like `Qwen3-Omni-30B`), use multi-GPU tensor parallelism: `--tensor-parallel-size <num_gpus>`.
- Use quantized models (e.g. AWQ, GPTQ) where available.

### Port Conflicts
If port `8000` or `8091` is in use, supply `--port <new_port>`:
```bash
./src/run-vllm-omni-docker.sh --model Qwen/Qwen-Image --port 8095
```
Remember to direct client requests to `http://localhost:8095/v1/...`.

### Kubernetes Troubleshooting & Debugging Guide
For detailed failure analysis and solutions (including the `VLLM_PORT` URI collision, Helm without KUBECONFIG, container image caching, and node certificate IP mismatches), see [`k8s/DEBUG_GUIDE.md`](k8s/DEBUG_GUIDE.md).
