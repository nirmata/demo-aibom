# Nirmata AI Security — Demo Guide

Talking track and setup guide for the three-pillar Nirmata AI security demo.

---

## The Story

> "AI agents are software. They need a supply chain, a governance layer, and a runtime security layer — just like any other software you run in production."

The demo answers three questions every security-conscious customer has:

| Pillar | Customer question | What Nirmata does |
|--------|------------------|-------------------|
| **1 · AI BOM** | "How do I know what AI is in my code?" | `nctl` scans source → discovers agents, tools, models, MCP; CI gate blocks unapproved additions |
| **2 · AI Controls Proxy** | "How do I ensure agents only call approved LLMs?" | Inline proxy intercepts every LLM API call and enforces a sanctioned model list |
| **3 · Kyverno eBPF Runtime** | "What if someone bypasses the proxy entirely?" | eBPF hooks into kernel `connect()` syscalls — no userspace bypass possible |

---

## How the demo is split

| | Pillar 1 | Pillars 2 & 3 |
|---|---|---|
| **Where** | GitHub Actions | Local terminal |
| **Why** | `nctl agent aibom` requires Linux (CGO build) | `kubectl` and runtime demo work on macOS |
| **Script** | Actions → AIBOM Demo — Pillar 1 → Run workflow | `bash demo/run-demo.sh` |

---

## Before the call — one-time setup

```bash
cd kyverno-aibom-reference
bash demo/setup-demo-cluster.sh
```

Takes 3–5 minutes. Creates: kind cluster, local registry, Kyverno, cosign keypair, attested image, ImageValidatingPolicies, `ai-controls` and `agents` namespaces.

---

## During the call — Step 1: GitHub Actions (Pillar 1)

1. Open **Actions → AIBOM Demo — Pillar 1: AI BOM Supply Chain**
2. Click **Run workflow**, choose a scenario

| Scenario | What it shows |
|----------|--------------|
| `approved` | Happy path: scan → gate passes → SARIF → attest → publish to NCH |
| `bad-tool` | `filesystem` tool detected → diff gate **BLOCKS** before build runs |
| `bad-model` | `gpt-5` detected → diff gate **BLOCKS** before build runs |

**Talking points per act:**

| Act | What to say |
|-----|------------|
| **1 · Discovery** | "nctl scanned the source in seconds — no instrumentation, no SDK changes needed. It found the agent framework, tools, and models by reading the code." |
| **2 · Baseline diff** | "The committed `aibom-baseline.json` is the policy. Anything added that isn't in it fails the gate. Developers can't slip in a new model without an explicit approval step." |
| **3 · SARIF + attest** | "Show the Security tab — AI inventory next to CVEs. The AIBOM is cryptographically attached to the image digest via cosign. You can't claim an image was attested without it actually being attested." |
| **4 · Bad tool blocked** | "The `filesystem` tool gives full disk access to an agent. The diff gate caught it before the PR merged — the build never ran." |
| **5 · Bad model blocked** | "`gpt-5` isn't in the baseline. Gate blocked it. No image was built, no code shipped." |

**Tips:**
- For `approved`: show the **Security** tab after the run — SARIF findings appear here.
- For `approved`: show the **Summary** tab for the pass/fail table.
- For bad scenarios: point out that the build job never ran — the gate stopped everything upstream.

---

## During the call — Step 2: Terminal (Pillars 2 & 3)

```bash
bash demo/run-demo.sh
```

The script pauses between sections. Press **Enter** to advance.

---

### Pillar 2 — AI Controls Proxy (Sanctioned Governance)

**Key question:** "How do I ensure agents only call approved LLMs?"

**What to show:**

1. **The policy file** (`demo/ai-controls/sanctioned-policy.yaml`):
   - `allowedProviders` — approved vendors and model lists
   - `blockedModels` — explicit deny list with reasons
   - `enforcement: block` — not just logging, actually blocks

2. **Blocked call demo** (simulated in script):
   - Agent requests `gpt-5` → proxy returns HTTP 403 with policy reason
   - "The call never reached OpenAI. No token spent, no data sent."

3. **Allowed call demo** (simulated in script):
   - Agent calls `claude-3-5-sonnet` → proxy passes through with audit log
   - "Every approved call is logged to NCH — you have a full audit trail."

**Talking points:**
- "This is inline, not a sidecar that can be disabled. The proxy is the path to the internet."
- "Changing the policy is a `kubectl apply` — no restarts, no rebuilds, takes effect in seconds."
- "The audit log in NCH shows you exactly which agents are calling which models, how often, and what was blocked."

