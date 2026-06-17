docker run \
    -it \
    --rm \
    --gpus all \
    -v ~/.cache/huggingface:/root/.cache/huggingface \
    --env "HF_TOKEN=$HF_TOKEN" \
    -p 8000:8000 \
    --ipc=host \
    vllm/vllm-openai:v0.17.0 \
    --model Qwen/Qwen3-0.6B \
    --gpu-memory-utilization 0.2