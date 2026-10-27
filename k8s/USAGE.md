# How to Use Kubernetes vLLM for LLM Serving

This guide explains how to use the Kubernetes deployment (`helm/vllm/` and `src/run-vllm-k8s.sh`) to serve LLMs in production or local environments, send inference requests from clients (curl, Python, LiteLLM), and perform day-to-day operations.

---

## 1. Quick Overview

Once deployed, vLLM on Kubernetes behaves like an OpenAI-compatible API server running inside the cluster:

| Property | Default (Text LLM) | Default (Omni / Multimodal) |
| --- | --- | --- |
| **Service Name** | `vllm` | `vllm` |
| **Port** | `8000` | `8091` |
| **Default Model** | `Qwen/Qwen3-0.6B` | `Qwen/Qwen-Image` |
| **Default Model Alias** | `qwen-small` | `qwen-image` |
| **Primary Endpoints** | `/health`, `/v1/models`, `/v1/chat/completions` | `/health`, `/v1/models`, `/v1/chat/completions`, `/v1/images/generations` |

---

## 2. Deploying a Model

From the repository root:

### Text Model (Default: Qwen3-0.6B)
```bash
./src/run-vllm-k8s.sh --model Qwen/Qwen3-0.6B --name qwen-small
```

### Larger Text Model
```bash
./src/run-vllm-k8s.sh --model Qwen/Qwen3-4B-Instruct-2507 --name qwen-4b --gpu-util 0.8
```

### Omni / Multimodal Model (Default: Qwen-Image)
```bash
./src/run-vllm-k8s.sh --omni --model Qwen/Qwen-Image --name qwen-image
```

### Monitoring Startup
```bash
# Check pod status (wait for Running and 1/1 Ready)
./src/run-vllm-k8s.sh --status

# Stream engine loading and CUDA graph capture logs
./src/run-vllm-k8s.sh --logs
```

---

## 3. Client Access Methods

The serving engine uses `ClusterIP` by default. Choose the appropriate access method for your clients:

### Method A: Local Port-Forward (Same Host / Laptop)
Run port-forwarding in a terminal:
```bash
./src/run-vllm-k8s.sh --port-forward
```
The API is then reachable on:
```text
http://localhost:8000/v1
```

### Method B: NodePort (LAN / Remote Clients)
If you want other machines on your local network to query the server directly without `kubectl port-forward`:
```bash
./src/run-vllm-k8s.sh \
  --model Qwen/Qwen3-0.6B \
  --name qwen-small \
  --service-type NodePort \
  --nodeport 30080
```
Clients across your network connect to:
```text
http://<node-ip>:30080/v1
```
*(On this host: `http://192.168.0.147:30080/v1`)*

### Method C: In-Cluster Access (Other Pods / Services)
Other workloads running inside the Kubernetes cluster connect via internal DNS without exposing ports:
```text
http://vllm.default.svc.cluster.local:8000/v1
```

---

## 4. Client Request Examples

### curl (Chat Completions)
```bash
curl -X POST "http://localhost:8000/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen-small",
    "messages": [
      {"role": "user", "content": "What is the capital of France?"}
    ],
    "temperature": 0.7,
    "max_tokens": 128
  }'
```

### Python (`requests`)
```python
import requests

response = requests.post(
    "http://localhost:8000/v1/chat/completions",
    json={
        "model": "qwen-small",
        "messages": [
            {"role": "system", "content": "You are a helpful coding assistant."},
            {"role": "user", "content": "Write a Python function to check for prime numbers."}
        ],
        "temperature": 0.2,
    },
)

print(response.json()["choices"][0]["message"]["content"])
```

### Python (`litellm`)
```python
import litellm

response = litellm.completion(
    model="openai/qwen-small",
    api_base="http://localhost:8000/v1",
    api_key="none",
    messages=[
        {"role": "user", "content": "Explain Kubernetes pods in two sentences."}
    ],
)

print(response.choices[0].message.content)
```

> **Note on Model Name:** Always pass the `--name` value (`qwen-small`), not the full Hugging Face ID (`Qwen/Qwen3-0.6B`), in the `"model"` field of API requests.

---

## 5. Omni & Image Generation Requests

When running an Omni / Diffusion model on port `8091`:

### Text-to-Image Generation (curl)
```bash
curl -X POST "http://localhost:8091/v1/images/generations" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen-image",
    "prompt": "A serene Japanese zen garden with maple leaves",
    "n": 1,
    "size": "1024x1024"
  }' | jq -r '.data[0].b64_json' | base64 -d > zen.png
```

### Text-to-Image Generation (LiteLLM)
```python
import litellm

response = litellm.image_generation(
    model="openai/qwen-image",
    api_base="http://localhost:8091/v1",
    api_key="none",
    prompt="A futuristic cyberpunk train at night in rain",
    size="1024x1024",
)
print("Image generated successfully!")
```

---

## 6. Daily Operations & Management

### Check Serving Health
```bash
# Automated verification test suite
./src/test-k8s.sh --skip-deploy --python

# Direct health endpoint
curl -s http://localhost:8000/health
curl -s http://localhost:8000/v1/models | jq .
```

### Stop Serving Engine / Clean Up
```bash
./src/run-vllm-k8s.sh --delete
```

### Troubleshooting
If the pod encounters any issues, consult the detailed guide:
- **[`k8s/DEBUG_GUIDE.md`](DEBUG_GUIDE.md)**
