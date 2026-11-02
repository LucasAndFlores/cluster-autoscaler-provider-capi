ALL_ARCH = amd64 arm64 s390x
.PHONY: all help build test-unit test-ci benchmark clean generate manifests \
	fmt fmt-check format make-image push-image push-manifest dev-release \
	execute-release release-validate release build-in-docker container test-in-docker
all: $(addprefix build-arch-,$(ALL_ARCH)) ## Build binaries for all supported architectures.

GO_TEST_DEFAULT_ANALYZERS ?= all
# Local unit-test packages; cluster-dependent e2e tests are run separately.
UNIT_TEST_PACKAGES ?= . ./cloudprovider/... ./version/...
TAG ?= dev
LDFLAGS ?= -s
ENVVAR = CGO_ENABLED=0
GOOS ?= linux
GOARCH ?= $(shell go env GOARCH)
BINARY_NAME := cluster-autoscaler-provider-capi
REGISTRY ?= gcr.io/k8s-staging-autoscaling
DOCKER_NETWORK ?= default
GO_IMAGE ?= golang:1.26

# VERSION is the cluster-autoscaler-provider-capi version baked into the binary via -ldflags.
#   1. Exact git tag pointing at HEAD, with the "cluster-autoscaler-provider-capi-" prefix stripped.
#   2. The current commit SHA.
#   3. The literal string "dev" (for builds outside a git checkout).
# A "-dirty" suffix is appended when the git working tree has uncommitted
# changes (cases 1 and 2 only).
# Override with `make VERSION=<value> ...` to force a specific value; an
# externally provided VERSION is used verbatim, with no "-dirty" suffix.
ifeq ($(origin VERSION),undefined)
  VERSION := $(shell git describe --exact-match --tags 2>/dev/null | sed -e 's|^$(BINARY_NAME)-||')
  ifeq ($(strip $(VERSION)),)
    VERSION := $(shell git rev-parse HEAD 2>/dev/null)
  endif
  ifeq ($(strip $(VERSION)),)
    VERSION := dev
  else
    VERSION := $(VERSION)$(shell git diff --no-ext-diff --quiet --exit-code 2>/dev/null || echo -dirty)
  endif
endif

VERSION_PKG := k8s.io/autoscaler/cluster-autoscaler/version
VERSION_LDFLAG := -X $(VERSION_PKG).ClusterAutoscalerVersion=$(VERSION)
LDFLAGS_VALUE := $(strip $(LDFLAGS) $(VERSION_LDFLAG))

ifdef BUILD_TAGS
  TAGS_FLAG = --tags $(BUILD_TAGS)
  PROVIDER = -$(BUILD_TAGS)
else
  TAGS_FLAG =
  PROVIDER =
endif
FOR_PROVIDER = $(if $(BUILD_TAGS), for $(BUILD_TAGS))
LDFLAGS_FLAG = --ldflags="$(LDFLAGS_VALUE)"

IMAGE = $(REGISTRY)/$(BINARY_NAME)$(PROVIDER)
IMAGE_BUILD_ARGS = --pull --platform linux/$* --network="$(DOCKER_NETWORK)" \
	--build-arg "GOARCH=$*" \
	--build-arg 'LDFLAGS=$(LDFLAGS_VALUE)' \
	--build-arg 'BUILD_TAGS=$(BUILD_TAGS)' \
	-t $(IMAGE)-$*:$(TAG) -f Dockerfile .

help: ## List available Makefile targets.
	@awk 'BEGIN { FS = ":.*## "; printf "Available targets:\n" } /^[[:alnum:]_-]+:.*## / { printf "  %-20s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

build: ## Build a binary for the current architecture (override with GOARCH).
	@$(MAKE) build-arch-$(GOARCH)

build-arch-%: ## Build a binary for the architecture specified by the target suffix.
	$(ENVVAR) GOOS=$(GOOS) GOARCH=$* go build -o $(BINARY_NAME)-$* $(LDFLAGS_FLAG) $(TAGS_FLAG)

test-unit: ## Run race-enabled unit tests and checks in both Go modules.
	go test -race -vet="$(GO_TEST_DEFAULT_ANALYZERS)" $(TAGS_FLAG) $(UNIT_TEST_PACKAGES)
	go -C apis test -race -vet="$(GO_TEST_DEFAULT_ANALYZERS)" $(TAGS_FLAG) ./...

test-ci: test-unit ## Run the same unit-test checks in CI.

