# Kubernetes vLLM Deployment & Debugging Guide

This document captures the real-world deployment challenges, root causes, and solutions encountered when serving **vLLM** and **vLLM-Omni** on Kubernetes (specifically MicroK8s and single-node/multi-node clusters with NVIDIA GPU acceleration).

---

## Quick Reference: Known Failure Modes & Fixes

| Failure / Symptom | Root Cause | Solution |
| --- | --- | --- |
| `Error: kubernetes cluster unreachable (127.0.0.1:8080)` | Upstream Helm cannot find kubeconfig when `kubectl` is aliased to MicroK8s. | Export `KUBECONFIG=/var/snap/microk8s/current/credentials/client.config` (automated in scripts). |
| `nvidia.com/gpu is not allocatable` | Kubernetes GPU device plugin / operator is disabled. | Run `microk8s enable gpu`. |
| `ValueError: VLLM_PORT appears to be a URI` | Kubernetes automatically injects `VLLM_PORT=tcp://<IP>:<PORT>` for services named `vllm`. | Add `enableServiceLinks: false` in Pod spec and set `VLLM_PORT: "8000"`. |
| Pod hangs in `ContainerCreating` for ~5 mins | First-time download of 8.6 GB container image by containerd. | Normal on first pull; cached permanently in containerd for fast subsequent starts. |
| `tls: failed to verify certificate: x509: valid for IP X, not Y` | Host machine's LAN IP changed, causing apiserver proxy to reject kubelet TLS. | Regenerate `kubelet.crt` with new IP in SANs; runner includes direct bridge fallback. |
| Vision Chat returns 400 Bad Request on text model | Test script passed image URL to a text-only model. | Added smart model dispatch and `--mode text` to `src/test-vllm-omni.py`. |

---

## 1. Issue: Helm Cluster Unreachable (`127.0.0.1:8080`)

### Symptom
Running `./src/run-vllm-k8s.sh` or `./src/test-k8s.sh` failed with:
```text
Error: kubernetes cluster unreachable: Get "http://localhost:8080/version": dial tcp 127.0.0.1:8080: connect: connection refused
```

### Root Cause
- `kubectl` on MicroK8s systems is aliased to `/snap/bin/microk8s.kubectl`, which automatically reads `/var/snap/microk8s/current/credentials/client.config`.
- Standalone Helm (`/usr/bin/helm`), however, follows standard Kubernetes client rules. Because neither `$KUBECONFIG` was exported nor did `~/.kube/config` exist, Helm fell back to `http://localhost:8080`.

### Fix
In both `src/run-vllm-k8s.sh` and `src/test-k8s.sh`, added automatic discovery of MicroK8s credentials:
```bash
if [[ -z "${KUBECONFIG:-}" && ! -f "${HOME}/.kube/config" ]]; then
    if [[ -r "/var/snap/microk8s/current/credentials/client.config" ]]; then
        export KUBECONFIG="/var/snap/microk8s/current/credentials/client.config"
    fi
fi
```
Alternatively, generate a global user kubeconfig:
```bash
mkdir -p ~/.kube
microk8s config > ~/.kube/config
chmod 600 ~/.kube/config
```

---

## 2. Issue: Cluster GPU Allocation Missing

### Symptom
Preflight checks reported:
```text
[!] Node GPU resource 'nvidia.com/gpu' is NOT currently allocatable on ray-head.
```

### Root Cause
Even when the host machine has NVIDIA drivers and Docker GPU acceleration working, Kubernetes needs the NVIDIA GPU Operator or K8s Device Plugin to expose GPU resources to the kubelet scheduler.

### Fix
Enable the MicroK8s GPU operator:
```bash
microk8s enable gpu
```
Verify allocatable GPU resources:
```bash
kubectl get node -o custom-columns=NAME:.metadata.name,GPUS:.status.allocatable."nvidia\.com/gpu"
```

---

## 3. Issue: Primary Crash — `VLLM_PORT` URI Collision

### Symptom
The deployment created the pod, but it immediately crashed (`CrashLoopBackOff`, exit code 1):
```text
(EngineCore_DP0 pid=166)   File "/usr/local/lib/python3.12/dist-packages/vllm/envs.py", line 437, in get_vllm_port
(EngineCore_DP0 pid=166)     raise ValueError(
(EngineCore_DP0 pid=166) ValueError: VLLM_PORT 'tcp://10.152.183.137:8000' appears to be a URI.
This may be caused by a Kubernetes service discovery issue, check the warning in: https://docs.vllm.ai/en/stable/serving/env_vars.html
```

