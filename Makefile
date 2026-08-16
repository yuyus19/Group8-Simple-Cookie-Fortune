# Build tasks for Simple Fortune Cookie.
#
# Run "make" on its own to see everything that is available.
#
# On Windows use Git Bash. The recipes are shell, not cmd.

SHELL := /bin/bash

REGISTRY   ?= docker.io
NAMESPACE  ?= jimdaf
IMAGE_BASE ?= cookie-fortune-group08
TAG        ?= latest

BACKEND_IMAGE  := $(REGISTRY)/$(NAMESPACE)/$(IMAGE_BASE)-backend
FRONTEND_IMAGE := $(REGISTRY)/$(NAMESPACE)/$(IMAGE_BASE)-frontend

K8S_NAMESPACE ?= fortune
SERVICES      := backend frontend

.DEFAULT_GOAL := help

# ---------------------------------------------------------------- meta ------

.PHONY: help
help: ## Show this help
	@echo "Simple Fortune Cookie build tasks"
	@echo
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Variables: TAG=$(TAG) NAMESPACE=$(NAMESPACE) K8S_NAMESPACE=$(K8S_NAMESPACE)"

# ----------------------------------------------------------------- go -------

.PHONY: build
build: ## Compile both services
	@for s in $(SERVICES); do echo "building $$s"; (cd $$s && go build ./...) || exit 1; done

.PHONY: test
test: ## Run the unit tests for both services
	@for s in $(SERVICES); do echo "testing $$s"; (cd $$s && go test ./... ) || exit 1; done

.PHONY: cover
cover: ## Run the tests and report coverage
	@for s in $(SERVICES); do \
		echo "coverage for $$s"; \
		(cd $$s && go test -coverprofile=coverage.out ./... && go tool cover -func=coverage.out | tail -1) || exit 1; \
	done

.PHONY: fmt
fmt: ## Format the Go code
	@for s in $(SERVICES); do (cd $$s && gofmt -w .); done

.PHONY: vet
vet: ## Run go vet on both services
	@for s in $(SERVICES); do echo "vetting $$s"; (cd $$s && go vet ./...) || exit 1; done

.PHONY: lint
lint: ## Run golangci-lint, the same way the pipeline does
	@command -v golangci-lint >/dev/null 2>&1 || { \
		echo "golangci-lint is not installed."; \
		echo "https://golangci-lint.run/welcome/install/"; exit 1; }
	@for s in $(SERVICES); do echo "linting $$s"; (cd $$s && golangci-lint run ./...) || exit 1; done

.PHONY: tidy
tidy: ## Tidy both go modules
	@for s in $(SERVICES); do (cd $$s && go mod tidy); done

# ------------------------------------------------------------- docker -------

.PHONY: docker-build
docker-build: ## Build both container images
	docker build -t $(BACKEND_IMAGE):$(TAG) ./backend
	docker build -t $(FRONTEND_IMAGE):$(TAG) ./frontend

.PHONY: docker-push
docker-push: ## Push both images to the registry
	docker push $(BACKEND_IMAGE):$(TAG)
	docker push $(FRONTEND_IMAGE):$(TAG)

.PHONY: scan
scan: ## Scan both images with Trivy, same as the pipeline
	@command -v trivy >/dev/null 2>&1 || { echo "trivy is not installed"; exit 1; }
	trivy image --severity HIGH,CRITICAL $(BACKEND_IMAGE):$(TAG)
	trivy image --severity HIGH,CRITICAL $(FRONTEND_IMAGE):$(TAG)

# ------------------------------------------------------------ compose -------

.PHONY: up
up: ## Start the whole stack locally with docker compose
	docker compose up -d --build --wait
	@echo "open http://localhost:8080"

.PHONY: down
down: ## Stop the stack, keeping the redis volume
	docker compose down

.PHONY: clean
clean: ## Stop the stack and delete the redis volume as well
	docker compose down -v
	@for s in $(SERVICES); do rm -f $$s/$$s $$s/$$s.exe $$s/coverage.out; done

.PHONY: logs
logs: ## Follow the compose logs
	docker compose logs -f

# ---------------------------------------------------------------- k8s -------

.PHONY: kind-up
kind-up: ## Create the local kind cluster
	kind create cluster --config k8s/kind-cluster.yaml

.PHONY: kind-down
kind-down: ## Delete the local kind cluster
	kind delete cluster --name fortune-cookie

.PHONY: deploy
deploy: ## Deploy to Kubernetes with scripts/deploy.sh
	./scripts/deploy.sh

.PHONY: smoke
smoke: ## Run the smoke tests against a running app
	./scripts/smoke-test.sh

.PHONY: stress
stress: ## Load test the running app with siege
	./scripts/stress-test.sh

.PHONY: rollback
rollback: ## Roll the deployments back to the previous version
	./scripts/rollback.sh

.PHONY: status
status: ## Show what is running in the cluster
	kubectl -n $(K8S_NAMESPACE) get deployments,pods,svc,hpa

# --------------------------------------------------------------- helm -------

.PHONY: helm-lint
helm-lint: ## Lint the Helm chart
	helm lint charts/fortune-cookie

.PHONY: helm-template
helm-template: ## Render the Helm chart without installing it
	helm template fortune-cookie charts/fortune-cookie

.PHONY: helm-install
helm-install: ## Install or upgrade the app with Helm
	helm upgrade --install fortune-cookie charts/fortune-cookie \
		--namespace $(K8S_NAMESPACE) --create-namespace --wait

.PHONY: helm-uninstall
helm-uninstall: ## Remove the Helm release
	helm uninstall fortune-cookie --namespace $(K8S_NAMESPACE)

# --------------------------------------------------------- monitoring -------

.PHONY: monitoring
monitoring: ## Deploy Prometheus and Grafana into the cluster
	kubectl apply -f k8s/monitoring/

.PHONY: grafana
grafana: ## Port forward Grafana to localhost:3000, login admin/admin
	@echo "open http://localhost:3000 and log in with admin / admin"
	kubectl -n monitoring port-forward svc/grafana 3000:3000

.PHONY: ci
ci: fmt vet lint test build ## Everything the pipeline runs, locally
	@echo "all checks passed"
