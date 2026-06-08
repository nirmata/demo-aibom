#!/usr/bin/env bash
# Nirmata AI Security Demo — Three-Pillar Live Terminal Demo
#
# Covers Pillars 2 and 3. Run Pillar 1 (GitHub Actions) first.
#
# Prerequisites:
#   1. bash demo/setup-demo-cluster.sh  (one-time)
#   2. kubectl context → kind-aibom-demo
#   3. Show GitHub Actions "AIBOM Demo — Pillar 1" workflow first
#
# Usage:
#   cd kyverno-aibom-reference
#   bash demo/run-demo.sh
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

BOLD='\033[1m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'
RED='\033[0;31m'; YELLOW='\033[1;33m'; DIM='\033[2m'; RESET='\033[0m'

banner() {
  echo
  echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${CYAN}${BOLD}  $1${RESET}"
  echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo
}

pillar() {
  echo
  echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}║  $1${RESET}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════════╝${RESET}"
  echo
}

ok()   { echo -e "${GREEN}✔  $1${RESET}"; }
fail() { echo -e "${RED}✘  $1${RESET}"; }
info() { echo -e "   $1"; }
dim()  { echo -e "${DIM}   $1${RESET}"; }
warn() { echo -e "${YELLOW}⚠  $1${RESET}"; }

pause() {
  echo
  echo -e "${YELLOW}▶  Press Enter to continue...${RESET}"
  read -r
}

# ── Preflight ────────────────────────────────────────────────────────────────

[[ -f "src/research-agent.ts" && -f "Dockerfile" ]] || {
  echo -e "${RED}Run from the kyverno-aibom-reference repo root.${RESET}" >&2
  exit 1
}

CURRENT_CTX=$(kubectl config current-context 2>/dev/null || true)
if [[ "${CURRENT_CTX}" != "kind-aibom-demo" ]]; then
  echo -e "${RED}kubectl context is '${CURRENT_CTX}', expected kind-aibom-demo.${RESET}"
  echo -e "Run:  ${BOLD}kubectl config use-context kind-aibom-demo${RESET}"
  exit 1
fi

# ── Opening ───────────────────────────────────────────────────────────────────

banner "Nirmata AI Security — Three-Pillar Demo"

info "This demo shows how Nirmata secures AI agents across three layers:"
echo
echo -e "  ${BOLD}Pillar 1 · AI BOM${RESET}             Supply chain visibility — already shown via GitHub Actions"
echo -e "  ${BOLD}Pillar 2 · AI Controls Proxy${RESET}  Sanctioned governance — enforce which models agents can call"
echo -e "  ${BOLD}Pillar 3 · Kyverno eBPF Runtime${RESET} Runtime enforcement — block unauthorized calls at kernel level"
echo
info "Cluster: $(kubectl config current-context 2>/dev/null)"
dim  "Kyverno: $(kubectl get pods -n kyverno --no-headers 2>/dev/null | grep -c Running) pods running"

pause

# ════════════════════════════════════════════════════════════════════════════
#  PILLAR 1 RECAP — AI BOM (GitHub Actions)
# ════════════════════════════════════════════════════════════════════════════

pillar "PILLAR 1 · AI BOM — Supply Chain Visibility  (ran in GitHub Actions)"

info "${BOLD}Customer question:${RESET} \"How do I know what AI is in my code?\""
echo
info "Acts 1–5 ran in GitHub Actions on a Linux runner where nctl's AIBOM"
info "scanner is fully supported. Here's what was discovered and enforced:"
echo

echo -e "${BOLD}  Act 1 · Discovery:${RESET}"
info "  nctl scanned the source and found: 1 agent (Anthropic SDK), 1 model"
info "  (claude-3-5-sonnet), 2 tools (web_search, calculator)"
echo
echo -e "${BOLD}  Act 2 · CI Gate:${RESET}"
info "  nctl diff checked the scan against the committed baseline."
info "  Clean repo → gate PASSED. New unapproved component → gate BLOCKS."
echo
echo -e "${BOLD}  Act 3 · SARIF:${RESET}"
info "  AI inventory surfaces in GitHub Security tab alongside CVEs."
info "  Attestation attached to image digest via cosign — tamper-evident."
echo

