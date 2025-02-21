SHELL := /bin/bash

# Options for 'bundle-build'
ifneq ($(origin CHANNELS), undefined)
BUNDLE_CHANNELS := --channels=$(CHANNELS)
endif
ifneq ($(origin DEFAULT_CHANNEL), undefined)
BUNDLE_DEFAULT_CHANNEL := --default-channel=$(DEFAULT_CHANNEL)
endif
BUNDLE_METADATA_OPTS ?= $(BUNDLE_CHANNELS) $(BUNDLE_DEFAULT_CHANNEL)

# Produce CRDs that work back to Kubernetes 1.11 (no version conversion)
CRD_OPTIONS ?= "crd:trivialVersions=true"

ifndef ANTREA_PLATFORM
	ANTREA_PLATFORM=kubernetes
endif

ifndef IS_CERTIFICATION
	IS_CERTIFICATION=false
endif

include versioning.mk

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

# Options for "packagemanifests".
ifneq ($(origin FROM_VERSION), undefined)
PKG_FROM_VERSION := --from-version=$(FROM_VERSION)
endif
ifneq ($(origin CHANNEL), undefined)
PKG_CHANNELS := --channel=$(CHANNEL)
endif
ifeq ($(IS_CHANNEL_DEFAULT), 1)
PKG_IS_DEFAULT_CHANNEL := --default-channel
endif
PKG_MAN_OPTS ?= $(FROM_VERSION) $(PKG_CHANNELS) $(PKG_IS_DEFAULT_CHANNEL)

all: manager

.golangci-bin:
	@echo "===> Installing Golangci-lint <==="
	@curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s -- -b $@ v1.51.0

.PHONY: golangci
golangci: .golangci-bin
	@echo "===> Running golangci <==="
	@GOOS=linux .golangci-bin/golangci-lint run -c .golangci.yml

.PHONY: golangci-fix
golangci-fix: .golangci-bin
	@echo "===> Running golangci-fix<==="
	@GOOS=linux .golangci-bin/golangci-lint run -c .golangci.yml --fix

# Run tests
ENVTEST_ASSETS_DIR = $(shell pwd)/testbin
test: generate golangci manifests
	mkdir -p $(ENVTEST_ASSETS_DIR)
	test -f $(ENVTEST_ASSETS_DIR)/setup-envtest.sh || curl -sSLo $(ENVTEST_ASSETS_DIR)/setup-envtest.sh https://raw.githubusercontent.com/kubernetes-sigs/controller-runtime/v0.6.3/hack/setup-envtest.sh
	source $(ENVTEST_ASSETS_DIR)/setup-envtest.sh; fetch_envtest_tools $(ENVTEST_ASSETS_DIR); setup_envtest_env $(ENVTEST_ASSETS_DIR); go test ./... -coverprofile cover.out

# Build manager binary
manager: generate golangci
	@echo "===> Building antrea-operator binary <==="
	go build -o bin/manager main.go

# Run against the configured Kubernetes cluster in ~/.kube/config
run: generate golangci manifests
	go run ./main.go

# Install CRDs into a cluster
install: manifests kustomize
	$(KUSTOMIZE) build config/crd | kubectl apply -f -

# Uninstall CRDs from a cluster
uninstall: manifests kustomize
	$(KUSTOMIZE) build config/crd | kubectl delete -f -

# Deploy controller in the configured Kubernetes cluster in ~/.kube/config
deploy: manifests kustomize
	cd config/manager && $(KUSTOMIZE) edit set image controller=${IMG}
	$(KUSTOMIZE) build config/default | kubectl apply -f -

# Generate manifests e.g. CRD, RBAC etc.
manifests: controller-gen kustomize antrea-resources
	$(CONTROLLER_GEN) $(CRD_OPTIONS) rbac:roleName=antrea-operator webhook paths="./..." output:crd:artifacts:config=config/crd/bases
	$(KUSTOMIZE) build config/crd > config/crd/operator.antrea.vmware.com_antreainstalls.yaml

