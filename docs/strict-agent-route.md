# Strict Agent Route: allowing only Claude and Copilot

How a company can limit AI coding agents to Claude and GitHub Copilot, and where a company-owned harness fits in.

**Bottom line:** no single control stops other agents. Enforcement takes three layers: a network default-deny on AI traffic, endpoint allowlisting, and company-only credentials. A company harness doesn't enforce anything; its job is to make the approved path the easiest one.

## 1. Decide what you are banning

An "agent" is two parts:

| Part | Examples | Enforced mainly by |
|------|----------|--------------------|
| **Client** (the app) | Cursor, Cline, Aider, opencode, a browser tab | Endpoint control (harder) |
| **Model provider** (where the data goes) | OpenAI, Gemini, OpenRouter, local Ollama | Network and credentials (easier) |

Many clients can call Claude. Cline using the company's Claude key still sends data only to Anthropic. Most policies care about data destination, so **providers only** is usually the right rule. Add a **clients only** rule only if you also need a consistent toolchain.

## 2. Layer 1: Network

### App fingerprinting alone is not enough

Layer-7 app identification (e.g. Palo Alto App-ID) recognises known web apps such as chatgpt.com. Most coding agents, though, make plain HTTPS calls to an API (`api.openai.com`, `generativelanguage.googleapis.com`, `openrouter.ai`). Without TLS decryption, those calls look like any other traffic.

### What works: a secure web gateway (SWG/SSE) or CASB with TLS inspection

Zscaler, Netskope, Palo Alto Prisma Access and Microsoft Defender for Cloud Apps all ship a predefined Generative AI category. The pattern Netskope recommends:

1. Block the whole Generative AI category.
2. Allow the sanctioned apps: Anthropic and GitHub Copilot.
3. End with a catch-all block rule for any unsanctioned AI traffic.

### Tenant restrictions (block personal accounts on allowed services)

Allowing `claude.ai` or `github.com` would also allow personal accounts. Both vendors let your proxy inject a header that limits access to your own tenant:

**Anthropic: `anthropic-allowed-org-ids`**

- The value is a comma-separated list of organization UUIDs, with no spaces.
- Larger lists use continuation headers (`;n=K`, then `anthropic-allowed-org-ids1` and up): at most 10 header lines and 500 UUIDs in total.
- Inject the header into traffic to `claude.ai`, `api.anthropic.com`, `claude.com` and `anthropic.com`. TLS inspection is required. Overwrite the header on every request; don't add it only when it is missing.
- It covers web, desktop, API-key and OAuth-token access. Claude Code isn't named in the article, so test it.
- Requires an Enterprise plan or a Console organization.
- A blocked org gets HTTP 403 with `"error_code":"tenant_restriction_violation"` and the message "Access restricted by network policy. Contact IT Administrator."
- Source: https://support.claude.com/en/articles/13198485-enforce-network-level-access-control-with-tenant-restrictions

**GitHub: `sec-GitHub-allowed-enterprise: <ENTERPRISE-ID>`**

- Inject it into web and API requests to `github.com`.
- Generally available since 2025-09-15, for GitHub Enterprise Cloud with Enterprise Managed Users (EMU) only. Enable it under Settings → Authentication security → Enterprise access restrictions.
- Copilot traffic falls under a **separate** network policy. See GitHub's guide on configuring your proxy server or firewall for Copilot.
- Source: https://github.blog/changelog/2025-09-15-enterprise-access-restrictions-with-corporate-proxies-is-now-generally-available/

### Gaps the network can't close

| Gap | Mitigation |
|-----|------------|
| Laptops off the corporate network | An always-on SSE client (e.g. Zscaler Client Connector) |
| Local models (Ollama, LM Studio) | Block model registries (Hugging Face, the Ollama registry); allowlist apps on the endpoint |
| Personal phones and home PCs | Policy, DLP and training; technical control isn't possible |
| Tunnels and personal VPNs | Endpoint/EDR detection; block known VPN categories |
| Certificate-pinned apps | They break under TLS inspection, so block them or exempt them by name |

## 3. Layer 2: Endpoint (needed for a clients-only rule)

