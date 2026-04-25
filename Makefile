CLUSTER_NAME   ?= gitops-monitoring-ai
ARGOCD_VERSION ?= v2.13.0
REPO_URL       ?= https://github.com/TechTalk-With-Nathan/gitops-monitoring-ai
KUBECONFIG     ?= $(HOME)/.kube/config

.PHONY: all cluster argocd bootstrap deploy port-forward-argocd port-forward-grafana port-forward-demo clean status

all: cluster argocd deploy

## ── Cluster ────────────────────────────────────────────────────────────────────

cluster:
	k3d cluster create $(CLUSTER_NAME) \
		--servers 1 \
		--agents 2 \
		--port "80:80@loadbalancer" \
		--port "443:443@loadbalancer" \
		--k3s-arg "--disable=traefik@server:0"
	kubectl wait --for=condition=Ready nodes --all --timeout=120s

## ── ArgoCD ─────────────────────────────────────────────────────────────────────

argocd:
	kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -n argocd -f \
		https://raw.githubusercontent.com/argoproj/argo-cd/$(ARGOCD_VERSION)/manifests/install.yaml
	kubectl wait --for=condition=available --timeout=300s \
		deployment/argocd-server -n argocd
	@echo ""
	@echo "==> ArgoCD admin password:"
	@kubectl -n argocd get secret argocd-initial-admin-secret \
		-o jsonpath="{.data.password}" | base64 -d
	@echo ""

## ── Deploy ─────────────────────────────────────────────────────────────────────

deploy:
	@echo "==> Applying app-of-apps root Application"
	kubectl apply -f argocd/app-of-apps.yaml
	@echo "==> Sync started - watch progress at http://localhost:8080 after port-forwarding"

## ── Port Forwards ──────────────────────────────────────────────────────────────

port-forward-argocd:
	kubectl port-forward svc/argocd-server -n argocd 8080:443

port-forward-grafana:
	kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80

port-forward-demo:
	kubectl port-forward svc/opentelemetry-demo-frontendproxy -n demo-app 8090:8080

port-forward-ollama:
	kubectl port-forward svc/ollama -n ai-agent 11434:11434

## ── Fault Injection ────────────────────────────────────────────────────────────

inject-error-rate:
	kubectl apply -f demo-app/fault-injection/high-error-rate.yaml
	@echo "==> High error rate flag activated - watch Grafana + k8sgpt"

inject-memory-leak:
	kubectl apply -f demo-app/fault-injection/memory-leak.yaml
	@echo "==> Memory leak flag activated"

inject-latency:
	kubectl apply -f demo-app/fault-injection/latency-spike.yaml
	@echo "==> Latency spike flag activated"

restore-demo:
	kubectl apply -f demo-app/fault-injection/restore.yaml
	@echo "==> Feature flags restored to normal"

## ── Utilities ──────────────────────────────────────────────────────────────────

status:
	@echo "==> ArgoCD Applications:"
	kubectl get applications -n argocd
	@echo ""
	@echo "==> k8sgpt Results:"
	kubectl get results -n k8sgpt-operator-system 2>/dev/null || echo "(none yet)"
	@echo ""
	@echo "==> Pods by Namespace:"
	kubectl get pods -A --field-selector=metadata.namespace!=kube-system | grep -v "Running\|Completed" | head -30

ollama-test:
	kubectl exec -it deploy/ollama -n ai-agent -- ollama run llama3.2:3b "Describe what a Kubernetes CrashLoopBackOff error means in 2 sentences."

bootstrap: cluster argocd deploy
	@echo ""
	@echo "==> Bootstrap complete!"
	@echo "    ArgoCD:  make port-forward-argocd  → https://localhost:8080"
	@echo "    Grafana: make port-forward-grafana  → http://localhost:3000 (admin/admin)"
	@echo "    Demo:    make port-forward-demo     → http://localhost:8090"

clean:
	k3d cluster delete $(CLUSTER_NAME)
