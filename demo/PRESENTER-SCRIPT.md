# Nirmata AI Security Demo — Presenter Script

Full talking track for the three-pillar customer demo.  
Time: ~25–35 minutes. Adjust depth to audience.

---

## Before You Start

**Have open in browser tabs (in order):**
1. `https://github.com/nirmata/demo-aibom/actions` — for GitHub Actions (Pillar 1)
2. `https://github.com/nirmata/demo-aibom/security/code-scanning` — for SARIF results
3. Nirmata Control Hub — AI Inventory view
4. Terminal window in `kyverno-aibom-reference/` repo root

**Pre-run before the call:**
```bash
bash demo/setup-demo-cluster.sh   # cluster must be ready
```

---

## Opening Hook (2 min)

> **Say:**
> "Every AI agent your team ships has a list of ingredients: which LLM it calls, which tools it has access to, which third-party SDKs it uses. Today most teams have no idea what that list is until something goes wrong."
>
> "Nirmata gives you that visibility — and then enforces it — across three layers: your source code, your LLM API calls, and your Kubernetes cluster. Let me show you what that looks like."

**Transition:** *Open the GitHub Actions tab.*

---

## Pillar 1 — AI BOM: Supply Chain Visibility

> **Customer question this answers:** *"How do I know what AI is in my code?"*

---

### Act 1 — Discovery: What's actually in the code?

**Action:** Trigger the workflow — `approved` scenario.
- Actions → AIBOM Demo — Pillar 1 → Run workflow → `approved`

> **Say:**
> "The first thing we do is scan the source code. Not the Docker image, not the running container — the source code, before anything is built. `nctl` reads the TypeScript files and discovers every AI component: the agent framework, the models being called, the tools registered, any MCP server connections."
>
> "Watch Act 1 complete — it takes about 10 seconds. No instrumentation, no changes to your code."

*Wait for Act 1 to go green.*

> "Found it. One Anthropic SDK agent calling claude-3-5-sonnet. Two tools: web_search and calculator. This is the AI Bill of Materials — the AIBOM."

---

### Act 2 — Baseline: Committing what's approved

> **Say:**
> "Act 2 is the gate. We committed an approved baseline to the repo — `aibom-baseline.json`. That file is your policy. Every PR, every commit gets diffed against it. If a developer adds a new tool, a new model, a new agent — the diff catches it before the PR can merge."
>
> "In this clean case, the scan matches the baseline exactly. Gate passes."

*Wait for Act 2 to go green.*

---

### Act 3 — SARIF + Attestation: Where developers see it

*While Act 3 runs:*

> **Say:**
> "Act 3 does three things: generates a SARIF report and uploads it to the GitHub Security tab — so AI inventory sits right next to CVEs in the same dashboard developers already use. Then it builds the image, and attaches the AIBOM to the specific image digest using cosign."
>
> "The attestation is cryptographically bound to the digest. You can't take an unscanned image and claim it was attested. You can't swap the image after attestation. It's tamper-evident."

*Show the Security tab after Act 3 completes.*

> "Here's the AIBOM in the Security tab. This is where a developer would see it during code review — same place they see dependency vulnerabilities."

---

### Act 4 — CI Gate Blocks a Dangerous Tool

**Action:** Trigger `bad-tool` scenario.
- Run workflow → `bad-tool`

> **Say:**
> "Now let's say a developer adds the filesystem tool to their agent. This gives the agent full read/write access to the container's filesystem — it can read secrets, write files, do damage. They push a PR."
>
> "Act 4 catches it. The diff detects `filesystem` as an added tool. The gate fails. The build never runs. No image is created. The PR can't merge until someone explicitly approves adding that tool to the baseline."

*Point out the build job is skipped — it never ran.*

> "The key point: the baseline is a deliberate approval step. Developers can't accidentally add dangerous capabilities. They have to go through your governance process first."

---

### Act 5 — CI Gate Blocks an Unapproved Model

**Action:** Trigger `bad-model` scenario (or show if already running).
- Run workflow → `bad-model`

> **Say:**
> "Same pattern with models. A developer switches from claude-3-5-sonnet to gpt-5 — maybe it's a new model they want to try, maybe it's a mistake. `gpt-5` isn't in the approved baseline. Gate fails. Build never runs."
>
> "You get this for every model, every tool, every agent framework — anything nctl discovers in the source. And nctl supports TypeScript, Python, Go, Java, Rust, and C#."

---

### Pillar 1 Summary

> **Say:**
> "So Pillar 1 gives you: complete AI inventory from source code, a CI gate that blocks unapproved additions, AI components in your existing security tooling, and a tamper-evident attestation on every image. All in your existing CI pipeline — no new infrastructure."

**Transition:** *Switch to the terminal.*

---

## Pillar 2 — AI Controls Proxy: Sanctioned Governance

> **Customer question this answers:** *"How do I ensure agents only call approved LLMs?"*

> **Say:**
> "The AI BOM tells you what should be there. The AI Controls proxy enforces it at runtime — on every actual API call your agents make."

---

### The Policy

**Action:** Run `bash demo/run-demo.sh` and advance to Pillar 2.

> **Say:**
> "Here's the sanctioned-models policy. It looks like any other Kubernetes policy. Anthropic and OpenAI are approved providers, with specific model lists. gpt-5, o3, and gpt-4-32k are explicitly blocked — each with a reason that gets logged."
>
> "This policy lives in the cluster. Changing it is a `kubectl apply` — takes effect in seconds, no rebuild, no restart."

---

### Blocked Call

