# Kubernetes vLLM Automated Testing & Verification Design

## Goal

Provide a robust automated test runner (`src/test-k8s.sh`) and end-to-end verification workflow for testing vLLM and vLLM-Omni deployments on Kubernetes (MicroK8s and standard K8s clusters).

## Context & Problem Statement

Deploying vLLM on Kubernetes involves multiple asynchronous stages:
1. GPU resource availability on nodes (`nvidia.com/gpu`).
2. Secret provisioning for Hugging Face tokens (`hf-token-secret`).
3. Helm or declarative manifest application.
4. Container image retrieval and model weight loading into VRAM.
5. ClusterIP networking with required port-forwarding for external or client validation.
6. Verification across OpenAI-compatible endpoints (`/health`, `/v1/models`, `/v1/chat/completions`, and `/v1/images/generations`).

Currently, developers must manually run `run-vllm-k8s.sh`, check pod status, open a separate terminal for `port-forward`, and manually formulate `curl` commands or run python scripts.

## System Architecture

The testing framework combines a Bash test orchestrator (`src/test-k8s.sh`) with optional deep Python validation (`src/test-vllm-omni.py`).

```text
+-----------------------------------------------------------------------------------+
|                              src/test-k8s.sh                                      |
|                                                                                   |
|  [Phase 1: Preflight Verification]                                                |
|    - Detect kubectl and helm                                                      |
|    - Verify node allocatable GPU (nvidia.com/gpu)                                 |
|    - Warn / check if MicroK8s GPU addon is required                               |
|    - Verify container image presence or import availability                       |
|                                                                                   |
|  [Phase 2: Deployment Orchestration]                                              |
|    - Unless --skip-deploy: invoke src/run-vllm-k8s.sh                             |
|    - Stream or poll kubectl rollout status / pod readiness                        |
|                                                                                   |
|  [Phase 3: Managed Port-Forwarding]                                               |
|    - Start kubectl port-forward in background                                     |
|    - Register POSIX trap (EXIT INT TERM) to ensure process termination            |
|    - Wait for local socket readiness                                              |
|                                                                                   |
|  [Phase 4: Endpoint Assertions]                                                   |
|    - GET /health -> assert HTTP 200                                               |
|    - GET /v1/models -> assert expected model ID is returned                       |
|    - POST /v1/chat/completions (text) or /v1/images/generations (omni)             |
|                                                                                   |
|  [Phase 5: Optional Deep Python Suite (--python)]                                 |
|    - Execute python3 src/test-vllm-omni.py --url http://localhost:$PORT/v1        |
|    - Validate token output or image binary generation                             |
|                                                                                   |
|  [Phase 6: Reporting & Teardown]                                                  |
|    - Print summary table (Endpoints, Latency, Status)                             |
|    - If --cleanup: uninstall Helm release or delete manifest resources           |
+-----------------------------------------------------------------------------------+
```

## CLI Specification

### Script: `src/test-k8s.sh`

```text
Usage:
  test-k8s.sh [options]

Options:
  --mode MODE         Modality: 'text' (default) or 'omni'
  --model MODEL       Model name/ID (default: Qwen/Qwen3-0.6B for text, Qwen/Qwen-Image for omni)
  --name NAME         API-visible model alias (default: qwen-small or qwen-image)
  --port PORT         Local port to forward to (default: 8000 for text, 8091 for omni)
  --python            Run the deep Python/LiteLLM test suite (Approach 2)
  --skip-deploy       Skip deployment and test against an existing running pod/service
  --cleanup           Delete deployment and secrets after testing concludes
  --timeout SECS      Timeout in seconds waiting for pod readiness (default: 300)
  --namespace NS      Kubernetes namespace (default: default)
  -h, --help          Show usage help
```

## Test Stages & Assertion Details

### 1. Preflight Validation
- Checks whether `kubectl` or `microk8s kubectl` is executable.
- Checks `status.allocatable."nvidia.com/gpu"` on cluster nodes. If `0` or missing, alerts user with instructions (`microk8s enable gpu`).
- Verifies if Docker / containerd has the required image (`vllm/vllm-openai:v0.17.0` or `vllm/vllm-omni:latest`).

### 2. Readiness Polling
- Uses `kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=vllm --timeout=${TIMEOUT}s` (with fallback to `app=vllm`).
- Periodically reports elapsed time and pod status (Pending / ContainerCreating / Running).

### 3. Connection & Port-Forward Trap
- Background port-forward launched via:
  ```bash
  "$KUBECTL" -n "$NAMESPACE" port-forward "svc/$SVC_NAME" "${PORT}:${PORT}" > /tmp/vllm-pf.log 2>&1 &
  PF_PID=$!
  ```
- Trap handler guarantees cleanup:
  ```bash
  cleanup() {
      if [[ -n "${PF_PID:-}" ]] && kill -0 "$PF_PID" 2>/dev/null; then
          kill "$PF_PID" 2>/dev/null || true
      fi
      if [[ "$CLEANUP_DEPLOY" == true ]]; then
          "${REPO_ROOT}/src/run-vllm-k8s.sh" --delete --namespace "$NAMESPACE"
      fi
  }
  trap cleanup EXIT INT TERM
  ```

### 4. HTTP Assertions
- **Test 1: Health Probe**
  - Endpoint: `http://localhost:${PORT}/health`
  - Expected: HTTP 200 OK
- **Test 2: Model Listing**
  - Endpoint: `http://localhost:${PORT}/v1/models`
  - Expected: JSON contains `data` array with matching model alias or ID.
- **Test 3: Completion / Generation**
  - For `text`: `POST /v1/chat/completions` with user prompt `"Reply with the word PONG"`.
  - Asserts response contains choices with non-empty message content.
  - For `omni`: `POST /v1/images/generations` or `POST /v1/chat/completions` (depending on loaded omni model).

### 5. Optional Python Suite (`--python`)
- If `--python` is provided, invokes `python3 src/test-vllm-omni.py --url "http://localhost:${PORT}/v1" --mode all`.
- Propagates success or failure status into overall test report.

## Error Handling & Failure Modes

1. **GPU Missing in Cluster:** Early abort with actionable error:
   ```
   [!] Error: 'nvidia.com/gpu' resource not found in cluster node allocatables.
       Run 'microk8s enable gpu' or configure NVIDIA GPU operator first.
   ```
2. **Pod Startup Timeout:** Prints recent pod events and container logs (`kubectl describe pod`, `kubectl logs`) before exiting.
3. **Port Conflict:** Detects if local port is occupied before launching port-forward; offers `--port <custom_port>`.

## Verification Plan

1. Verify `src/test-k8s.sh --help` works cleanly.
2. Verify preflight checks accurately report GPU status.
3. Live cluster test:
   - Run preflight check.
   - If MicroK8s GPU is enabled, execute `./src/test-k8s.sh --model Qwen/Qwen3-0.6B --name qwen-small`.
   - Validate assertion output and port-forward process cleanup.
