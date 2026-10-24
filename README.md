# vLLM Serving Engine

Scripts for running and testing vLLM and vLLM-Omni with Docker, the CLI, and Python.

## Available Launchers

| Script | Targeted Modalities | Default Docker Image | Default Port | Primary Endpoints |
| --- | --- | --- | --- | --- |
| `src/run-vllm-docker.sh` | Text LLMs (Qwen, Mistral, Llama, etc.) | `vllm/vllm-openai:v0.17.0` | `8000` | `/v1/chat/completions` |
| `src/run-vllm-omni-docker.sh` | Omni-modality (Video, Audio, Image, Text, Diffusion DiT, TTS) | `vllm/vllm-omni:latest` | `8091` | `/v1/chat/completions`, `/v1/images/generations`, `/v1/audio/speech` |

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
