# GitOps Monitoring + AI SRE Agent


A fully GitOps-managed observability stack with an AI agent that automatically analyzes Kubernetes issues, interprets logs and metrics, and surfaces root cause in plain English directly in Grafana.

## Architecture

```
Git Repository (source of truth)
         │  ArgoCD syncs
         ▼
┌──────────────────────────────────────────────────────────┐
│                      ArgoCD                              │
│         (reconciles all apps from this repo)             │
└──┬────────┬──────────┬───────────┬─────────────────────-┘
   │        │          │           │
   ▼        ▼          ▼           ▼
LGTM     Demo App   Ollama    k8sgpt Operator
Stack    (OTel)     (LLM)     (AI Analyzer)
   │        │          │           │
   └────────┴──────────┴─────┬─────┘
                              ▼
                    Grafana Dashboard
                  "AI SRE Agent Analysis"
```

### Stack

| Layer | Tool | Purpose |
|---|---|---|
| GitOps | ArgoCD | App-of-apps, continuous reconciliation |
| Collector | **Grafana Alloy** | Metrics + Logs + Traces in one DaemonSet |
| Metrics | Prometheus | Storage + AlertManager |
| Logs | Loki | Pod logs + k8s events |
| Traces | Tempo | Distributed tracing |
| Visualization | Grafana | Unified dashboards |
| LLM | **Ollama + llama3.2:3b** | Self-hosted, no API key needed |
| AI Agent | **k8sgpt operator** | Kubernetes-native analyzer, stores `Result` CRDs |
| Demo App | OpenTelemetry Demo | Pre-instrumented microservices with fault injection |

## Prerequisites

```bash
# Required
brew install k3d kubectl helm git   # macOS
# or
apt install kubectl git && pip install helm  # Linux

# Verify
k3d version && kubectl version --client && helm version
```

Minimum resources: **8 GB RAM**, 4 vCPU, 30 GB disk (Ollama model is ~2.5 GB).

## Quick Start

```bash
git clone https://github.com/TechTalk-With-Nathan/gitops-monitoring-ai
cd gitops-monitoring-ai

# Edit REPO_URL to point to your fork
export REPO_URL=https://github.com/TechTalk-With-Nathan/gitops-monitoring-ai

# One-shot bootstrap
./scripts/bootstrap.sh

# Or step by step
make cluster      # k3d cluster with 2 agents
make argocd       # install ArgoCD + print admin password
make deploy       # apply app-of-apps → ArgoCD reconciles everything
```

ArgoCD will now sync all applications in order (infrastructure → monitoring → demo → AI agent). Full convergence takes ~10–15 minutes on first run (Ollama model pull is the slow step).

## Accessing UIs

```bash
make port-forward-argocd    # ArgoCD   → https://localhost:8080
make port-forward-grafana   # Grafana  → http://localhost:3000  (admin/admin)
make port-forward-demo      # Demo App → http://localhost:8090
make port-forward-ollama    # Ollama   → http://localhost:11434
```

## Demo Walkthrough (Episode Script)

### 1. Normal State
- Open Grafana → explore Kubernetes dashboards (pre-loaded from kube-prometheus-stack)
- Show the demo app at `localhost:8090` : online shop with live traffic
- Open **AI SRE Agent** dashboard : shows 0 active issues

### 2. Inject a Fault (GitOps style)
```bash
# Option A: via make (direct kubectl apply)
make inject-error-rate

# Option B: GitOps way : commit the fault, ArgoCD syncs it
git add demo-app/fault-injection/high-error-rate.yaml
git commit -m "demo: inject product catalog errors"
git push
```

ArgoCD detects the change → syncs within 3 minutes → `productcatalogservice` starts returning errors.

### 3. Watch the AI Respond
Within 5 minutes:
- Prometheus fires `HighErrorRate` alert
- AlertManager webhooks the AI Analysis Receiver
- k8sgpt analyzes the `demo-app` namespace
- Result CRD is created:
  ```bash
  kubectl get results -n k8sgpt-operator-system
  kubectl describe result <name> -n k8sgpt-operator-system
  ```
- AI analysis pushed to Loki, visible in **AI SRE Agent** Grafana dashboard

### 4. Restore via GitOps
```bash
make restore-demo
# or
git revert HEAD && git push
```