# Generate code
generate: controller-gen
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./..."

# Build the docker image
docker-build:
	docker build -f build/Dockerfile . -t ${IMG}
	docker tag ${IMG} antrea/antrea-operator

# find or download controller-gen
# download controller-gen if necessary
controller-gen:
ifeq (, $(shell which controller-gen))
	@{ \
	set -e ;\
	go install sigs.k8s.io/controller-tools/cmd/controller-gen@v0.6.2 ;\
	}
CONTROLLER_GEN=$(GOBIN)/controller-gen
else
CONTROLLER_GEN=$(shell which controller-gen)
endif

kustomize:
ifeq (, $(shell which kustomize))
	@{ \
	set -e ;\
	KUSTOMIZE_GEN_TMP_DIR=$$(mktemp -d) ;\
	cd $$KUSTOMIZE_GEN_TMP_DIR ;\
	go mod init tmp ;\
	go get sigs.k8s.io/kustomize/kustomize/v3@v3.5.4 ;\
	rm -rf $$KUSTOMIZE_GEN_TMP_DIR ;\
	}
KUSTOMIZE=$(GOBIN)/kustomize
else
KUSTOMIZE=$(shell which kustomize)
endif

# Generate bundle manifests and metadata, then validate generated files.
.PHONY: bundle
bundle: manifests kustomize
	operator-sdk generate kustomize manifests -q
	# OCP requires that an image will be identified by its digest hash
	if [ "$(IS_CERTIFICATION)" == "true" ]; then \
	        $(KUSTOMIZE) build config/manifests | operator-sdk generate bundle -q --use-image-digests --overwrite $(BUNDLE_METADATA_OPTS) --version $(VERSION) ; \
	else \
		cd config/manager && $(KUSTOMIZE) edit set image antrea/antrea-operator:v$(VERSION) ;\
	        $(KUSTOMIZE) build config/manifests | operator-sdk generate bundle -q --overwrite $(BUNDLE_METADATA_OPTS) --version $(VERSION) ; \
	fi
	operator-sdk bundle validate ./bundle
	cp config/samples/operator_v1_antreainstall.yaml ./deploy/$(ANTREA_PLATFORM)/operator.antrea.vmware.com_v1_antreainstall_cr.yaml
	cp config/crd/operator.antrea.vmware.com_antreainstalls.yaml deploy/$(ANTREA_PLATFORM)/operator.antrea.vmware.com_antreainstalls_crd.yaml

.PHONY: ocpbundle
ocpbundle: ANTREA_PLATFORM=openshift
ocpbundle: bundle
	./hack/edit_bundle_metadata_ocp.sh

ocpcertification: IS_CERTIFICATION=true
ocpcertification: ocpbundle

# Build the bundle image.
.PHONY: bundle-build
bundle-build:
	docker build -f bundle.Dockerfile -t $(BUNDLE_IMG) .
	docker tag ${BUNDLE_IMG} antrea/antrea-operator-bundle

antrea-resources:
	./hack/generate-antrea-resources.sh --platform $(ANTREA_PLATFORM) --version $(VERSION)
	cp ./config/rbac/role.yaml ./deploy/$(ANTREA_PLATFORM)/role.yaml
	cp ./config/samples/operator_v1_antreainstall.yaml ./deploy/$(ANTREA_PLATFORM)/operator.antrea.vmware.com_v1_antreainstall_cr.yaml

# Generate package manifests.
packagemanifests: kustomize manifests
	operator-sdk generate kustomize manifests -q
	cd config/manager && $(KUSTOMIZE) edit set image antrea-operator=$(IMG)
	$(KUSTOMIZE) build config/manifests | operator-sdk generate packagemanifests -q --version $(VERSION) $(PKG_MAN_OPTS)

test-tidy:
	@echo
	@echo "===> Checking go.mod tidiness <==="
	./hack/tidy-check.sh

.PHONY: tidy
tidy:
	rm -f go.sum
	go mod tidy

.PHONY: bin
bin: manager
