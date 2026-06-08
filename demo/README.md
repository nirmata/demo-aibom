# Nirmata AI Security Demo — Runbook

Three-pillar live demo: AI BOM supply chain visibility, AI Controls proxy governance, and Kyverno eBPF runtime enforcement.

---

## The Story

> *"AI agents are software. They need a supply chain, a governance layer, and a runtime security layer — just like any other software you run in production."*

| Pillar | Customer question | What it shows |
|--------|-----------------|---------------|
| **1 · AI BOM** | "How do I know what AI is in my code?" | `nctl` scans source → discovers agents, tools, models, MCP; CI gate blocks unapproved additions |
| **2 · AI Controls Proxy** | "How do I ensure agents only call approved LLMs?" | Inline proxy intercepts every LLM API call and enforces a sanctioned model list |
| **3 · Kyverno eBPF Runtime** | "What if someone bypasses the proxy?" | eBPF hooks into kernel `connect()` syscalls — no userspace bypass possible |

**Full talking track with Q&A prep:** [`PRESENTER-SCRIPT.md`](PRESENTER-SCRIPT.md)

---

## Prerequisites

| Tool | Purpose | Install |
|------|---------|---------|
| `kind` | Local Kubernetes cluster | https://kind.sigs.k8s.io/docs/user/quick-start/ |
| `docker` | Build images, run local registry | https://docs.docker.com/get-docker/ |
| `kubectl` | Interact with the cluster | https://kubernetes.io/docs/tasks/tools/ |
| `helm` | Install Kyverno | https://helm.sh/docs/intro/install/ |
| `cosign` | Attest images | https://docs.sigstore.dev/cosign/system_config/installation/ |

> **macOS note:** The macOS `nctl` binary does not include the AIBOM scanner. Pillar 1 always runs in GitHub Actions on a Linux runner. No local `nctl` required.

---

## Before the Call — One-Time Setup

```bash
git clone https://github.com/nirmata/demo-aibom
cd demo-aibom
bash demo/setup-demo-cluster.sh
```

Takes **3–5 minutes**. Do this before the customer call. Creates:
- kind cluster `aibom-demo` + local registry on `localhost:5001`
- Kyverno installed via Helm
- `research-agent` image built, pushed, and AIBOM-attested
- Pillar 3 policies applied (NetworkPolicy + Kyverno ClusterPolicy)
- `ai-controls` and `agents` namespaces ready

---

## Demo Steps

### Step 1 — Pillar 1: AI BOM via GitHub Actions

**Open:** `https://github.com/nirmata/demo-aibom/actions`

1. Click **"AIBOM Demo — Pillar 1: AI BOM Supply Chain"** in the left sidebar
2. Click **"Run workflow"**
3. Choose a scenario and walk through the job graph live:

| Scenario | What to show | Expected result |
|----------|-------------|-----------------|
| `approved` | Happy path: scan → gate passes → SARIF → attest | All Acts ✅ green |
| `bad-tool` | `filesystem` tool added by a developer | Act 1 ✅, Act 4 ❌ gate blocks |
| `bad-model` | `gpt-5` used instead of approved model | Act 1 ✅, Act 5 ❌ gate blocks |

**What each act answers:**

| Act | Say this |
|-----|---------|
| **1 · Discovery** | "nctl scanned the source in seconds — found the framework, model, and tools just by reading the code." |
| **2 · Baseline diff** | "The committed JSON is the policy. Any unapproved addition fails the gate before the PR can merge." |
| **3 · SARIF + attest** | "AI inventory surfaces in the Security tab next to CVEs. The AIBOM is cryptographically bound to the image." |
| **4 · filesystem blocked** | "Full disk access from an agent. Gate caught it before the PR merged — build never ran." |
| **5 · gpt-5 blocked** | "Not in the baseline. Gate blocked it. No image built, no code shipped." |

**After the `approved` run:** click the **Security tab** to show SARIF findings alongside CVEs.

---

### Step 2 — Pillars 2 & 3: Terminal Demo

**Open a terminal** in the `demo-aibom` directory:

```bash
bash demo/run-demo.sh
```

Press **Enter** to advance between sections.

#### Pillar 2 — AI Controls Proxy

| Section | What to say |
|---------|------------|
| Show policy | "Approved providers and models are listed. Blocked models have reasons that get logged. Changing this is a `kubectl apply` — takes effect in seconds." |
| Blocked call | "gpt-5 → HTTP 403 from the proxy. The call never reached OpenAI. No tokens spent, no data sent." |
| Allowed call | "claude-3-5-sonnet → allowed through with an audit entry in NCH. Every call is logged." |
| Key point | "This is inline — it's in the request path, not monitoring after the fact." |