- **App allowlisting through MDM/EDR:** Intune with WDAC/AppLocker on Windows; Jamf or Santa on macOS. Block installs of Cursor, Windsurf, Ollama and similar.
- **IDE extension allowlist:** VS Code has an enterprise policy for allowed extensions. Allow Copilot and block Cline, Continue and similar. Check what your JetBrains version offers.
- **Claude Code managed settings.** Users can't override these.
  - File locations:
    - macOS: `/Library/Application Support/ClaudeCode/managed-settings.json`
    - Linux/WSL: `/etc/claude-code/managed-settings.json`
    - Windows: `C:\Program Files\ClaudeCode\managed-settings.json`
    - Also: a `managed-settings.d/` directory, the macOS profile domain `com.anthropic.claudecode`, or `HKLM\SOFTWARE\Policies\ClaudeCode`.
  - Login: `forceLoginMethod` (`claudeai` or `console`) and `forceLoginOrgUUID` pin users to the company org.
  - Permission locks: `allowManagedPermissionRulesOnly`, `permissions.disableBypassPermissionsMode: "disable"`, `allowManagedHooksOnly`, `allowManagedMcpServersOnly`.
  - Models: `availableModels` restricts which models can be chosen. A managed `model` is only a default, not a lock.
  - A local administrator can still edit the managed file. Don't give developers local admin.
  - Source: https://code.claude.com/docs/en/managed-settings
- **Copilot:** use the org and enterprise policies (allowed models, public-code matching, features) and Copilot's own network guide.

## 4. Layer 3: Credentials

- Never give out raw provider API keys.
- Send every model call through one company **AI gateway** (e.g. LiteLLM, Amazon Bedrock or Google Vertex for Claude, or your proxy). It holds the keys and allowlists providers.
- An unapproved agent then has no credentials to use. You also get audit logs, cost tracking and one place to change providers.
- Point Claude Code at the gateway through managed `env` or `apiKeyHelper`. Verify the exact format in the settings reference before you roll it out.

## 5. A company-owned harness (the canon approach)

### What it gives you, and what it doesn't

It doesn't enforce anything. Nothing stops someone installing another agent next to it. What it does give you:

- one standard workflow (plan, implement, review, evaluate)
- quality gates and an audit trail
- shared skills and project context
- one place to change models or policy

If it talks only to the company gateway, it becomes the easiest approved path. People route around friction, so a good approved path cuts down on shadow AI better than more blocking does.

### Recommended design

1. **Build on top of Claude Code and Copilot CLI**, not on direct model calls. You inherit their tooling, security updates and enterprise controls.
2. **Talk only to the company gateway**, with no keys embedded in the harness.
3. **Deploy through MDM** together with the managed Claude Code settings and Copilot policies.
4. **Keep it thin.** Every supported runtime adds drift. canon's Codex and Pi caveats in `skills/sprint/reference/complete.md` show the cost, and docs mirrored per runtime go stale.

### Build a new one or adapt canon

canon already runs on several harnesses (Claude Code, Codex, Pi). Adding a Copilot CLI target and an "approved runtimes only" setting would likely cost less than a new harness. It would also give canon an enterprise story: canon is the governed workflow layer, and the company's SSE and AI gateway do the enforcing.

## 6. Recommended rollout

1. Pick the rule: providers only (recommended) or providers and clients.
2. Set up the AI gateway and revoke direct provider keys.
3. In the SSE, set a GenAI default-deny, allow Anthropic and Copilot, and inject both tenant-restriction headers.
4. Through MDM, deploy managed Claude Code settings, Copilot policies, the VS Code extension allowlist and app allowlisting.
5. Ship the harness as the default path, pointed at the gateway.
6. Monitor SSE logs for blocked GenAI attempts. Treat repeated attempts as signs of a gap in the approved tooling, not just as violations.

## 7. Still to verify

- Whether Claude Code (OAuth login) is covered by Anthropic tenant restrictions. The article covers OAuth tokens in general but doesn't name Claude Code.
- Copilot's proxy and network policy details, which are separate from `sec-GitHub-allowed-enterprise`.
- The value formats for `apiKeyHelper` and the managed `env` (`ANTHROPIC_BASE_URL`) when pointing at a gateway.
- Whether non-EMU GitHub Enterprise accounts have an equivalent tenant restriction.

*Researched 2026-11-19. Vendor features change, so recheck the sources before writing policy.*