benchmark: ## Run benchmarks in both Go modules without running tests.
	go test -bench=. -run='^$$' -vet="$(GO_TEST_DEFAULT_ANALYZERS)" $(TAGS_FLAG) $(UNIT_TEST_PACKAGES)
	go -C apis test -bench=. -run='^$$' -vet="$(GO_TEST_DEFAULT_ANALYZERS)" $(TAGS_FLAG) ./...

dev-release: dev-release-arch-$(GOARCH) ## Build and interactively publish the current-architecture image.

dev-release-arch-%: make-image-arch-%
	$(MAKE) push-image-arch-$*
	@echo "Release ${TAG}${FOR_PROVIDER}-$* completed"

make-image: make-image-arch-$(GOARCH) ## Build and load an image for the current architecture.

make-image-arch-%:
	docker buildx build --load $(IMAGE_BUILD_ARGS)
	@echo "Image ${TAG}${FOR_PROVIDER}-$* completed"

push-image: push-image-arch-$(GOARCH) ## Interactively publish an existing current-architecture image.

push-image-arch-%:
	./push_image.sh ${IMAGE}-$*:${TAG}

# Publish single-platform manifests for docker manifest create.
push-release-image-arch-%:
	docker buildx build --push --provenance=false $(IMAGE_BUILD_ARGS)

push-manifest: ## Publish a manifest for existing architecture images.
	docker manifest create ${IMAGE}:${TAG} \
	    $(addprefix $(IMAGE)-, $(addsuffix :$(TAG), $(ALL_ARCH)))
	docker manifest push --purge ${IMAGE}:${TAG}

execute-release: $(addprefix push-release-image-arch-,$(ALL_ARCH)) ## Publish architecture images, then the multi-architecture manifest.
	$(MAKE) push-manifest
	@echo "Release ${TAG}${FOR_PROVIDER} completed"

clean: clean-arch-$(GOARCH) ## Remove the current-architecture binary (override with GOARCH).

clean-arch-%:
	rm -f $(BINARY_NAME)-$*

generate: ## Generate API deepcopy implementations.
	$(MAKE) -C apis generate

manifests: ## Generate API CRD, RBAC, and webhook manifests.
	$(MAKE) -C apis manifests

fmt: ## Format Go files in both modules.
	find . -type d \( -name .git -o -name vendor -o -name bin \) -prune -o -type f -name '*.go' -exec gofmt -s -w {} +

fmt-check: ## Check Go formatting in both modules without changing files.
	@files="$$(find . -type d \( -name .git -o -name vendor -o -name bin \) -prune -o -type f -name '*.go' -exec gofmt -s -l {} +)" || exit $$?; \
	if [ -n "$$files" ]; then \
		printf 'Go files requiring formatting:\n%s\n' "$$files" >&2; \
		exit 1; \
	fi

format: fmt ## Alias for fmt.

build-in-docker: build-in-docker-arch-$(GOARCH) ## Build a binary using the Go container image.

build-in-docker-arch-%:
	docker run --rm -v "$(CURDIR):/workspace:Z" -w /workspace "$(GO_IMAGE)" \
		make build-arch-$* GOOS="$(GOOS)" VERSION="$(VERSION)" \
		LDFLAGS="$(LDFLAGS)" BUILD_TAGS="$(BUILD_TAGS)" \
		BINARY_NAME="$(BINARY_NAME)" ENVVAR="$(ENVVAR)"

release-validate: ## Check that VERSION matches a release tag at HEAD.
	@if [ -z "$(shell git tag --points-at HEAD | grep -Fx '$(BINARY_NAME)-$(VERSION)')" ]; then \
		echo "Can't release: VERSION=$(VERSION) does not match a git tag at HEAD"; \
		exit 1; \
	fi

release: TAG = v$(VERSION)
release: release-validate ## Validate the release tag before publishing images.
	$(MAKE) execute-release TAG="$(TAG)" VERSION="$(VERSION)"
	@echo "Full in-docker release ${TAG}${FOR_PROVIDER} completed"

container: container-arch-$(GOARCH) ## Build and load an image using the multistage Dockerfile.

container-arch-%: make-image-arch-%
	@echo "Full in-docker image ${TAG}${FOR_PROVIDER}-$* completed"

test-in-docker: ## Run both-module unit tests using the Go container image.
	docker run --rm -v "$(CURDIR):/workspace:Z" -w /workspace "$(GO_IMAGE)" \
		make test-unit VERSION="$(VERSION)" \
		GO_TEST_DEFAULT_ANALYZERS="$(GO_TEST_DEFAULT_ANALYZERS)" \
		BUILD_TAGS="$(BUILD_TAGS)" UNIT_TEST_PACKAGES="$(UNIT_TEST_PACKAGES)"