---

### Pillar 3 — Kyverno eBPF Runtime (Kernel-Level Enforcement)

**Key question:** "What if someone bypasses the proxy entirely?"

**What to show:**

1. **The policy file** (`demo/ebpf-policies/agent-egress.yaml`):
   - `NetworkPolicy` — default-deny all egress for `nirmata.io/ai-agent=true` pods
   - `ClusterPolicy` — auto-labels every pod in the `agents` namespace
   - "In production, Kyverno's eBPF runtime adds domain/SNI filtering on top."

2. **Unrestricted pod** (live `kubectl run test-unrestricted`):
   - No label → can reach the internet
   - Shows the before state

3. **AI agent pod blocked** (live `kubectl run test-agent` with label):
   - Same image, same command, but labelled as AI agent
   - Connection times out — the kernel-level policy blocks the egress
   - "This is enforced by the CNI at the kernel level — the process never completes the TCP handshake."

**Talking points:**
- "The proxy is the policy layer. eBPF is the enforcement backstop. Even if someone finds a way to bypass the proxy, the kernel blocks the call."
- "The auto-labelling ClusterPolicy means developers don't have to remember to opt in. Everything in the `agents` namespace is covered automatically."
- "This is the difference between software-level and kernel-level enforcement."

---

## Key talking points (all pillars)

> **"Three layers, one story."**
> Source code → CI → runtime. We cover every point where an AI component can be introduced or misused.

> **"The AI BOM is the source of truth."**
> It's not documentation — it's a signed artifact attached to your image. If the AIBOM says it, it's true. If there's no AIBOM, the image can't deploy.

> **"The proxy is inline, not observability."**
> Blocking happens before the call reaches the provider. This isn't alerting after the fact — it's prevention.

> **"eBPF can't be bypassed from userspace."**
> The check happens in the kernel, below the application layer. No LD_PRELOAD trick, no modified library, no admin escalation gets around it.

> **"Policy changes propagate in seconds."**
> Add a model to the approved list → `kubectl apply` → the proxy picks it up. No rebuild, no restart, no deployment window.

---

## File map

```
demo/
├── DEMO-GUIDE.md                    ← you are here
├── DEMO-GUIDE.html                  ← browser-ready version
├── README.md                        ← setup and script reference
├── setup-demo-cluster.sh            ← one-time environment setup
├── run-demo.sh                      ← Pillars 2–3 live terminal demo
│
├── ai-controls/
│   └── sanctioned-policy.yaml      ← Pillar 2: proxy governance policy
│
├── ebpf-policies/
│   └── agent-egress.yaml           ← Pillar 3: NetworkPolicy + ClusterPolicy
│
├── bad-agent-tools.ts              ← Pillar 1 Act 4: filesystem tool demo
├── bad-agent-model.ts              ← Pillar 1 Act 5: gpt-5 model demo
│
└── manifests/
    ├── pod-approved-local.yaml     ← generated by setup (digest pre-filled)
    └── pod-no-attestation-local.yaml

../.github/workflows/
└── demo-acts-1-5.yml               ← Pillar 1 CI demo (manual trigger)
```

---

## Troubleshooting

**`nctl agent aibom` not supported (macOS)**
Expected. The AIBOM scanner requires a Linux CGO build. Use the GitHub Actions workflow for Pillar 1.

**Approved pod blocked by Kyverno with registry connection error**
Kyverno's attestation verification tries to reach `localhost:5001` from inside the cluster (which doesn't resolve to the host). This is a local networking limitation. The attestation story is fully demonstrated in GitHub Actions (Pillar 1). The local demo focuses on Pillars 2–3.

**NetworkPolicy not blocking in Pillar 3**
kindnet supports NetworkPolicy but it can take 10–30s to propagate. If the test-agent pod reaches the internet, wait 30s and re-run. Check: `kubectl describe networkpolicy ai-agent-default-deny`.

**AIControlsPolicy CRD not found**
The `controls.nirmata.io` CRD requires the AI Controls component to be deployed. The demo script gracefully skips the `kubectl apply` and shows the policy file for the talking point. The blocked/allowed call outputs are simulated.

**Starting fresh**
```bash
kind delete cluster --name aibom-demo
docker rm -f aibom-demo-registry
rm -rf demo/keys demo/policies-local demo/aibom-demo.json
bash demo/setup-demo-cluster.sh
```