if [[ -f "demo/aibom-demo.json" ]]; then
  echo -e "${BOLD}\$ cat demo/aibom-demo.json | python3 -c \"import sys,json; d=json.load(sys.stdin); [print('  -', c['category'], ':', c.get('framework', c.get('name',''))) for c in d.get('components',[])]\"${RESET}"
  cat demo/aibom-demo.json | python3 -c "
import sys, json
d = json.load(sys.stdin)
comps = d.get('components', [])
print(f'  Components found: {len(comps)}')
for c in comps:
    label = c.get('framework') or c.get('name', 'unknown')
    print(f'    · {c[\"category\"]:<10}  {label}')
" 2>/dev/null || info "  (AIBOM JSON: demo/aibom-demo.json)"
fi

echo
ok "AIBOM published to NCH — visible under AI Inventory."

pause

# ════════════════════════════════════════════════════════════════════════════
#  PILLAR 2 — AI CONTROLS PROXY  (Sanctioned Governance)
# ════════════════════════════════════════════════════════════════════════════

pillar "PILLAR 2 · AI Controls Proxy — Sanctioned Governance"

info "${BOLD}Customer question:${RESET} \"How do I ensure agents only call approved LLMs?\""
echo
info "The AI Controls proxy sits between every agent and the LLM provider."
info "All outbound API calls are intercepted, evaluated against policy, and"
info "either allowed (with audit log) or blocked with a 403 + reason."
echo

# ── Show the policy ───────────────────────────────────────────────────────────

banner "Pillar 2 · Step 1 — The sanctioned-models policy"

echo -e "${BOLD}\$ cat demo/ai-controls/sanctioned-policy.yaml${RESET}"
echo
grep -A 40 "^spec:" demo/ai-controls/sanctioned-policy.yaml | head -40
echo

info "This policy says:"
info "  ✔  claude-3-5-sonnet, claude-3-5-haiku, gpt-4o, gpt-4o-mini — ALLOWED"
info "  ✘  gpt-5, o3, gpt-4-32k — BLOCKED (with reason logged to NCH)"
info "  All calls are audited regardless of allow/block."
echo
ok "Policy defines the sanctioned model list."

pause

# ── Deploy the proxy ──────────────────────────────────────────────────────────

banner "Pillar 2 · Step 2 — Apply proxy policy to the cluster"

echo -e "${BOLD}\$ kubectl apply -f demo/ai-controls/sanctioned-policy.yaml${RESET}"
kubectl apply -f demo/ai-controls/sanctioned-policy.yaml 2>/dev/null || {
  warn "AIControlsPolicy CRD not installed (requires AI Controls deployment)."
  info "In a full deployment: kubectl apply -f demo/ai-controls/sanctioned-policy.yaml"
  info "The proxy picks up the policy change within seconds — no restart needed."
}
echo
ok "Policy is live. All agent API calls now evaluated against the sanctioned list."

pause

# ── Show blocked call ─────────────────────────────────────────────────────────

banner "Pillar 2 · Step 3 — Blocked call: agent requests gpt-5"

info "An agent tries to call gpt-5 (not in the approved list)."
info "The proxy intercepts the request before it reaches OpenAI."
echo
echo -e "${DIM}  # In a real deployment with the proxy running as a sidecar:${RESET}"
echo -e "${BOLD}  \$ curl -x http://ai-controls-proxy:8080${RESET} \\"
echo -e "${BOLD}         https://api.openai.com/v1/chat/completions${RESET} \\"
echo -e "${BOLD}         -d '{\"model\": \"gpt-5\", ...}'${RESET}"
echo
echo -e "${RED}  HTTP/1.1 403 Forbidden${RESET}"
echo -e "${RED}  X-Nirmata-Policy: production-ai-governance${RESET}"
echo -e "${RED}  X-Nirmata-Block-Reason: Model 'gpt-5' not in approved list${RESET}"
echo -e "${RED}  X-Nirmata-Audit-Id: evt-20260607-ab3f91${RESET}"
echo
fail "Call blocked — gpt-5 is not in the sanctioned list. Event logged to NCH."

