#!/usr/bin/env bash

# Copyright 2021 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

###
# This script is to be used when updating the generated clients of 
# the Provisioning Request CRD.
###

set -o errexit
set -o nounset
set -o pipefail

GO_CMD=${1:-go}
CURRENT_DIR=$(dirname "${BASH_SOURCE[0]}")
cd "${CURRENT_DIR}/.."
API_ROOT="$(pwd -P)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
API_MODULE="$("${GO_CMD}" list -m -mod=readonly -f "{{.Path}}")"
CODEGEN_PKG="$("${GO_CMD}" list -m -mod=readonly -f "{{.Dir}}" k8s.io/code-generator)"

# shellcheck source=/dev/null
source "${CODEGEN_PKG}/kube_codegen.sh"

crds='capacitybuffer capacityquota provisioningrequest'

for crd in $crds
do
  kube::codegen::gen_client \
    --output-pkg "${API_MODULE}/$crd/client" \
    --output-dir "${API_ROOT}/$crd/client" \
    --boilerplate "${REPO_ROOT}/hack/boilerplate/boilerplate.generatego.txt" \
    --with-watch \
    --with-applyconfig \
    "${API_ROOT}/$crd"
done

# We need to clean up the go.mod file since code-generator adds temporary library to the go.mod file.
"${GO_CMD}" mod tidy
