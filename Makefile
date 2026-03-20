# Makefile for building the resource-state-metrics server image
# from a specific upstream commit.
#
# Usage:
#   make build         # Clone upstream, build Docker image
#   make push          # Push image to GHCR
#   make all           # Build and push
#   make clean         # Remove cloned upstream source
#
# Override defaults:
#   make build UPSTREAM_COMMIT=abc1234
#   make build IMAGE_REPO=ghcr.io/my-org/resource-state-metrics

UPSTREAM_REPO    ?= https://github.com/kubernetes-sigs/resource-state-metrics.git
UPSTREAM_COMMIT  ?= 5383f7d
UPSTREAM_DIR     ?= .upstream/resource-state-metrics

IMAGE_REPO       ?= ghcr.io/crossplane-contrib/resource-state-metrics-server
IMAGE_TAG        ?= $(UPSTREAM_COMMIT)
IMAGE            ?= $(IMAGE_REPO):$(IMAGE_TAG)

PLATFORM         ?= linux/amd64,linux/arm64

.PHONY: all
all: build push

.PHONY: clone
clone:
	@if [ ! -d "$(UPSTREAM_DIR)/.git" ]; then \
		echo "Cloning upstream resource-state-metrics..."; \
		mkdir -p $(dir $(UPSTREAM_DIR)); \
		git clone $(UPSTREAM_REPO) $(UPSTREAM_DIR); \
	fi
	@cd $(UPSTREAM_DIR) && \
		git fetch origin && \
		git checkout $(UPSTREAM_COMMIT)
	@echo "Checked out commit $(UPSTREAM_COMMIT)"

.PHONY: build
build: clone
	@echo "Building $(IMAGE)..."
	docker build \
		-t $(IMAGE) \
		$(UPSTREAM_DIR)
	@echo "Built $(IMAGE)"

.PHONY: build-multiarch
build-multiarch: clone
	@echo "Building multi-arch $(IMAGE)..."
	docker buildx build \
		--platform $(PLATFORM) \
		-t $(IMAGE) \
		$(UPSTREAM_DIR)
	@echo "Built $(IMAGE) for $(PLATFORM)"

.PHONY: push
push:
	@echo "Pushing $(IMAGE)..."
	docker push $(IMAGE)
	@echo "Pushed $(IMAGE)"

.PHONY: push-multiarch
push-multiarch: clone
	@echo "Building and pushing multi-arch $(IMAGE)..."
	docker buildx build \
		--platform $(PLATFORM) \
		--push \
		-t $(IMAGE) \
		$(UPSTREAM_DIR)
	@echo "Pushed $(IMAGE) for $(PLATFORM)"

.PHONY: clean
clean:
	rm -rf .upstream

# PromQL Testing
METRICS_FIXTURE  ?= promql-tests/fixtures/metrics.prom
PROMTOOL         ?= promtool

.PHONY: promql-test
promql-test: ## Run all promtool PromQL tests
	@echo "Running PromQL tests..."
	@find promql-tests -name '*_test.yaml' -exec $(PROMTOOL) test rules {} +
	@echo "All PromQL tests passed."

.PHONY: generate-input-series
generate-input-series: ## Generate promtool input_series YAML from scraped metrics fixture
	@if [ ! -f "$(METRICS_FIXTURE)" ]; then \
		echo "Error: Metrics fixture not found: $(METRICS_FIXTURE)"; \
		echo "Scrape metrics from RSM and save to $(METRICS_FIXTURE)"; \
		exit 1; \
	fi
	@echo "    input_series:"
	@while IFS= read -r line; do \
		case "$$line" in \
			""|\#*) continue ;; \
		esac; \
		series=$$(echo "$$line" | sed 's/[[:space:]][[:space:]]*[0-9eE.+-]*$$//'); \
		value=$$(echo "$$line" | sed 's/.*[[:space:]][[:space:]]*//'); \
		value=$$(echo "$$value" | sed 's/\.0\{1,\}$$//'); \
		echo "      - series: '$$series'"; \
		echo "        values: \"$$value\""; \
	done < "$(METRICS_FIXTURE)"

.PHONY: info
info:
	@echo "Upstream repo:   $(UPSTREAM_REPO)"
	@echo "Upstream commit: $(UPSTREAM_COMMIT)"
	@echo "Image:           $(IMAGE)"

# Local Development Environment
MONITORING_NS    ?= monitoring
RSM_NAMESPACE    ?= resource-state-metrics

