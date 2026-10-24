#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -euo pipefail

readonly DEFAULT_IMAGE="vllm/vllm-omni:latest"
readonly DEFAULT_PORT="8091"

model=""
served_name=""
image="$DEFAULT_IMAGE"
port="$DEFAULT_PORT"
vllm_args=()

usage() {
    cat <<'EOF'
Usage:
  run-vllm-omni-docker.sh --model MODEL [launcher options] [vLLM options...]

Required:
  --model MODEL       Omni/multimodal model ID or local path (e.g. Qwen/Qwen3-Omni-30B-A3B-Instruct).

Launcher options:
  --name NAME         API-visible model name (passed as --served-model-name).
  --image IMAGE       Docker image (default: vllm/vllm-omni:latest).
  --port PORT         Host/container port (default: 8091).
  -h, --help          Show this help text.

All other arguments are passed to `vllm serve MODEL --omni --port PORT` unchanged.
Examples:
  # Omni Multimodal Chat (Audio / Video / Image / Text)
  run-vllm-omni-docker.sh --model Qwen/Qwen3-Omni-30B-A3B-Instruct \
      --name qwen3-omni --tensor-parallel-size 2

  # Diffusion / Text-to-Image
  run-vllm-omni-docker.sh --model Qwen/Qwen-Image \
      --name qwen-image --gpu-memory-utilization 0.8
EOF
}

die() {
    printf 'Error: %s\n\n' "$1" >&2
    usage >&2
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --model)
            [[ $# -ge 2 && -n "$2" ]] || die "--model requires a value"
            model="$2"
            shift 2
            ;;
        --model=*)
            model="${1#*=}"
            [[ -n "$model" ]] || die "--model requires a value"
            shift
            ;;
        --name)
            [[ $# -ge 2 && -n "$2" ]] || die "--name requires a value"
            served_name="$2"
            shift 2
            ;;
        --name=*)
            served_name="${1#*=}"
            [[ -n "$served_name" ]] || die "--name requires a value"
            shift
            ;;
        --image)
            [[ $# -ge 2 && -n "$2" ]] || die "--image requires a value"
            image="$2"
            shift 2
            ;;
        --image=*)
            image="${1#*=}"
            [[ -n "$image" ]] || die "--image requires a value"
            shift
            ;;
        --port)
            [[ $# -ge 2 && -n "$2" ]] || die "--port requires a value"
            port="$2"
            shift 2
            ;;
        --port=*)
            port="${1#*=}"
            [[ -n "$port" ]] || die "--port requires a value"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            vllm_args+=("$@")
            break
            ;;
        *)
            vllm_args+=("$1")
            shift
            ;;
    esac
done

[[ -n "$model" ]] || die "--model is required"

docker_args=(
    run
    -it
    --rm
    --gpus all
    -v "${HOME}/.cache/huggingface:/root/.cache/huggingface"
    --env "HF_TOKEN=${HF_TOKEN-}"
    -p "${port}:${port}"
    --ipc=host
    "$image"
    vllm
    serve
    "$model"
    --omni
    --port "$port"
)

if [[ -n "$served_name" ]]; then
    docker_args+=(--served-model-name "$served_name")
fi

docker_args+=("${vllm_args[@]}")

exec docker "${docker_args[@]}"