### Root Cause
Kubernetes has legacy Docker-link service discovery built into every container. When a Service named `vllm` exists in the namespace, Kubernetes automatically injects environment variables into all pods in that namespace:
```text
VLLM_PORT=tcp://10.152.183.137:8000
VLLM_PORT_8000_TCP=tcp://10.152.183.137:8000
VLLM_SERVICE_HOST=10.152.183.137
VLLM_SERVICE_PORT=8000
```
However, inside vLLM (`vllm.envs`), `VLLM_PORT` is an internal configuration variable for engine/API port binding and strictly expects an **integer** (like `8000`). Receiving `tcp://...` triggered an immediate unhandled `ValueError`.

### Fix
In `helm/vllm/templates/deployment.yaml`, `k8s/vllm-text.yaml`, and `k8s/vllm-omni.yaml`:

1. **Disable Service Link Injection:**
   ```yaml
   spec:
     template:
       spec:
         enableServiceLinks: false
   ```
2. **Explicitly set `VLLM_PORT` in container environment:**
   ```yaml
         containers:
           - name: vllm
             env:
               - name: VLLM_PORT
                 value: "8000"  # or "8091" for omni
   ```

---

## 4. Issue: First-Launch Container Creation Latency

### Symptom
The pod remained in `Pending` / `ContainerCreating` for ~5 minutes on the initial run.

### Root Cause
MicroK8s uses `containerd` as its CRI runtime, which does not share image storage with Docker Engine (`docker images`). The 8.6 GB container image `vllm/vllm-openai:v0.17.0` had to be pulled over the network into containerd.

### Fix & Handling
- Containerd caches the image layers locally after the first download. Subsequent pod starts take ~5 seconds to initialize.
- Enhanced `src/test-k8s.sh` to track `ContainerCreating` vs `CrashLoopBackOff` in real time, so developers can distinguish between active image downloads and unexpected process failures.

---

## 5. Issue: Host LAN IP Mismatch & Kubelet Certificate Verification

### Symptom
When streaming logs (`kubectl logs`) or port-forwarding (`kubectl port-forward`):
```text
error: error upgrading connection: error dialing backend: tls: failed to verify certificate:
x509: certificate is valid for 192.168.1.217, not 192.168.0.147
```

### Root Cause
If the host machine receives a new LAN IP via DHCP (e.g. changed from `192.168.1.217` to `192.168.0.147`), the MicroK8s Kubelet certificate on port 10250 (`/var/snap/microk8s/current/certs/kubelet.crt`) still holds the old IP address in its Subject Alternative Names (SANs). When `kube-apiserver` dials kubelet to proxy logs or port-forwards, TLS verification fails.

### Fix
1. **Regenerate Kubelet Certificate:**
   Re-sign `kubelet.crt` with the current IP address added to the SAN list:
   ```bash
   openssl req -new -key /var/snap/microk8s/current/certs/kubelet.key \
     -out /tmp/kubelet.csr \
     -subj "/CN=system:node:ray-head/O=system:nodes" \
     -addext "subjectAltName=DNS:ray-head,IP:192.168.0.147,IP:127.0.0.1"

   openssl x509 -req -in /tmp/kubelet.csr \
     -CA /var/snap/microk8s/current/certs/ca.crt \
     -CAkey /var/snap/microk8s/current/certs/ca.key \
     -CAcreateserial -out /tmp/kubelet.crt -days 3650

   cp /tmp/kubelet.crt /var/snap/microk8s/current/certs/kubelet.crt
   ```
2. **Automated Test Runner Fallback (`src/test-k8s.sh`):**
   `src/test-k8s.sh` tests standard `kubectl port-forward` first. If an apiserver TLS proxy issue is detected but the Pod is healthy, the runner establishes a local TCP bridge directly to the Pod IP on the cluster network, ensuring tests run reliably without interruption.

---

## 6. Diagnostic Cheat Sheet

### Check Pod Status & Direct Pod IP
```bash
kubectl get pods -o wide -l app.kubernetes.io/name=vllm
```

### Direct Health Probe to Pod IP (Bypassing Service Proxy)
```bash
POD_IP=$(kubectl get pod -l app.kubernetes.io/name=vllm -o jsonpath='{.items[0].status.podIP}')
curl -s http://${POD_IP}:8000/health
```

### View Real-Time containerd Image Pull Activity
```bash
journalctl -u snap.microk8s.daemon-containerd -f
```

### Query Active Models on the Serving Engine
```bash
curl -s http://localhost:8000/v1/models | jq .
```

### Test Chat Inference
```bash
curl -X POST "http://localhost:8000/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen-small",
    "messages": [{"role": "user", "content": "What is the capital of France?"}]
  }'
```

---

## Automated Test Verification
Run the complete automated test suite with Python verification:
```bash
./src/test-k8s.sh --skip-deploy --python
```
All four assertions (Health Probe, Model Discovery, OpenAI Chat Inference, and Python Suite) should return `PASS`.
