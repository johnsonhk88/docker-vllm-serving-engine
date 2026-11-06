# OpenCode Tool Calling with vLLM

This guide configures a local vLLM server and OpenCode so the agent can call tools. It covers the required vLLM flags, parser selection, OpenCode provider settings, verification, and Kubernetes deployment.

## Why vLLM needs extra flags

OpenCode enables tools for a model when that model declares tool support. It then sends OpenAI-style tool definitions and sets this request field:

```json
"tool_choice": "auto"
```

vLLM only accepts `tool_choice: "auto"` when the server was started with both:

- `--enable-auto-tool-choice`
- `--tool-call-parser <parser>`

Without them, the request fails immediately with:

```text
"auto" tool choice requires --enable-auto-tool-choice and --tool-call-parser to be set
```

## Docker

### Qwen3 instruct models

Qwen3 and Qwen2.5 instruct models emit Hermes-style tool calls: a JSON object inside `<tool_call>...</tool_call>` tags. Use the `hermes` parser:

```bash
./src/run-vllm-docker.sh \
  --model Qwen/Qwen3-0.6B \
  --name qwen-small \
  --gpu-memory-utilization 0.2 \
  --enable-auto-tool-choice \
  --tool-call-parser hermes
```

vLLM registers the model under the `--name` value. OpenCode must send that same value in its `modelID` field (or use it as the model key when `modelID` is omitted).

### Qwen3-Coder

Qwen3-Coder uses a different tool-call format. Use the `qwen3_coder` parser:

```bash
./src/run-vllm-docker.sh \
  --model Qwen/Qwen3-Coder-30B-A3B-Instruct \
  --name qwen3-coder \
  --gpu-memory-utilization 0.9 \
  --enable-auto-tool-choice \
  --tool-call-parser qwen3_coder
```

### Parser selection

| Model / tool-call format | `--tool-call-parser` |
| --- | --- |
| Qwen3 instruct, Qwen2.5 instruct, Hermes-style JSON | `hermes` |
| Qwen3-Coder | `qwen3_coder` |
| Qwen3 XML-style tool calls | `qwen3_xml` |
| Llama 3.x | `llama3_json` |
| Mistral | `mistral` |

The parser must match the model's chat template. Using the wrong parser still lets the server start, but tool calls may come back as plain text or malformed JSON. Check the model's `tokenizer_config.json` chat template or vLLM's tool parser list when unsure.

`--enable-auto-tool-choice` and `--tool-call-parser` must be used together. vLLM refuses to start if auto tool choice is enabled without a parser.

## OpenCode configuration

OpenCode's built-in `vllm` provider discovers models from `http://127.0.0.1:8000/v1`. Discovery cannot infer tool support, so declare `capabilities.tools: true` explicitly.

Minimal `opencode.jsonc`:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "providers": {
    "vllm": {
      "name": "vLLM (local)",
      "settings": {
        "baseURL": "http://127.0.0.1:8000/v1"
      },
      "models": {
        "qwen-small": {
          "modelID": "qwen-small",
          "name": "Qwen3 0.6B (vLLM)",
          "capabilities": {
            "tools": true,
            "input": ["text"],
            "output": ["text"]
          },
          "limit": {
            "context": 40960,
            "output": 8192
          }
        }
      }
    }
  }
}
```

Notes:

- `baseURL` must include `/v1`.
- `modelID` is the value sent in the request's `model` field. It must match vLLM's `--served-model-name` (or the model ID reported by `GET /v1/models`).
- `capabilities.tools: true` is required. Without it, OpenCode does not send tools to vLLM.
- Set `limit.context` to the `max_model_len` reported by `GET /v1/models`, or lower. `Qwen/Qwen3-0.6B` reports `40960` with the default vLLM configuration.
- OpenCode reloads configuration automatically. Use `/reload` if a changed model list is not picked up.

Select the model with `/models` → `vllm/qwen-small`, or set it as the default:

```jsonc
{
  "model": "vllm/qwen-small"
}
```

If you serve Qwen3-Coder, add a second model entry whose key and `modelID` match the server's `--served-model-name`:

```jsonc
"qwen3-coder": {
  "modelID": "qwen3-coder",
  "name": "Qwen3 Coder 30B-A3B (vLLM)",
  "capabilities": {
    "tools": true,
    "input": ["text"],
    "output": ["text"]
  },
  "limit": {
    "context": 65536,
    "output": 16384
  }
}
```

The `65536` context above is an example; adjust it to the `max_model_len` reported by the running Qwen3-Coder server.

Each vLLM process serves one model. Point OpenCode at the model name returned by `/v1/models` for the currently running server.

## Verify tool calling

Send a request with tools and `tool_choice: "auto"`:

```bash
curl -s http://127.0.0.1:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen-small",
    "messages": [
      {"role": "user", "content": "What is the weather in Hong Kong? Use the get_weather tool."}
    ],
    "tools": [
      {
        "type": "function",
        "function": {
          "name": "get_weather",
          "description": "Get the current weather for a city",
          "parameters": {
            "type": "object",
            "properties": {
              "city": {"type": "string", "description": "City name"}
            },
            "required": ["city"]
          }
        }
      }
    ],
    "tool_choice": "auto",
    "max_tokens": 256
  }' | jq