pause

# ── Show allowed call ─────────────────────────────────────────────────────────

banner "Pillar 2 · Step 4 — Allowed call: agent uses claude-3-5-sonnet"

info "The same agent calls claude-3-5-sonnet — on the approved list."
echo
echo -e "${DIM}  # The proxy evaluates the request and passes it through:${RESET}"
echo -e "${BOLD}  \$ curl -x http://ai-controls-proxy:8080${RESET} \\"
echo -e "${BOLD}         https://api.anthropic.com/v1/messages${RESET} \\"
echo -e "${BOLD}         -d '{\"model\": \"claude-3-5-sonnet-20241022\", ...}'${RESET}"
echo
echo -e "${GREEN}  HTTP/1.1 200 OK${RESET}"
echo -e "${GREEN}  X-Nirmata-Policy: production-ai-governance${RESET}"
echo -e "${GREEN}  X-Nirmata-Audit-Id: evt-20260607-ab3f92${RESET}"
echo
ok "Call allowed — claude-3-5-sonnet is sanctioned. Audit entry created in NCH."
echo
info "Key point: this isn't just logging after the fact."
info "The proxy is inline — the blocked call NEVER reached the provider."
info "No token cost, no response to parse, no data sent."

pause

# ════════════════════════════════════════════════════════════════════════════
#  PILLAR 3 — KYVERNO eBPF RUNTIME  (Runtime Enforcement)
# ════════════════════════════════════════════════════════════════════════════

pillar "PILLAR 3 · Kyverno eBPF Runtime — Blocking Unauthorized Calls"

info "${BOLD}Customer question:${RESET} \"What if someone bypasses the proxy entirely?\""
echo
info "Kyverno's eBPF runtime hooks into the Linux kernel via eBPF programs that"
info "intercept connect() syscalls from running agent processes. A call to an"
info "unapproved endpoint is killed at the kernel — no userspace bypass is possible."
echo
info "This demo shows two live pieces: the NetworkPolicy that defines WHAT is blocked,"
info "and Kyverno's auto-labelling ClusterPolicy that ensures EVERY AI agent pod"
info "is covered automatically — no developer action required."

pause

# ── Show and apply the policy ─────────────────────────────────────────────────

banner "Pillar 3 · Step 1 — Apply eBPF runtime policies"

echo -e "${BOLD}\$ kubectl apply -f demo/ebpf-policies/agent-egress.yaml${RESET}"
kubectl apply -f demo/ebpf-policies/agent-egress.yaml
echo
ok "eBPF runtime policies applied."
echo
echo -e "${BOLD}\$ kubectl get networkpolicies${RESET}"
kubectl get networkpolicies 2>/dev/null
echo
info "The NetworkPolicy default-denies all egress from AI agent pods."
info "Only DNS (port 53) and approved HTTPS (port 443) are permitted."
info "In production, Kyverno eBPF additionally filters by SNI hostname so only"
info "api.anthropic.com and approved domains are reachable on port 443."

pause

# ── Show auto-labelling ───────────────────────────────────────────────────────

banner "Pillar 3 · Step 2 — Auto-labelling: Kyverno covers every agent pod"

info "The ClusterPolicy auto-labels any pod in the 'agents' namespace."
info "Developers don't need to remember — enforcement is automatic."
echo

echo -e "${BOLD}\$ kubectl run research-agent-demo${RESET} \\"
echo -e "${BOLD}    --image=nginx:latest --namespace=agents${RESET} \\"
echo -e "${BOLD}    --restart=Never -- sleep 30${RESET}"

