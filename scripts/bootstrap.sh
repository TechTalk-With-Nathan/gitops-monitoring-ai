#!/usr/bin/env bash
# bootstrap.sh - full one-shot setup for gitops-monitoring-ai demo
# Requirements: k3d, kubectl, helm, git
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-gitops-monitoring-ai}"
ARGOCD_VERSION="${ARGOCD_VERSION:-v2.13.0}"
REPO_URL="${REPO_URL:-https://github.com/TechTalk-With-Nathan/gitops-monitoring-ai}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
warn() { echo "[$(date '+%H:%M:%S')] WARN: $*" >&2; }
die()  { echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; exit 1; }

check_deps() {
  log "Checking dependencies..."
  for cmd in k3d kubectl helm git; do
    command -v "$cmd" &>/dev/null || die "$cmd is required but not installed"
    log "  ✓ $cmd $(${cmd} version --short 2>/dev/null | head -1 || true)"
  done
}

create_cluster() {
  if k3d cluster list | grep -q "^$CLUSTER_NAME"; then
    warn "Cluster '$CLUSTER_NAME' already exists - skipping creation"
    return
  fi

  log "Creating k3d cluster: $CLUSTER_NAME"
  k3d cluster create "$CLUSTER_NAME" \
    --servers 1 \
    --agents 2 \
    --port "80:80@loadbalancer" \
    --port "443:443@loadbalancer" \
    --k3s-arg "--disable=traefik@server:0" \
    --wait

  kubectl wait --for=condition=Ready nodes --all --timeout=120s
  log "Cluster ready. Nodes:"
  kubectl get nodes
}

install_argocd() {
  if kubectl get namespace argocd &>/dev/null; then
    warn "ArgoCD namespace already exists - skipping install"
    return
  fi

  log "Installing ArgoCD $ARGOCD_VERSION"
  kubectl create namespace argocd
  kubectl apply -n argocd \
    -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

  log "Waiting for ArgoCD server to be ready (up to 5 min)..."
  kubectl wait --for=condition=available --timeout=300s \
    deployment/argocd-server -n argocd

  ARGOCD_PWD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d)

  log "ArgoCD installed."
  log "  URL:      https://localhost:8080 (run: make port-forward-argocd)"
  log "  Username: admin"
  log "  Password: $ARGOCD_PWD"
}

configure_argocd_repo() {
  if [[ "$REPO_URL" == *"TechTalk-With-Nathan"* ]]; then
    warn "REPO_URL is still the placeholder. Update it before deploying."
    warn "  export REPO_URL=https://github.com/TechTalk-With-Nathan/gitops-monitoring-ai"
    warn "  Then re-run: $0"
    return
  fi

  log "Registering repo $REPO_URL with ArgoCD"
  # Use ArgoCD CLI if available, otherwise apply the Application directly
  if command -v argocd &>/dev/null; then
    argocd login localhost:8080 --username admin \
      --password "$(kubectl -n argocd get secret argocd-initial-admin-secret \
        -o jsonpath="{.data.password}" | base64 -d)" \
      --insecure --grpc-web 2>/dev/null || true
    argocd repo add "$REPO_URL" --insecure-skip-server-verification 2>/dev/null || true
  fi
}

deploy_app_of_apps() {
  log "Deploying app-of-apps root Application"
  # Patch REPO_URL into app-of-apps.yaml before applying
  PATCHED=$(sed "s|https://github.com/TechTalk-With-Nathan/gitops-monitoring-ai|${REPO_URL}|g" \
    "$ROOT_DIR/argocd/app-of-apps.yaml")
  echo "$PATCHED" | kubectl apply -f -
  log "App-of-apps applied. ArgoCD will now reconcile all applications."
}

wait_for_monitoring() {
  log "Waiting for monitoring namespace to have running pods..."
  local retries=0
  until kubectl get pods -n monitoring 2>/dev/null | grep -q "Running" || [ $retries -ge 30 ]; do
    sleep 10
    retries=$(( retries + 1 ))
    log "  ... waiting ($retries/30)"
  done
  kubectl get pods -n monitoring 2>/dev/null | head -20 || true
}

print_summary() {
  GRAFANA_PWD="admin"
  log ""
  log "╔══════════════════════════════════════════════════════════════╗"
  log "║              Bootstrap Complete!                             ║"
  log "╠══════════════════════════════════════════════════════════════╣"
  log "║  ArgoCD:                                                     ║"
  log "║    make port-forward-argocd  →  https://localhost:8080       ║"
  log "║    User: admin / Pass: (see above)                           ║"
  log "║                                                              ║"
  log "║  Grafana:                                                    ║"
  log "║    make port-forward-grafana  →  http://localhost:3000       ║"
  log "║    User: admin / Pass: $GRAFANA_PWD                               ║"
  log "║                                                              ║"
  log "║  Demo App:                                                   ║"
  log "║    make port-forward-demo  →  http://localhost:8090          ║"
  log "║                                                              ║"
  log "║  Fault Injection:                                            ║"
  log "║    make inject-error-rate   (product catalog errors)         ║"
  log "║    make inject-memory-leak  (recommendation service OOM)     ║"
  log "║    make inject-latency      (ad service latency spike)       ║"
  log "║    make restore-demo        (revert all faults)              ║"
  log "║                                                              ║"
  log "║  k8sgpt Results:                                             ║"
  log "║    kubectl get results -n k8sgpt-operator-system             ║"
  log "╚══════════════════════════════════════════════════════════════╝"
}

main() {
  log "==> gitops-monitoring-ai bootstrap"
  log "    Repo: $REPO_URL"
  check_deps
  create_cluster
  install_argocd
  configure_argocd_repo
  deploy_app_of_apps
  wait_for_monitoring
  print_summary
}

main "$@"