### Fault Scenarios

| Scenario | Command | What k8sgpt detects |
|---|---|---|
| High error rate | `make inject-error-rate` | Pod restarts, HTTP 5xx, product catalog errors |
| Memory pressure | `make inject-memory-leak` | OOMKilled, recommendation service cache failure |
| Latency spike | `make inject-latency` | Ad service slow, P99 > SLO, trace waterfall shows bottleneck |

## Repository Structure

```
gitops-monitoring-ai/
├── argocd/
│   ├── app-of-apps.yaml          # Root ArgoCD application
│   └── applications/             # One Application per stack component
├── monitoring/
│   ├── kube-prometheus-stack/    # Prometheus + Grafana + AlertManager
│   ├── loki/                     # Log aggregation
│   ├── tempo/                    # Distributed tracing
│   └── grafana/
│       ├── dashboards/           # ConfigMaps auto-loaded by Grafana sidecar
│       └── datasources/          # All 4 datasources pre-configured
├── alloy/
│   ├── config.alloy              # Alloy pipeline (metrics + logs + traces)
│   ├── configmap.yaml            # Deployed ConfigMap (mirrors config.alloy)
│   └── values.yaml               # Alloy Helm values
├── ai-agent/
│   ├── ollama/                   # Ollama LLM server + model init Job
│   ├── k8sgpt/                   # k8sgpt operator values + K8sGPT CR
│   └── receiver/                 # Webhook receiver: k8sgpt/AlertManager → Loki
├── demo-app/
│   ├── values.yaml               # OTel Demo Helm values
│   └── fault-injection/          # GitOps-friendly fault manifests
├── infrastructure/
│   ├── namespaces.yaml
│   └── rbac/                     # k8sgpt ClusterRole
├── scripts/
│   └── bootstrap.sh              # One-shot cluster setup
└── Makefile                      # All common operations
```

## Customisation

### Use a Better Model
Edit `ai-agent/k8sgpt/k8sgpt-cr.yaml` and `ai-agent/ollama/model-init-job.yaml`:
```yaml
# Better analysis quality, needs 8GB RAM
model: mistral:7b
# or
model: llama3.1:8b
```

### Add Slack Notifications
In `ai-agent/k8sgpt/k8sgpt-cr.yaml`:
```yaml
sink:
  type: slack
  endpoint: https://hooks.slack.com/services/YOUR/SLACK/WEBHOOK
```

### Scale Up for Production
- Loki: change `deploymentMode: Distributed` in `monitoring/loki/values.yaml`
- Prometheus: add Thanos sidecar for long-term storage
- Ollama: add GPU node with `nvidia.com/gpu: 1` resource request

## How k8sgpt Works

```
Every 5 min:
  k8sgpt operator → scans cluster resources
        ↓ finds issues (CrashLoopBackOff, OOMKilled, ImagePullBackOff, etc.)
        ↓ sends resource context to Ollama (llama3.2:3b)
        ↓ LLM returns plain-English explanation + suggested fix
        ↓ Result CRD stored in k8sgpt-operator-system namespace
        ↓ webhook → AI Analysis Receiver → Loki
        ↓ Grafana "AI SRE Agent" dashboard shows analysis

On alert:
  AlertManager fires → webhook → AI Analysis Receiver
        ↓ logs alert context to Loki with labels {job="alertmanager-webhook"}
        ↓ Grafana annotation created on dashboards
```

## Troubleshooting

**Ollama model pull is slow/stuck**
```bash
kubectl logs job/ollama-model-init -n ai-agent -f
# Model is ~2.5GB : allow 5-10 min on first pull
```

**k8sgpt not creating Results**
```bash
kubectl describe k8sgpt k8sgpt -n k8sgpt-operator-system
kubectl logs deploy/k8sgpt-operator-controller-manager -n k8sgpt-operator-system
```

**Alloy not collecting logs**
```bash
kubectl logs ds/alloy -n monitoring | grep -i error
# Check it can read /var/log/pods on the node
kubectl exec -it ds/alloy -n monitoring -- /bin/alloy fmt /etc/alloy/config.alloy
```

**ArgoCD stuck syncing**
```bash
kubectl get applications -n argocd
# Force sync:
argocd app sync <app-name> --force
```
