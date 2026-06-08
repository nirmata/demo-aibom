#!/usr/bin/env bash
# demo/setup-demo-cluster.sh
# ─────────────────────────────────────────────────────────────────────────────
# Sets up a self-contained local environment for the AIBOM demo.
#
# Run from the kyverno-aibom-reference repo root:
#   bash demo/setup-demo-cluster.sh
#
# What gets created:
#   kind cluster        aibom-demo
#   Local OCI registry  localhost:5001  (container: aibom-demo-registry)
#   Kyverno 1.13+       installed via Helm with insecure-registry support
#   cosign keypair      demo/keys/cosign.key + cosign.pub
#   Approved image      localhost:5001/agents/research-agent:<sha>  (built + attested)
#   Kyverno policies    require-aibom-attestation-local + enforce-aibom-constraints-local
#   Demo manifests      demo/manifests/pod-approved-local.yaml  (digest pre-filled)
#
# Prerequisites (must be on PATH):
#   kind, docker, kubectl, helm, cosign
#
# Optional:
#   nctl  — for live AIBOM generation; if absent the committed baseline is attested
#           Install: https://nirmata.com/contact  (private preview)
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
CLUSTER_NAME="aibom-demo"
REGISTRY_NAME="aibom-demo-registry"
REGISTRY_PORT="5001"                     # host-side port for the local registry
REGISTRY_HOST="localhost:${REGISTRY_PORT}"
IMAGE_NAME="${REGISTRY_HOST}/agents/research-agent"
IMAGE_TAG="demo"
KYVERNO_NAMESPACE="kyverno"
KEYS_DIR="demo/keys"
LOCAL_POLICIES_DIR="demo/policies-local"
AIBOM_FILE="demo/aibom-demo.json"

# ── Colours ───────────────────────────────────────────────────────────────────
BOLD='\033[1m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'
RED='\033[0;31m'; YELLOW='\033[1;33m'; DIM='\033[2m'; RESET='\033[0m'

banner() { echo -e "\n${CYAN}${BOLD}━━  $1  ━━${RESET}\n"; }
ok()     { echo -e "${GREEN}${BOLD}✔${RESET}  $1"; }
info()   { echo -e "   $1"; }
warn()   { echo -e "${YELLOW}⚠  $1${RESET}"; }
step()   { echo -e "${DIM}  →${RESET} $1"; }
die()    { echo -e "${RED}${BOLD}✘  ERROR:${RESET} $1" >&2; exit 1; }

# ── Prerequisite check ────────────────────────────────────────────────────────
banner "Checking prerequisites"

MISSING=()
for cmd in kind docker kubectl helm cosign; do
  if command -v "$cmd" &>/dev/null; then
    ok "$cmd  $(${cmd} version --short 2>/dev/null || ${cmd} version 2>/dev/null | head -1 || true)"
  else
    MISSING+=("$cmd")
    echo -e "${RED}✘  $cmd — NOT FOUND${RESET}"
  fi
done

if command -v nctl &>/dev/null; then
  # Verify this nctl build actually supports aibom scanning (requires CGO + include_aibom_scanner)
  if nctl agent aibom generate --help &>/dev/null; then
    ok "nctl  (live AIBOM generation enabled)"
    HAVE_NCTL=true
  else
    warn "nctl found but this build does not support aibom scanning."
    warn "  The aibom subcommand requires a Linux distribution build of nctl or one"
    warn "  compiled with: CGO_ENABLED=1 go build -tags include_aibom_scanner"
    warn "  Falling back to committed aibom-baseline.json as the attestation predicate."
    HAVE_NCTL=false
  fi
else
  warn "nctl not found — will attest the committed aibom-baseline.json instead"
  warn "Install nctl from https://nirmata.com/contact for full source-scan demo"
  HAVE_NCTL=false
fi