#### Pillar 3 — Kyverno eBPF Runtime

| Section | What to say |
|---------|------------|
| Show policy | "Default-deny all egress from AI agent pods. Only DNS and approved HTTPS allowed." |
| Apply policies | "NetworkPolicy and a Kyverno ClusterPolicy that auto-labels every pod in the agents namespace." |
| Auto-label demo | "Watch: I create a pod in the agents namespace. Kyverno automatically applies `nirmata.io/ai-agent=true`. Enforcement is automatic — developers don't opt in." |
| Production picture | "In production, that label is how Kyverno eBPF attaches to the container's network namespace. The connect() syscall to any unapproved endpoint is killed at the kernel. No userspace bypass possible." |

---

## File Map

```
demo-aibom/
├── demo/
│   ├── README.md                    ← you are here
│   ├── PRESENTER-SCRIPT.md          ← full talking track with Q&A prep
│   ├── DEMO-GUIDE.md                ← concise presenter notes
│   ├── DEMO-GUIDE.html              ← browser-ready version
│   │
│   ├── setup-demo-cluster.sh        ← one-time cluster bootstrap
│   ├── run-demo.sh                  ← Pillars 2–3 interactive terminal demo
│   │
│   ├── ai-controls/
│   │   └── sanctioned-policy.yaml  ← Pillar 2: proxy governance policy
│   │
│   ├── ebpf-policies/
│   │   └── agent-egress.yaml       ← Pillar 3: NetworkPolicy + ClusterPolicy
│   │
│   ├── bad-agent-tools.ts          ← Pillar 1 Act 4: filesystem tool
│   ├── bad-agent-model.ts          ← Pillar 1 Act 5: gpt-5 model
│   │
│   └── manifests/
│       ├── pod-approved-local.yaml      ← generated by setup
│       └── pod-no-attestation-local.yaml
│
├── src/
│   └── research-agent.ts           ← the agent being scanned
├── aibom-baseline.json             ← approved AIBOM baseline (the policy)
├── .aibom.yaml                     ← scanner configuration
└── .github/workflows/
    └── demo-acts-1-5.yml           ← Pillar 1 CI workflow
```

---

## Demo Flow at a Glance

```
BEFORE THE CALL          DURING THE CALL
─────────────────────    ──────────────────────────────────────────────────

bash setup-demo-         Step 1 — Browser: GitHub Actions (Pillar 1)
  cluster.sh             ──────────────────────────────────────────────
  ↓                        Actions → AIBOM Demo — Pillar 1
  kind cluster             Run workflow → pick scenario:
  Kyverno installed          approved  → Acts 1–3 all green
  image built + attested     bad-tool  → Act 4 blocks the PR
  namespaces ready           bad-model → Act 5 blocks the PR
  Pillar 3 policies          Walk through job graph live
  applied
                           After approved: show Security tab (SARIF)

                         Step 2 — Terminal: Pillars 2 & 3
                         ──────────────────────────────────────────────
                           bash demo/run-demo.sh
                           Pillar 2: proxy policy → blocked call → allowed call
                           Pillar 3: NetworkPolicy → Kyverno auto-labelling
```

---

## Troubleshooting

**nctl aibom not supported on macOS**
Expected. Pillar 1 runs in GitHub Actions (Linux). No action needed.

**Kyverno ClusterPolicy not auto-labelling pods**
```bash
kubectl get clusterpolicy label-ai-agent-pods
kubectl describe clusterpolicy label-ai-agent-pods
```

**NetworkPolicy not applied**
```bash
kubectl get networkpolicies
kubectl apply -f demo/ebpf-policies/agent-egress.yaml
```

**AIControlsPolicy CRD not found (Pillar 2)**
Expected if AI Controls is not deployed. The script shows the policy file and skips the apply gracefully.

**Cluster not responding / stale setup**
```bash
kind delete cluster --name aibom-demo
docker rm -f aibom-demo-registry
rm -rf demo/keys demo/policies-local demo/aibom-demo.json
bash demo/setup-demo-cluster.sh
```

**GitHub Actions workflow not appearing in sidebar**
Ensure you are on the `main` branch of `nirmata/demo-aibom`. The workflow must exist on the default branch to appear in the Actions UI.
