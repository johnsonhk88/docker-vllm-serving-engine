# vLLM Docker Launcher README Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the placeholder README with a step-by-step guide for running, configuring, and testing the dynamic vLLM Docker launcher.

**Architecture:** Keep the documentation centered on the existing `src/run-vllm-docker.sh` interface. Organize the README as a workflow from prerequisites to first request, then add a concise option reference, hardware-oriented examples, client snippets, and troubleshooting guidance. Do not change launcher behavior or unrelated scripts.

**Tech Stack:** Markdown, Bash examples, curl, Python OpenAI SDK.

## Global Constraints

- The README documents the Docker launcher only; existing CLI, Python, and model-specific scripts remain outside this documentation update.
- `--model MODEL` is required.
- `--name NAME` is the API-visible alias generated through `--served-model-name`.
- `--image IMAGE` defaults to `vllm/vllm-openai:v0.17.0`.
- `--port PORT` defaults to `8000`, maps host and container ports, and sets vLLM's listening port.
- All other arguments are passed to vLLM unchanged.
- The README must warn that `--name qwen-small` is valid but `-- name qwen-small` is not.
- Do not modify `src/run-vllm-docker.sh` as part of this task.
- Do not create a git commit unless the user explicitly requests one.

---

## File Map

- Modify: `README.md` - complete step-by-step Docker launcher documentation.
- Reference only: `src/run-vllm-docker.sh` - source of truth for launcher flags and defaults.
- Reference only: `docs/superpowers/specs/2026-10-24-vllm-docker-readme-design.md` - approved documentation scope.

### Task 1: Write the README Quickstart and Reference

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: launcher options and defaults from `src/run-vllm-docker.sh`.
- Produces: copy-paste instructions for setup, startup, readiness, and API requests.

- [ ] **Step 1: Replace the placeholder README with the complete guide**

Replace the complete contents of `README.md` with:

```markdown
# vLLM Serving Engine

Scripts for running and testing vLLM with Docker, the CLI, and Python.

## Overview

`src/run-vllm-docker.sh` is a generic Docker launcher for the vLLM OpenAI-compatible server. Choose the model at runtime instead of editing the script, give it an optional API name, and pass any supported `vllm serve` option for that run.

The launcher keeps these container settings consistent:

- NVIDIA GPU access through Docker.
- Hugging Face cache mounted from `~/.cache/huggingface`.
- `HF_TOKEN` passed into the container.
- Host/container port mapping.
- Automatic container removal when the server stops.

## Prerequisites

Install and verify the following before starting a server:

1. An NVIDIA GPU with a compatible NVIDIA driver.
2. Docker Engine.
3. NVIDIA Container Toolkit, so Docker supports `--gpus all`.
4. A Hugging Face account and access token for gated or private models.

Export the Hugging Face token in the shell that starts the launcher:

```bash
export HF_TOKEN="hf_your_token_here"
```

Public models may work without `HF_TOKEN`. Do not commit tokens to this repository or place them directly in shell scripts.

Verify Docker can access the GPU:

```bash
docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
```

The CUDA image tag can be changed to one available in your environment.

## Step-by-Step Quickstart

### 1. Set the Hugging Face token

Only required for models that need authentication:

```bash
export HF_TOKEN="hf_your_token_here"
```

### 2. Start a model

Start a small model and expose it through the API name `qwen-small`:

```bash
./src/run-vllm-docker.sh \
  --model Qwen/Qwen3-0.6B \
  --name qwen-small \
  --gpu-memory-utilization 0.2
```

The command stays attached to the vLLM server logs. Keep this terminal open while sending requests. Press `Ctrl+C` to stop the server; Docker removes the container because the launcher uses `--rm`.

If the script is not executable, use Bash explicitly:

```bash
bash src/run-vllm-docker.sh \
  --model Qwen/Qwen3-0.6B \
  --name qwen-small \
  --gpu-memory-utilization 0.2
```

The following form is also supported, because the script re-executes itself with Bash:

```bash
sh src/run-vllm-docker.sh \
  --model Qwen/Qwen3-0.6B \
  --name qwen-small \
  --gpu-memory-utilization 0.2
```

### 3. Check server readiness

Open a second terminal and list the models exposed by the server:

```bash
curl http://localhost:8000/v1/models
```

The response should include `qwen-small` when `--name qwen-small` was used. If no response is available, keep watching the startup terminal for model download, GPU memory, or configuration errors.

### 4. Send a chat completion request

Use the value from `--name` in the request's `model` field:

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

If `--name` is omitted, use the model identifier passed to `--model` in the request instead.

## Launcher Options

```text
Usage:
  run-vllm-docker.sh --model MODEL [launcher options] [vLLM options...]
```

| Option | Default | Description |
| --- | --- | --- |
| `--model MODEL` | Required | Hugging Face model ID or local model path passed to vLLM. |
| `--name NAME` | vLLM default | API-visible name passed as `--served-model-name NAME`. Clients use this value in request JSON. |
| `--image IMAGE` | `vllm/vllm-openai:v0.17.0` | Docker image used to start vLLM. |
| `--port PORT` | `8000` | Maps the host and container ports and passes `--port PORT` to vLLM. |
| `-h`, `--help` | None | Print launcher usage and exit. |

All other arguments are passed to vLLM unchanged. This includes options such as:

```bash
--gpu-memory-utilization 0.8
--max-model-len 4096
--max-num-seqs 256
--max-num-batched-tokens 512
--tensor-parallel-size 2
--pipeline-parallel-size 1
--enable-chunked-prefill
--trust-remote-code
```

The launcher owns `--port` so Docker and vLLM always listen on the same port. Use one option with no space between the two hyphens:

```bash
# Correct
--name qwen-small

