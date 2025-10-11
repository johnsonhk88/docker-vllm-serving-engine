vllm serve mistralai/Mistral-7B-Instruct-v0.2 \
    --max-num-seqs 256 \
    --gpu-memory-utilization 0.9 \
    --tensor-parallel-size 2 \
    --pipeline-parallel-size 1 \
    --kv-cache-memory 6190536294 \
    --enable-chunked-prefill \
    --max-num-batched-tokens 512 \
    --port 8000