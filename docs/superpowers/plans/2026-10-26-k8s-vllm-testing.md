# Kubernetes vLLM Automated Testing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a robust automated testing script `src/test-k8s.sh` for Kubernetes vLLM deployments and execute live verification on the cluster.

**Architecture:** A modular Bash orchestrator with preflight GPU/cluster detection, deployment orchestration via `src/run-vllm-k8s.sh`, reliable background port-forwarding with POSIX exit traps, automated curl assertions against OpenAI endpoints, and an optional deep Python test suite flag (`--python`).

**Tech Stack:** Bash, kubectl, MicroK8s, curl, jq, Python 3, requests, LiteLLM.

## Global Constraints

- Bash scripts must re-exec cleanly if executed via `sh` or `bash`.
- Background `kubectl port-forward` processes must be safely terminated upon exit or abort (via `trap ... EXIT INT TERM`).
- Non-destructive by default: do not delete deployments unless `--cleanup` is specified.
- Respect existing repo conventions and script structures (`src/run-vllm-k8s.sh`).

---

### Task 1: CLI Interface and Preflight Checks in `src/test-k8s.sh`

**Files:**
- Create: `src/test-k8s.sh`

**Interfaces:**
- Consumes: cluster environment (`kubectl`, `microk8s.kubectl`)
- Produces: CLI options parser (`--mode`, `--model`, `--name`, `--port`, `--python`, `--skip-deploy`, `--cleanup`, `--timeout`, `--namespace`), preflight validation of GPU allocatables and CLI tools.

- [ ] **Step 1: Write CLI argument parser and preflight checks in `src/test-k8s.sh`**
- [ ] **Step 2: Add executable permissions (`chmod +x src/test-k8s.sh`)**
- [ ] **Step 3: Test CLI help output and preflight detection (`./src/test-k8s.sh --help`)**

---

### Task 2: Deployment Orchestration, Pod Readiness Polling, and Port-Forward Trap

**Files:**
- Modify: `src/test-k8s.sh`

**Interfaces:**
- Consumes: `src/run-vllm-k8s.sh`
- Produces: deployment invocation, polling loop waiting for pod readiness, background port-forwarding with PID tracking and POSIX trap cleanup.

- [ ] **Step 1: Implement deployment trigger using `src/run-vllm-k8s.sh` (or skip if `--skip-deploy`)**
- [ ] **Step 2: Implement readiness polling loop with timeout reporting**
- [ ] **Step 3: Implement background port-forwarding with connection readiness check and trap handler**
- [ ] **Step 4: Test port-forward trap handling under dry-run / simulated conditions**

---

### Task 3: HTTP Endpoint Assertions & Results Reporting

**Files:**
- Modify: `src/test-k8s.sh`

**Interfaces:**
- Consumes: forwarded local port (`http://localhost:$PORT`)
- Produces: HTTP tests for `/health`, `/v1/models`, and `/v1/chat/completions` (or `/v1/images/generations`), formatted summary table.

- [ ] **Step 1: Implement `/health` probe assertion**
- [ ] **Step 2: Implement `/v1/models` JSON model ID assertion**
- [ ] **Step 3: Implement inference request assertion with latency measurement**
- [ ] **Step 4: Implement formatted ANSI summary report table**

---

### Task 4: Python Test Suite Integration (`--python`) & Documentation

**Files:**
- Modify: `src/test-k8s.sh`
- Modify: `k8s/README.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: `src/test-vllm-omni.py`
- Produces: invocation of Python runner when `--python` flag is passed, comprehensive documentation in READMEs.

- [ ] **Step 1: Wire `--python` flag to trigger `python3 src/test-vllm-omni.py`**
- [ ] **Step 2: Update `k8s/README.md` and `README.md` with `src/test-k8s.sh` usage and examples**
- [ ] **Step 3: Validate syntax and linting**

---

### Task 5: Live Verification & Testing on Cluster

**Files:**
- Test against: Kubernetes cluster / MicroK8s

**Interfaces:**
- Consumes: `src/test-k8s.sh`
- Produces: live test execution, verifying GPU allocatable status, deploying test model, and running endpoint assertions.

- [ ] **Step 1: Run preflight checks on local cluster (`./src/test-k8s.sh --help` & check allocatable GPU)**
- [ ] **Step 2: Verify dry-run / readiness behavior**
- [ ] **Step 3: Document instructions for full live test run once MicroK8s GPU addon is enabled**
