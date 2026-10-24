# vLLM Docker Launcher README

## Goal

Replace the placeholder `README.md` with a practical, step-by-step guide for running the dynamic Docker launcher in `src/run-vllm-docker.sh`.

## Audience and Scope

The README targets developers who want to serve different vLLM models through the OpenAI-compatible Docker API. It documents the Docker launcher only; existing CLI, Python, and model-specific scripts remain outside this documentation update.

## Document Structure

The README will contain these sections in order:

1. Overview.
2. Prerequisites.
3. Step-by-step quickstart.
4. Launcher option reference.
5. Model-serving examples.
6. Client testing with curl and Python.
7. Troubleshooting and tuning tips.

## Required Content

### Overview

Explain that the launcher accepts a model at runtime rather than hardcoding one model, preserves GPU and Hugging Face cache configuration, and forwards arbitrary vLLM serving flags.

### Prerequisites

List an NVIDIA GPU with compatible drivers, Docker, NVIDIA Container Toolkit, and the Hugging Face CLI/account requirement for gated or private models. Show `export HF_TOKEN="..."` and explain that public models may not need a token.

### Quickstart

Provide exact commands to:

1. Set `HF_TOKEN` when needed.
2. Start `Qwen/Qwen3-0.6B` with `--name qwen-small`.
3. Check `/v1/models`.
4. Send a chat completion request using `"model": "qwen-small"`.

State that the terminal running Docker remains attached and that `Ctrl+C` stops and removes the container because the launcher uses `--rm`.

### Option Reference

Document:

- `--model MODEL` as required and passed to vLLM's model option.
- `--name NAME` as the API-visible alias generated through `--served-model-name`; explain that clients use this value in request JSON.
- `--image IMAGE` with default `vllm/vllm-openai:v0.17.0`.
- `--port PORT` with default `8000`, mapping host and container ports and setting vLLM's listening port.
- `--help`.
- All other arguments as unchanged vLLM passthrough arguments.

Warn that `--name` must be written as one option (`--name qwen-small`), not `-- name qwen-small`.

### Examples

Include commands for:

- Low-memory testing with `Qwen/Qwen3-0.6B` and `--gpu-memory-utilization 0.2`.
- An RTX 3080-class 12 GB setup with `Qwen/Qwen3-4B-AWQ`, `--gpu-memory-utilization 0.8`, and `--max-model-len 4096`.
- A multi-GPU 7B setup with `--tensor-parallel-size 2`.

Examples must identify that hardware availability and model compatibility determine the correct values; they are starting points rather than guarantees.

### Client Testing

Provide a curl request against `/v1/chat/completions` and a short Python `openai` client example using `base_url="http://localhost:8000/v1"`. Both examples must use the API model alias selected by the startup command.

### Troubleshooting

Cover:

- Use `./src/run-vllm-docker.sh`, `bash src/run-vllm-docker.sh`, or `sh src/run-vllm-docker.sh`; the script re-executes itself with Bash for the `sh` form.
- Correct the common `-- name` typo.
- Reduce `--gpu-memory-utilization`, `--max-model-len`, or batching options for GPU out-of-memory failures.
- Use `docker` logs/output and `/v1/models` to distinguish startup failures from client model-name mismatches.
- Use a different `--port` when host port `8000` is occupied and send clients to the matching port.

## Verification

- Check every documented launcher flag against the current script.
- Ensure every copy-paste command uses valid shell syntax and a matching API model name.
- Run Markdown whitespace checks and inspect the final diff.
- Do not modify the launcher or unrelated README sections beyond this documentation scope.