.PHONY: local
local:
	up project run --local
	kubectl apply -f examples/rbac-crossplane.yaml
	kubectl apply -f examples/xr-rsm.yaml
	kubectl apply -f examples/configuration-eks.yaml
	kubectl wait configuration.pkg --all --for=condition=Healthy --timeout 5m
	kubectl wait configuration.pkg --all --for=condition=Installed --timeout 5m
	kubectl wait configurationrevisions.pkg --all --for=condition=RevisionHealthy --timeout 10m
	kubectl wait provider.pkg --all --for=condition=Healthy --timeout 5m
	kubectl wait provider.pkg --all --for=condition=Installed --timeout 5m
	kubectl wait providerrevisions.pkg --all --for=condition=RevisionHealthy --timeout 5m
	kubectl wait function.pkg --all --for=condition=Healthy --timeout 5m
	kubectl wait function.pkg --all --for=condition=Installed --timeout 5m
	kubectl wait functionrevisions.pkg --all --for=condition=RevisionHealthy --timeout 5m
	kubectl create namespace team-a --dry-run=client -o yaml | kubectl apply -f -
	kubectl create namespace team-b --dry-run=client -o yaml | kubectl apply -f -
	@if [ -n "$${AWS_CLOUD_CREDENTIALS}" ]; then \
		echo "Creating cloud credential secret..."; \
		kubectl -n team-a create secret generic provider-creds \
			--from-literal=creds="$${AWS_CLOUD_CREDENTIALS}" \
			--dry-run=client -o yaml | kubectl apply -f -; \
		kubectl -n team-b create secret generic provider-creds \
			--from-literal=creds="$${AWS_CLOUD_CREDENTIALS}" \
			--dry-run=client -o yaml | kubectl apply -f -; \
		echo "Creating default ProviderConfig..."; \
		kubectl apply -f examples/provider-config.yaml; \
	else \
		echo "Skipping cloud credentials and ProviderConfigs (AWS_CLOUD_CREDENTIALS not set)"; \
	fi
	@for i in $$(seq 1 60); do \
		kubectl get namespace $(RSM_NAMESPACE) >/dev/null 2>&1 && break; \
		sleep 5; \
	done
	kubectl wait --for=condition=available deployment/resource-state-metrics \
		-n $(RSM_NAMESPACE) --timeout=300s
	kubectl apply -R -f examples/metrics/
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
	helm repo update prometheus-community
	helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
		--namespace $(MONITORING_NS) --create-namespace \
		--set prometheus.prometheusSpec.additionalScrapeConfigs[0].job_name=resource-state-metrics \
		--set prometheus.prometheusSpec.additionalScrapeConfigs[0].scrape_interval=15s \
		--set "prometheus.prometheusSpec.additionalScrapeConfigs[0].scrape_protocols[0]=PrometheusText0.0.4" \
		--set "prometheus.prometheusSpec.additionalScrapeConfigs[0].static_configs[0].targets[0]=resource-state-metrics.$(RSM_NAMESPACE).svc.cluster.local:9999" \
		--set prometheus.prometheusSpec.additionalScrapeConfigs[1].job_name=resource-state-metrics-telemetry \
		--set prometheus.prometheusSpec.additionalScrapeConfigs[1].scrape_interval=15s \
		--set "prometheus.prometheusSpec.additionalScrapeConfigs[1].scrape_protocols[0]=PrometheusText0.0.4" \
		--set "prometheus.prometheusSpec.additionalScrapeConfigs[1].static_configs[0].targets[0]=resource-state-metrics.$(RSM_NAMESPACE).svc.cluster.local:9998" \
		--set grafana.sidecar.dashboards.enabled=true \
		--set grafana.sidecar.dashboards.searchNamespace=$(MONITORING_NS) \
		--wait --timeout 5m
	@sed 's/$${DS_PROMETHEUS}/prometheus/g' examples/grafana/resource-state-metrics-dashboard.json | \
		kubectl create configmap rsm-grafana-dashboard \
			--namespace $(MONITORING_NS) \
			--from-file=resource-state-metrics-dashboard.json=/dev/stdin \
			--dry-run=client -o yaml | \
		kubectl label --local -f - grafana_dashboard=1 -o yaml | \
		kubectl apply -f -
	@echo ""
	@echo "============================================================"
	@echo " Local environment ready!"
	@echo "============================================================"
	@echo " Grafana:     kubectl port-forward -n $(MONITORING_NS) svc/kube-prometheus-stack-grafana 3000:80"
	@echo "              http://localhost:3000  (user: admin)"
	@echo "              kubectl get secret --namespace $(MONITORING_NS) -l app.kubernetes.io/component=admin-secret -o jsonpath=\"{.items[0].data.admin-password}\" | base64 --decode ; echo"
	@echo ""
	@echo " Prometheus:  kubectl port-forward -n $(MONITORING_NS) svc/kube-prometheus-stack-prometheus 9090:9090"
	@echo "              http://localhost:9090"
	@echo ""
	@echo " RSM Metrics: kubectl port-forward -n $(RSM_NAMESPACE) svc/resource-state-metrics 9999:9999"
	@echo "              http://localhost:9999/metrics"
	@echo ""

.PHONY: local-clean
local-clean:
	@echo "Deleting XRs with foreground cascading deletion (to avoid cloud resource leaks)..."
	kubectl delete -f examples/metrics/eks/xrs.yaml --cascade=foreground --wait --timeout=30m --ignore-not-found
	@echo "XRs deleted. Stopping local environment..."
	up project stop --force
