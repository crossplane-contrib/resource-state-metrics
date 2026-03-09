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
UPSTREAM_COMMIT  ?= 5c929a5
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

.PHONY: info
info:
	@echo "Upstream repo:   $(UPSTREAM_REPO)"
	@echo "Upstream commit: $(UPSTREAM_COMMIT)"
	@echo "Image:           $(IMAGE)"
