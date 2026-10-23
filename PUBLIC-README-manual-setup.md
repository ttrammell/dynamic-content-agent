<!--
CANONICAL "manual-setup-after-deploying" section for the PUBLIC repo README
(github.com/ttrammell/dynamic-content-agent). This file is the source of truth kept in the
toolkit repo so it stays reconciled with the install runbook
(docs/agentforce-agent-package-install-runbook.md) and the panel's Setup tab (dcAgentPreflight
readinessRows). When you edit any of the three, update the other two. Paste the section below,
verbatim, under the README anchor #manual-setup-after-deploying.
-->

## Manual setup after deploying

The web-installer (or `sf project deploy`) lands the package as **draft source** — it is NOT a
live agent yet, and its self-auth isn't configured. Finish these steps. Everything here is also
shown as a live checklist in the **Setup tab** of the "Dynamic Content Agent" panel that appears
in the CMS email builder after deploy — use it to see each item's ✓/✗ status and jump to the
right Setup page.

Steps 1–4 are the JWT self-auth (the agent mints its own token to write CMS + wire Data Cloud
personalization). `install.py` automates the packageable parts; the items below are the
irreducible manual ones.

1. **OAuth consent on the External Client App** — Setup → **External Client App Manager** →
   `AuraPoc_JwtApp` → Edit Settings:
   - Enable **OAuth** + **JWT Bearer Flow**.
   - Scopes: **`api`** + **`full` (Full access)** + a Data Cloud scope (**`cdp_query_api`**) +
     **`refresh_token` (offline_access)**. ⚠ `refresh_token` is **required** (JWT bearer 422s
     `refresh_token scope is required` without it) — the #1 first-run failure. ⚠ `full` is **also
     required — do NOT skip** (corrected 2026-10-01): without it `frontdoor.jsp` bounces the token
     and PP wiring fails ("Personalization failed AND rollback delete also failed"). Also assign the
     run-as user `EinsteinGPTPromptTemplateUser` (Prompt Template User) for LLM generation.
     NOTE: this file now MIRRORS the live public README (github.com/ttrammell/dynamic-content-agent),
     which is the richer source — update that README first, then sync this file to it.
   - Select the deployed certificate **`AuraPoc_JwtCert`** — try the picker first. If it's not
     listed (common on a fresh org), download it (Certificate and Key Management →
     `AuraPoc_JwtCert` → Download Certificate) and upload/select that `.crt` in the ECA (confirmed
     necessary on a fresh-org install 2026-10-02). Never generate a brand-new self-signed cert —
     a different key won't match the config record's `CertDevName__c`.

2. **Run-as user pre-authorization** — same app → **Policies → OAuth Policies** → set
   **Permitted Users = "Admin approved users are pre-authorized"** (never "self-authorize" — a
   server-to-server flow has no interactive approval). Then assign the perm set to the run-as user
   (`install.py` automates the perm-set assignment; the policy toggle is manual).

3. **Config record** (`AuraPoc_Config.Default`, a Custom Metadata record) — must hold THIS org's
   values (never copy from another org): **Consumer Key** (from `AuraPoc_JwtApp` → Settings),
   `CertDevName__c = AuraPoc_JwtCert`, `RunAsUser__c` = the run-as username, `InstanceUrl__c` =
   this org's My Domain. `install.py` deploys this; verify it in the Setup tab.

4. **Remote Site Settings** (the Aura leg — needed for dynamic-content personalization, not for
   static email builds) — `AuraPoc_FileForce = https://<mydomain>.file.force.com` and
   `AuraPoc_LightningForce = https://<mydomain>.lightning.force.com`. `install.py` generates +
   deploys these with your My Domain substituted; missing them gives
   `System.CalloutException: Unauthorized endpoint`.

   **Prerequisite (not automatable):** a **Marketing CMS workspace** must exist in the org
   (Enhanced space, `spaceType.apiName == 'marketing'`).

5. **Publish + activate** (compile the draft into a live agent — CLI only; there is no API for
   this, and the compiled bundle isn't portable, so it must run in each target org):
   ```bash
   sf agent publish authoring-bundle -n Dynamic_Content_Agent_v3 -o <alias>   # compiles Bot/BotVersion
   sf agent activate  -n Dynamic_Content_Agent_v3 --version <N> -o <alias>     # publish lands INACTIVE
   ```

6. **Grant Agent Access** — Setup → target **Profile or Permission Set** → **App → Agent Access**
   → add `Dynamic_Content_Agent_v3`. An internal agent is invisible to users until this is granted
   (it's a Profile/Perm-Set grant, not a connection).

**Verify:** in the agent's test chat, say **"test the connection"** — it mints the JWT (never
returns it), lists email-capable Marketing CMS workspaces, and probes the Aura session, reporting
each leg independently and naming the exact fix on any failure.