# Incorrect: this passes `name` and `qwen-small` to vLLM
-- name qwen-small
```

## Model-Serving Examples

These are starting points. The correct settings depend on the GPU, available memory, model format, and vLLM version.

### Low-memory testing

```bash
./src/run-vllm-docker.sh \
  --model Qwen/Qwen3-0.6B \
  --name qwen-small \
  --gpu-memory-utilization 0.2
```

### RTX 3080-class 12 GB GPU

```bash
./src/run-vllm-docker.sh \
  --model Qwen/Qwen3-4B-AWQ \
  --name qwen-4b-awq \
  --gpu-memory-utilization 0.8 \
  --max-model-len 4096 \
  --max-num-seqs 256 \
  --max-num-batched-tokens 512
```

### Multi-GPU 7B model

The value of `--tensor-parallel-size` must match the number of GPUs assigned to vLLM:

```bash
./src/run-vllm-docker.sh \
  --model mistralai/Mistral-7B-Instruct-v0.2 \
  --name mistral-7b \
  --tensor-parallel-size 2 \
  --gpu-memory-utilization 0.9 \
  --max-num-seqs 256
```

## Python Client

Install the OpenAI Python package in your client environment:

```bash
python -m pip install openai
```

With the server running under the alias `qwen-small`, send a request using the OpenAI-compatible API:

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:8000/v1",
    api_key="not-needed-for-local-server",
)

response = client.chat.completions.create(
    model="qwen-small",
    messages=[
        {"role": "user", "content": "What is the capital of France?"},
    ],
)

print(response.choices[0].message.content)
```

## Troubleshooting

### `set: Illegal option -o pipefail`

Do not use `sh` with an older copy of the script. The current launcher re-executes itself with Bash, so this is valid:

```bash
sh src/run-vllm-docker.sh --model Qwen/Qwen3-0.6B --name qwen-small
```

You can also run it directly or invoke Bash explicitly:

```bash
./src/run-vllm-docker.sh --model Qwen/Qwen3-0.6B --name qwen-small
bash src/run-vllm-docker.sh --model Qwen/Qwen3-0.6B --name qwen-small
```

### GPU out-of-memory errors

Try one or more of the following, depending on the model:

- Lower `--gpu-memory-utilization`.
- Lower `--max-model-len`.
- Lower `--max-num-seqs`.
- Lower `--max-num-batched-tokens`.
- Use a smaller or quantized model.
- Use `--tensor-parallel-size` with multiple GPUs.

For example:

```bash
./src/run-vllm-docker.sh \
  --model Qwen/Qwen3-4B-AWQ \
  --name qwen-4b-awq \
  --gpu-memory-utilization 0.7 \
  --max-model-len 2048 \
  --max-num-seqs 32
```

### Port 8000 is already in use

Choose a different port. The launcher updates both Docker and vLLM:

```bash
./src/run-vllm-docker.sh \
  --model Qwen/Qwen3-0.6B \
  --name qwen-small \
  --port 8001
```

Send requests to `http://localhost:8001/v1/...` when using this command.

### The API rejects the model name

Check the name returned by:

```bash
curl http://localhost:8000/v1/models
```

The request's `model` value must exactly match the returned ID. If the launcher was started with `--name qwen-small`, use `"model": "qwen-small"`; if no name was supplied, use the original `--model` value.

### The server does not start

Read the attached Docker/vLLM output first. Common causes include an unavailable model, missing Hugging Face access, unsupported model options, insufficient GPU memory, or an invalid vLLM parameter. Once the server starts, `/v1/models` is the quickest readiness check.
```

- [ ] **Step 2: Check the README examples against the launcher interface**

Run:

```bash
grep -F -- '--model MODEL' README.md
grep -F -- '--name NAME' README.md
grep -F -- '--image IMAGE' README.md
grep -F -- '--port PORT' README.md
grep -F -- 'vllm/vllm-openai:v0.17.0' README.md
grep -F -- 'Qwen/Qwen3-0.6B' README.md
grep -F -- '"model": "qwen-small"' README.md
```

Expected: each command finds the documented interface, default image, quickstart model, and matching API alias.

### Task 2: Verify Documentation Quality

**Files:**
- Verify: `README.md`
- Verify: `src/run-vllm-docker.sh`

**Interfaces:**
- Consumes: the completed README and current launcher source.
- Produces: evidence that the documentation is internally consistent and does not alter launcher behavior.

- [ ] **Step 1: Check Markdown whitespace and inspect the diff**

Run:

```bash
git diff --check
git diff -- README.md
git status --short
```

Expected: no whitespace errors, README contains only the approved documentation changes, and `src/run-vllm-docker.sh` remains the existing user change.

- [ ] **Step 2: Validate the documented launcher syntax without starting Docker**

Run:

```bash
bash -n src/run-vllm-docker.sh
sh src/run-vllm-docker.sh --help >/tmp/vllm-launcher-help.txt
grep -F -- 'run-vllm-docker.sh --model MODEL' /tmp/vllm-launcher-help.txt
```

Expected: Bash syntax validation succeeds, `sh` invocation exits successfully through the self-reexec guard, and help output matches the README usage line.

- [ ] **Step 3: Confirm no implementation files changed**

Run:

```bash
git diff --name-only
```

Expected: only `README.md` is listed among the implementation changes; do not commit unless the user explicitly requests it.
