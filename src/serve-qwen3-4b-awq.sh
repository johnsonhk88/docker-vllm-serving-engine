# test in nvidia RTX 3080 12GB GPU

# Run the vLLM server with the Qwen3-4B-AWQ model
vllm serve "Qwen/Qwen3-4B-AWQ" \
    --max-num-seqs 256 \
    --gpu-memory-utilization 0.8 \
    --kv-cache-memory 6190536294 \
    --enable-chunked-prefill \
    --max-num-batched-tokens 512

vllm serve "Qwen/Qwen3-4B-Instruct-2507" \
    --max-num-seqs 256 \
    --gpu-memory-utilization 0.8 \
    --kv-cache-memory 6190536294 \
    --enable-chunked-prefill \
    --max-num-batched-tokens 512

vllm serve Qwen/Qwen3-4B-Instruct-2507 \
    --max-num-seqs 256 \
	--max-model-len 4096 \
    --gpu-memory-utilization 0.9 \
    --tensor-parallel-size 2 \
    --pipeline-parallel-size 1 \
    --enable-chunked-prefill \
    --max-num-batched-tokens 512 \
    --port 8000

# test query
# Call the server using curl:
curl -X POST "http://localhost:8000/v1/chat/completions" \
	-H "Content-Type: application/json" \
	--data '{
		"model": "Qwen/Qwen3-4B-AWQ",
		"messages": [
			{
				"role": "user",
				"content": "What is the capital of France?"
			}
		]
	}'

curl -X POST "http://localhost:8000/v1/chat/completions" \
	-H "Content-Type: application/json" \
	-d '{
		"model": "Qwen/Qwen3-4B-Instruct-2507"
		"messages": [
			{
				"role": "user",
				"content": "What is the capital of France?"
			}
		]
	}'

curl http://localhost:8000/v1/chat/completions -H "Content-Type: application/json" \ -d '{
        "model": "Qwen/Qwen3-4B-Instruct-2507",
        "messages": [
          {"role": "system", "content": "You are a helpful assistant."},
          {"role": "user", "content": "What is the capital of France?"}
        ]
      }