```

A successful response is HTTP 200. A model with good tool-calling behavior returns `choices[0].message.tool_calls`; smaller models may return plain text instead. The important part is that vLLM no longer rejects the request.

For a deterministic parser check, set `"tool_choice": "required"` or name the function. Both require a tool parser and force a tool call instead of leaving the decision to the model.

## Kubernetes

The Helm chart exposes arbitrary vLLM arguments through `extraArgs`.

Create `values-tool-calling.yaml`:

```yaml
mode: text
model: Qwen/Qwen3-0.6B
servedModelName: qwen-small

extraArgs:
  - --enable-auto-tool-choice
  - --tool-call-parser
  - hermes
```

Deploy:

```bash
helm upgrade --install vllm ./helm/vllm -f values-tool-calling.yaml
```

For Qwen3-Coder, change `model`, `servedModelName`, and the parser to `qwen3_coder`.

For raw manifests, add the same entries under the container's `args` in [`k8s/vllm-text.yaml`](../k8s/vllm-text.yaml):

```yaml
args:
  - "--model"
  - "Qwen/Qwen3-0.6B"
  - "--served-model-name"
  - "qwen-small"
  - "--port"
  - "8000"
  - "--gpu-memory-utilization"
  - "0.2"
  - "--enable-auto-tool-choice"
  - "--tool-call-parser"
  - "hermes"
```

Then apply and port-forward as usual:

```bash
kubectl apply -f k8s/vllm-text.yaml
./src/run-vllm-k8s.sh --port-forward
```

The convenience script `src/run-vllm-k8s.sh` does not forward arbitrary vLLM flags, so use Helm `extraArgs` or the raw manifest for tool-calling flags.

## Troubleshooting

### Error: `"auto" tool choice requires --enable-auto-tool-choice and --tool-call-parser to be set`

The running vLLM process does not have the flags. Check its command line:

```bash
docker ps --format '{{.ID}}\t{{.Image}}\t{{.Command}}'
```

Stop the old container and restart it with both flags. Changing the OpenCode configuration cannot fix this; the vLLM server must be restarted.

### Server starts, but tool calls appear as text

The parser does not match the model's tool-call format. Qwen3 instruct models use `hermes`; Qwen3-Coder uses `qwen3_coder`. Review the parser table above and check the model's chat template.

### `maximum context length` errors in OpenCode

OpenCode trusts the configured `limit.context`. If it is larger than vLLM's `max_model_len`, requests can exceed the server limit. Read the value from:

```bash
curl -s http://127.0.0.1:8000/v1/models | jq '.data[0].max_model_len'
```

Set `limit.context` to that value or lower.

### The model calls tools unreliably

Tool-calling quality depends on the model. `Qwen/Qwen3-0.6B` is useful for smoke tests, but larger Qwen3 instruct models or `Qwen3-Coder` are better for agent workloads.

## See also

- [vLLM serving quickstart](../README.md)
- [OpenCode providers documentation](https://opencode.ai/v2/docs/providers)
- [OpenCode models documentation](https://opencode.ai/v2/docs/models)