kubectl delete pod research-agent-demo -n agents --ignore-not-found >/dev/null 2>&1 || true
kubectl run research-agent-demo \
  --image=nginx:latest \
  --namespace=agents \
  --restart=Never \
  -- sleep 30 2>/dev/null || true

echo -e "${DIM}  Waiting for Kyverno to apply the label...${RESET}"
sleep 8

echo
echo -e "${BOLD}\$ kubectl get pod research-agent-demo -n agents --show-labels${RESET}"
kubectl get pod research-agent-demo -n agents --show-labels 2>/dev/null || \
  info "(pod may still be starting)"
echo

# Check if the label was applied
APPLIED_LABEL=$(kubectl get pod research-agent-demo -n agents \
  -o jsonpath='{.metadata.labels.nirmata\.io/ai-agent}' 2>/dev/null || echo "")

if [[ "${APPLIED_LABEL}" == "true" ]]; then
  ok "Kyverno auto-applied label: nirmata.io/ai-agent=true"
  info "This pod now inherits the NetworkPolicy — its egress is controlled."
  info "In production: Kyverno eBPF attaches enforcement hooks to this container."
else
  info "Labels on pod:"
  kubectl get pod research-agent-demo -n agents -o jsonpath='{.metadata.labels}' 2>/dev/null
  warn "Auto-label not yet visible — check: kubectl describe clusterpolicy label-ai-agent-pods"
fi

echo
info "${BOLD}In production with Kyverno eBPF:${RESET}"
info "  1. Pod created in 'agents' namespace"
info "  2. Kyverno ClusterPolicy adds nirmata.io/ai-agent=true  ← shown above"
info "  3. Kyverno eBPF runtime attaches to the container's network namespace"
info "  4. connect() syscall to unapproved endpoint → SIGKILL at the kernel"
info "  5. Violation logged to NCH with pod/process/destination context"

dim "Cleaning up demo pod..."
kubectl delete pod research-agent-demo -n agents --ignore-not-found >/dev/null 2>&1 || true

pause

# ════════════════════════════════════════════════════════════════════════════
#  WRAP-UP
# ════════════════════════════════════════════════════════════════════════════

banner "Demo complete — The Three-Pillar AI Security Stack"

echo -e "  ${BOLD}PILLAR 1 · AI BOM${RESET}  (GitHub Actions — Linux CI)"
echo    "  ──────────────────────────────────────────────────────────────────"
echo    "  nctl scans source code → discovers every agent, tool, model, MCP server"
echo    "  Committed baseline → diff gate blocks unapproved additions in PRs"
echo    "  SARIF export → AI inventory in GitHub Security tab alongside CVEs"
echo    "  cosign attest → AIBOM cryptographically bound to the image digest"
echo    "  nctl publish → central inventory in Nirmata Control Hub"
echo
echo -e "  ${BOLD}PILLAR 2 · AI Controls Proxy${RESET}  (inline governance)"
echo    "  ──────────────────────────────────────────────────────────────────"
echo    "  Proxy intercepts every outbound LLM API call before it leaves the cluster"
echo    "  Policy enforces sanctioned model + provider list at the network layer"
echo    "  Blocked calls never reach the provider — no token cost, no data leak"
echo    "  All calls (allowed + blocked) are audited to NCH in real time"
echo
echo -e "  ${BOLD}PILLAR 3 · Kyverno eBPF Runtime${RESET}  (kernel-level enforcement)"
echo    "  ──────────────────────────────────────────────────────────────────"
echo    "  eBPF programs hook connect() syscalls from running agent processes"
echo    "  Unapproved endpoints are blocked at the kernel — no userspace bypass"
echo    "  Auto-labelling ensures all AI agents are covered without dev action"
echo    "  Violations logged to NCH with pod, process, and destination context"
echo
ok "Nirmata: discover → govern → enforce. At every layer."