[[ ${#MISSING[@]} -gt 0 ]] && \
  die "Missing required tools: ${MISSING[*]}\nInstall them and re-run."

# Must be run from repo root
[[ -f "src/research-agent.ts" && -f "Dockerfile" && -d "policies" ]] || \
  die "Run this script from the kyverno-aibom-reference repo root.\n  cd /path/to/kyverno-aibom-reference && bash demo/setup-demo-cluster.sh"

# ── Tear down any previous demo cluster ───────────────────────────────────────
banner "Cleaning up previous demo environment (if any)"

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  step "Deleting existing kind cluster '${CLUSTER_NAME}'..."
  kind delete cluster --name "${CLUSTER_NAME}"
  ok "Old cluster removed"
else
  ok "No previous cluster found"
fi

if docker inspect "${REGISTRY_NAME}" &>/dev/null; then
  step "Removing existing registry container '${REGISTRY_NAME}'..."
  docker rm -f "${REGISTRY_NAME}" >/dev/null
  ok "Old registry removed"
fi

# ── Local OCI registry ────────────────────────────────────────────────────────
banner "Starting local OCI registry on port ${REGISTRY_PORT}"

docker run -d \
  --restart=always \
  --name "${REGISTRY_NAME}" \
  -p "127.0.0.1:${REGISTRY_PORT}:5000" \
  registry:2 >/dev/null

ok "Registry running at ${REGISTRY_HOST}"

# ── kind cluster ──────────────────────────────────────────────────────────────
banner "Creating kind cluster '${CLUSTER_NAME}'"

cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    # Expose the API server on a fixed port so kubectl works predictably
    extraPortMappings: []
containerdConfigPatches:
  # Let cluster nodes pull from the local registry over the docker network
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry]
      [plugins."io.containerd.grpc.v1.cri".registry.mirrors]
        [plugins."io.containerd.grpc.v1.cri".registry.mirrors."${REGISTRY_HOST}"]
          endpoint = ["http://${REGISTRY_NAME}:5000"]
EOF

ok "Cluster '${CLUSTER_NAME}' created"

# Connect the registry container to the kind docker network
step "Connecting registry to kind network..."
docker network connect "kind" "${REGISTRY_NAME}" 2>/dev/null || true

# Standard kind local-registry-hosting ConfigMap (used by tooling to discover the registry)
kubectl apply -f - <<EOF >/dev/null
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "${REGISTRY_HOST}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

ok "Registry integrated with cluster"

# ── Kyverno ───────────────────────────────────────────────────────────────────
banner "Installing Kyverno"

step "Adding Kyverno Helm repo..."
helm repo add kyverno https://kyverno.github.io/kyverno/ --force-update >/dev/null
helm repo update >/dev/null

step "Installing Kyverno chart (this takes ~2 min)..."
helm install kyverno kyverno/kyverno \
  -n "${KYVERNO_NAMESPACE}" --create-namespace \
  --wait --timeout 8m \
  --set admissionController.replicas=1 \
  --set backgroundController.replicas=1 \
  --set cleanupController.replicas=1 \
  --set reportsController.replicas=1 \
  --set "admissionController.extraArgs[0]=--allowInsecureRegistry" \
  >/dev/null

ok "Kyverno installed"
kubectl get pods -n "${KYVERNO_NAMESPACE}" --no-headers | awk '{print "  " $1 "  " $3}'

# Detect installed Kyverno app version for CRD URL construction
KYVERNO_APP_VERSION=$(helm list -n "${KYVERNO_NAMESPACE}" -o json \
  | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['app_version'])" 2>/dev/null || true)
step "Kyverno app version: ${KYVERNO_APP_VERSION:-unknown}"

# ImageValidatingPolicy lives in the policies.kyverno.io API group which is not
# always registered by the Helm chart depending on the version. Apply the CRD
# directly from the matching upstream tag so it is always present.
step "Ensuring ImageValidatingPolicy CRD is registered..."
if kubectl api-resources --api-group=policies.kyverno.io 2>/dev/null | grep -qi "imagevalidating"; then
  ok "ImageValidatingPolicy CRD already present"
else
  # The Kyverno Helm chart (3.x) does not bundle CRDs in the chart's crds/ directory
  # (helm show crds returns empty). Apply the CRD directly from the matching GitHub tag.
  # CRDs live under config/crds/<group>/ in the Kyverno repo.
  CRD_BASE="https://raw.githubusercontent.com/kyverno/kyverno"
  CRD_PATH="config/crds/policies.kyverno.io/policies.kyverno.io_imagevalidatingpolicies.yaml"
  CRD_URL_TAG="${CRD_BASE}/${KYVERNO_APP_VERSION}/${CRD_PATH}"
  CRD_URL_MAIN="${CRD_BASE}/main/${CRD_PATH}"

  step "Applying ImageValidatingPolicy CRD from GitHub (tag: ${KYVERNO_APP_VERSION})..."
  CRD_APPLIED=false
  if kubectl apply -f "${CRD_URL_TAG}" 2>&1; then
    CRD_APPLIED=true
  elif kubectl apply -f "${CRD_URL_MAIN}" 2>&1; then
    CRD_APPLIED=true
  fi

  if [[ "${CRD_APPLIED}" == "true" ]]; then
    sleep 5
    if kubectl api-resources --api-group=policies.kyverno.io 2>/dev/null | grep -qi "imagevalidating"; then
      ok "ImageValidatingPolicy CRD registered"
    else
      warn "CRD applied but not yet visible — waiting 10 more seconds..."
      sleep 10
      kubectl api-resources --api-group=policies.kyverno.io 2>/dev/null | grep -qi "imagevalidating" && \
        ok "ImageValidatingPolicy CRD registered" || \
        warn "CRD still not visible — Acts 6-8 may need a manual retry after 30s"
    fi
  else
    warn "Could not register ImageValidatingPolicy CRD automatically."
    warn "Run manually:"
    warn "  kubectl apply -f ${CRD_URL_TAG}"
    warn "Acts 6-8 (Kyverno admission) will not work until the CRD is present."
  fi
fi

# ── cosign keypair ────────────────────────────────────────────────────────────
banner "Generating cosign keypair for local demo signing"

mkdir -p "${KEYS_DIR}"

if [[ -f "${KEYS_DIR}/cosign.key" ]]; then
  warn "Existing cosign keypair found in ${KEYS_DIR}/ — reusing."
  warn "Delete ${KEYS_DIR}/cosign.key to regenerate."
else
  # cosign generate-key-pair writes cosign.key + cosign.pub into the current directory.
  # We cd into KEYS_DIR so the files land there directly — the --output-key-file flag
  # does not exist in cosign 2.x.
  (cd "${KEYS_DIR}" && COSIGN_PASSWORD="" cosign generate-key-pair)
  ok "Keypair generated"
fi

ok "Private key: ${KEYS_DIR}/cosign.key"
ok "Public key:  ${KEYS_DIR}/cosign.pub"

# ── Build and push the "approved" agent image ─────────────────────────────────
banner "Building research-agent image"

step "Building ${IMAGE_NAME}:${IMAGE_TAG}..."
docker build -t "${IMAGE_NAME}:${IMAGE_TAG}" . >/dev/null

step "Pushing to local registry..."
docker push "${IMAGE_NAME}:${IMAGE_TAG}" >/dev/null

# Capture the digest — we need it to attest and to write the demo pod manifest
IMAGE_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "${IMAGE_NAME}:${IMAGE_TAG}" | cut -d@ -f2)
IMAGE_REF="${IMAGE_NAME}@${IMAGE_DIGEST}"

ok "Image pushed: ${IMAGE_NAME}:${IMAGE_TAG}"
ok "Digest: ${IMAGE_DIGEST}"

# ── Generate AIBOM ────────────────────────────────────────────────────────────
banner "Generating AIBOM"

if [[ "${HAVE_NCTL}" == "true" ]]; then
  step "Running nctl agent aibom generate ..."
  nctl agent aibom generate . --output json --file "${AIBOM_FILE}"
  ok "AIBOM generated: ${AIBOM_FILE}"
else
  step "nctl not available — using committed baseline as AIBOM predicate"
  cp aibom-baseline.json "${AIBOM_FILE}"
  ok "Using aibom-baseline.json as predicate: ${AIBOM_FILE}"
fi

# ── Attest AIBOM to image digest ─────────────────────────────────────────────
banner "Attesting AIBOM to image with cosign"

step "Attesting ${IMAGE_REF} ..."

COSIGN_ALLOW_HTTP_REGISTRY=true \
COSIGN_PASSWORD="" \
  cosign attest \
    --key "${KEYS_DIR}/cosign.key" \
    --predicate "${AIBOM_FILE}" \
    --type "https://nirmata.com/aibom/v1" \
    "${IMAGE_REF}"

ok "Attestation attached to ${IMAGE_NAME}@${IMAGE_DIGEST}"

# Verify it round-trips correctly
step "Verifying attestation is readable..."
COSIGN_ALLOW_HTTP_REGISTRY=true \
  cosign verify-attestation \
    --key "${KEYS_DIR}/cosign.pub" \
    --type "https://nirmata.com/aibom/v1" \
    --insecure-ignore-tlog \
    "${IMAGE_REF}" >/dev/null 2>&1 && ok "Attestation verified" || \
    warn "Attestation verify returned non-zero — may still work via Kyverno"

# ── Generate local Kyverno policies ──────────────────────────────────────────
banner "Generating local Kyverno policies"

mkdir -p "${LOCAL_POLICIES_DIR}"

# Read the public key and indent it for embedding in YAML (12 spaces)
PUB_KEY_INDENTED=$(awk '{print "            " $0}' "${KEYS_DIR}/cosign.pub")

# ── Policy 1: require AIBOM attestation ──────────────────────────────────────
# Verifies the image has a valid AIBOM attestation signed by the local demo key.
# We use verifyAttestationSignatures (not verifyImageSignatures) because the
# setup only runs cosign attest, not cosign sign.
cat > "${LOCAL_POLICIES_DIR}/require-aibom-attestation-local.yaml" <<POLICY
apiVersion: policies.kyverno.io/v1
kind: ImageValidatingPolicy
metadata:
  name: require-aibom-attestation-local
  annotations:
    policies.kyverno.io/title: Require AIBOM Attestation (Local Demo)
    policies.kyverno.io/description: >-
      Requires every agent Pod image to have a valid Nirmata AIBOM attestation
      signed by the local demo cosign key. Images without a valid attestation
      are blocked at admission.
spec:
  validationActions: [Deny]
  webhookConfiguration:
    timeoutSeconds: 15
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["pods"]
  matchImageReferences:
    - glob: "${REGISTRY_HOST}/agents/*"
  attestors:
    - name: localKey
      cosign:
        key:
          data: |
${PUB_KEY_INDENTED}
  attestations:
    - name: aibom
      intoto:
        type: https://nirmata.com/aibom/v1
  validations:
    - expression: >-
        images.containers.map(image,
          verifyAttestationSignatures(image, attestations.aibom, [attestors.localKey])
        ).all(e, e > 0)
      message: "Image must have a valid AIBOM attestation (https://nirmata.com/aibom/v1)."
POLICY

# ── Policy 2: enforce AIBOM constraints ──────────────────────────────────────
# Verifies the AIBOM attestation was signed by the approved pipeline key.
# In production this policy would also inspect the attestation payload to
# enforce approved frameworks, tools, and models — that level of inspection
# uses ClusterPolicy with JMESPath. For this local demo, the CI gate (Acts 4-5)
# demonstrates per-component enforcement; here we enforce the attestation contract.
cat > "${LOCAL_POLICIES_DIR}/enforce-aibom-constraints-local.yaml" <<POLICY
apiVersion: policies.kyverno.io/v1
kind: ImageValidatingPolicy
metadata:
  name: enforce-aibom-constraints-local
  annotations:
    policies.kyverno.io/title: Enforce AIBOM Constraints (Local Demo)
    policies.kyverno.io/description: >-
      Verifies the AIBOM attestation was signed by the authorised CI pipeline key.
      Ensures no image reaches the cluster without a traceable AIBOM signed by
      the same key that the CI pipeline uses.
spec:
  validationActions: [Deny]
  webhookConfiguration:
    timeoutSeconds: 15
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["pods"]
  matchImageReferences:
    - glob: "${REGISTRY_HOST}/agents/*"
  attestors:
    - name: localKey
      cosign:
        key:
          data: |
${PUB_KEY_INDENTED}
  attestations:
    - name: aibom
      intoto:
        type: https://nirmata.com/aibom/v1
  validations:
    - expression: >-
        images.containers.map(image,
          verifyAttestationSignatures(image, attestations.aibom, [attestors.localKey])
        ).all(e, e > 0)
      message: >-
        AIBOM attestation missing or not signed by the approved pipeline key.
        Ensure the image was built and attested via the Nirmata CI pipeline.
POLICY

ok "Local policies written to ${LOCAL_POLICIES_DIR}/ (for reference — not applied to cluster)"
# Note: ImageValidatingPolicies are NOT applied here. They require the local registry
# to be reachable from inside the cluster for cosign attestation verification, which
# doesn't work with localhost:5001 from within kind pods. Pillar 1 attestation
# enforcement is demonstrated in GitHub Actions where the registry is accessible.

# ── Generate demo pod manifests with real image digest ────────────────────────
banner "Writing demo pod manifests"

mkdir -p demo/manifests

cat > demo/manifests/pod-approved-local.yaml <<MANIFEST
# Approved agent pod — properly attested image, passes all Kyverno policies.
# Generated by setup-demo-cluster.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
apiVersion: v1
kind: Pod
metadata:
  name: research-agent-approved
  namespace: default
  labels:
    app: research-agent
    aibom-attested: "true"
spec:
  containers:
    - name: agent
      image: ${IMAGE_REF}
      command: ["node", "dist/research-agent.js"]
      env:
        - name: ANTHROPIC_API_KEY
          value: "demo-placeholder-key"
      resources:
        requests: { cpu: "100m", memory: "128Mi" }
        limits:   { cpu: "500m", memory: "512Mi" }
  restartPolicy: Never
MANIFEST

cat > demo/manifests/pod-no-attestation-local.yaml <<MANIFEST
# Unattested pod — expected to be BLOCKED by require-aibom-attestation-local.
# Expected error: "Image must have a valid AIBOM attestation"
apiVersion: v1
kind: Pod
metadata:
  name: research-agent-no-attest
  namespace: default
spec:
  containers:
    - name: agent
      image: nginx:latest
      resources:
        requests: { cpu: "100m", memory: "128Mi" }
        limits:   { cpu: "500m", memory: "512Mi" }
  restartPolicy: Never
MANIFEST

ok "pod-approved-local.yaml  (digest: ${IMAGE_DIGEST:0:19}...)"
ok "pod-no-attestation-local.yaml"

# ── Pre-pull nginx into kind so the demo doesn't wait ─────────────────────────
banner "Pre-pulling demo images into cluster nodes"

step "Pulling curlimages/curl:latest into kind node (used for Pillar 3 demo)..."
docker pull curlimages/curl:latest >/dev/null 2>&1 && \
  kind load docker-image curlimages/curl:latest --name "${CLUSTER_NAME}" >/dev/null 2>/dev/null && \
  ok "curlimages/curl:latest loaded" || warn "curl image pre-load skipped — will pull at demo time"

step "Loading research-agent into kind node..."
kind load docker-image "${IMAGE_NAME}:${IMAGE_TAG}" --name "${CLUSTER_NAME}" >/dev/null && \
  ok "research-agent image loaded" || warn "Image load skipped — pods will pull from local registry"

# ── Smoke test ────────────────────────────────────────────────────────────────
banner "Smoke test — Pillar 3 NetworkPolicy enforcement"

# Apply the Pillar 3 eBPF policies before testing
step "Applying Pillar 3 eBPF policies..."
kubectl apply -f demo/ebpf-policies/agent-egress.yaml

# Verify NetworkPolicy and ClusterPolicy are present
step "Verifying NetworkPolicy is active..."
if kubectl get networkpolicy ai-agent-default-deny &>/dev/null; then
  ok "NetworkPolicy ai-agent-default-deny is active"
else
  warn "NetworkPolicy not found — Pillar 3 demo will not work as expected"
fi

step "Verifying ClusterPolicy (auto-labeller) is active..."
if kubectl get clusterpolicy label-ai-agent-pods &>/dev/null; then
  ok "ClusterPolicy label-ai-agent-pods is active"
else
  warn "ClusterPolicy not found — check kyverno.io CRD availability"
fi

# ── Pillar 2: AI Controls namespace ──────────────────────────────────────────
banner "Setting up Pillar 2 — AI Controls namespace"

kubectl create namespace ai-controls 2>/dev/null || ok "ai-controls namespace already exists"
ok "Namespace 'ai-controls' ready for AI Controls proxy policy"

# ── Pillar 3: eBPF runtime — Kyverno ClusterPolicy pre-check ─────────────────
banner "Setting up Pillar 3 — Kyverno runtime policies"

step "Checking that Kyverno CRDs support ClusterPolicy..."
if kubectl api-resources --api-group=kyverno.io 2>/dev/null | grep -qi "clusterpolicy"; then
  ok "kyverno.io/ClusterPolicy available"
else
  warn "kyverno.io ClusterPolicy CRD not found — Pillar 3 auto-labelling step will be skipped"
fi

step "Creating 'agents' namespace for Pillar 3 demo..."
kubectl create namespace agents 2>/dev/null || ok "'agents' namespace already exists"
ok "Namespace 'agents' ready — pods here will be auto-labelled as AI agents"

# ── Summary ───────────────────────────────────────────────────────────────────
banner "Setup complete — Three-Pillar Demo Ready"

echo -e "${GREEN}${BOLD}Cluster${RESET}      kind cluster '${CLUSTER_NAME}'"
echo -e "${GREEN}${BOLD}Registry${RESET}     ${REGISTRY_HOST}  (HTTP, trusted by cluster)"
echo -e "${GREEN}${BOLD}Kyverno${RESET}      $(helm list -n ${KYVERNO_NAMESPACE} --short 2>/dev/null || echo "installed")"
echo -e "${GREEN}${BOLD}Image${RESET}        ${IMAGE_NAME}:${IMAGE_TAG}"
echo -e "${GREEN}${BOLD}Digest${RESET}       ${IMAGE_DIGEST}"
echo -e "${GREEN}${BOLD}AIBOM${RESET}        ${AIBOM_FILE}"
echo -e "${GREEN}${BOLD}Keys${RESET}         ${KEYS_DIR}/cosign.{key,pub}"
echo
echo -e "  ${BOLD}Pillar 1 (AI BOM)${RESET}         GitHub Actions workflow   — source scan, CI gate, SARIF, attest"
echo -e "  ${BOLD}Pillar 2 (AI Controls)${RESET}    demo/ai-controls/        — proxy sanctioned policy (CRD optional)"
echo -e "  ${BOLD}Pillar 3 (Kyverno eBPF)${RESET}  demo/ebpf-policies/      — NetworkPolicy + ClusterPolicy (active)"
echo
echo -e "${BOLD}Show Pillar 1 first:${RESET}"
echo    "  GitHub Actions → AIBOM Demo — Pillar 1 → Run workflow"
echo
echo -e "${BOLD}Then run Pillars 2–3 live:${RESET}"
echo    "  bash demo/run-demo.sh"
echo
echo -e "${BOLD}Tear down when done:${RESET}"
echo    "  kind delete cluster --name ${CLUSTER_NAME}"
echo    "  docker rm -f ${REGISTRY_NAME}"
echo