> **Say:**
> "An agent calls gpt-5. The AI Controls proxy intercepts the request before it leaves the cluster. Returns a 403 with the policy name, the reason, and an audit ID that's logged to NCH."
>
> "The call never reached OpenAI. No tokens spent. No data sent. No bill."

---

### Allowed Call

> **Say:**
> "Same agent, claude-3-5-sonnet. Proxy checks the policy, finds it's approved, passes it through. Audit entry created. Every call — allowed and blocked — goes into the NCH audit log."
>
> "This means you have a complete record of every LLM call made by every agent across every environment. That's the audit trail your compliance team needs."

---

### Pillar 2 Key Point

> **Say:**
> "The proxy is inline. It's not monitoring, it's not alerting — it's in the request path. A blocked call never happens. That's the difference between governance and observability."

---

## Pillar 3 — Kyverno eBPF Runtime: Kernel-Level Enforcement

> **Customer question this answers:** *"What if someone bypasses the proxy entirely?"*

> **Say:**
> "Let's talk about what a sophisticated attacker or a careless developer can do. They can bypass the proxy. They can route traffic around it. They can modify the agent at runtime. The proxy is software — software can be circumvented."
>
> "Kyverno's eBPF runtime operates at a different layer. eBPF programs run inside the Linux kernel. They intercept the `connect()` syscall — the actual system call that opens a network connection. There is no userspace bypass. You can't LD_PRELOAD your way around it. You can't modify a library. The check happens below your application."

---

### The Policy

**Action:** Advance to Pillar 3 in the script.

> **Say:**
> "Here's the policy. A NetworkPolicy that default-denies all egress from AI agent pods. DNS is allowed. HTTPS to approved endpoints is allowed. Anything else — blocked at the kernel."
>
> "Below that, a Kyverno ClusterPolicy that automatically labels every pod in the `agents` namespace as an AI agent. Developers don't opt in — enforcement is automatic for anything that runs in that namespace."

---

### Auto-Labelling Demo

> **Say:**
> "Watch what happens when I create a pod in the agents namespace."

*Pod gets created, show the label being applied.*

> "Kyverno detected the pod, evaluated the ClusterPolicy, and applied `nirmata.io/ai-agent=true` automatically. That label is the hook. In production, the eBPF runtime uses that label to attach enforcement programs to the container's network namespace. The container doesn't know they're there."

---

### The Production Picture

> **Say:**
> "The full runtime sequence is: pod created in agents namespace → Kyverno auto-labels it → eBPF runtime attaches to the container's network namespace → any `connect()` syscall to an unapproved endpoint is intercepted and killed at the kernel level → violation is logged to NCH with pod, process, destination, and timestamp."
>
> "It doesn't matter if the agent's code was modified after it was deployed. It doesn't matter if someone found a way to route around the proxy. The enforcement is in the kernel."

---

## Wrap-Up (2 min)

> **Say:**
> "So here's the full picture. Three layers, one story."
>
> "**Pillar 1 — AI BOM**: We know exactly what AI components are in your code. A CI gate blocks unapproved additions before they can ship. Everything is attested and published to a central inventory."
>
> "**Pillar 2 — AI Controls Proxy**: At runtime, every LLM API call goes through a policy check. Unsanctioned calls are blocked inline before they reach the provider. Complete audit trail in NCH."
>
> "**Pillar 3 — Kyverno eBPF**: At the kernel level, no agent can make an unauthorized network call regardless of how it was modified or what it tries. Auto-labelling means no agent is ever left uncovered."
>
> "The AI BOM tells you what should be there. The proxy enforces it on every call. The eBPF runtime enforces it even if the proxy is bypassed. You need all three."

---

## Handling Common Questions

**"What languages does the scanner support?"**
> TypeScript, Python, Go, Java, Rust, and C#. No instrumentation needed — it reads source code statically.

**"What if we use a private LLM / on-prem model?"**
> The proxy policy supports any HTTP endpoint. Add your internal endpoint to the allowed list. The AIBOM scanner detects custom SDK wrappers through configurable signatures in `.aibom.yaml`.

**"How does this work with our existing Kyverno installation?"**
> It adds two policy objects to your existing cluster. No changes to your existing policies, no new controllers to run for the admission piece. The eBPF runtime is a separate component.

**"How do we roll this out without breaking existing agents?"**
> Start with the AIBOM scanner in audit mode — it just reports, doesn't block. Generate a baseline from your current codebase. Then enable the gate. For the proxy, start with `enforcement: warn` before switching to `block`. Progressive rollout.

**"What does the NCH dashboard show?"**
> Every agent, in every cluster, with its full AIBOM — which models it calls, which tools it has, which MCP servers it connects to. Plus the audit log of every LLM call. One view across all environments.

**"What's the performance impact of the proxy?"**
> Sub-millisecond latency for allowed calls. The proxy is in-process, not a separate network hop. The eBPF programs add negligible overhead — they're optimized kernel code, not user-space logic.

---

## Demo Cheat Sheet

| Step | Where | Action |
|------|-------|--------|
| Start cluster | Terminal | `bash demo/setup-demo-cluster.sh` (before call) |
| Pillar 1 happy path | Browser → Actions | `approved` scenario |
| Pillar 1 bad tool | Browser → Actions | `bad-tool` scenario |
| Pillar 1 bad model | Browser → Actions | `bad-model` scenario |
| Pillars 2 & 3 | Terminal | `bash demo/run-demo.sh` |
| NCH inventory | Browser → NCH | AI Inventory → Agent Components |
