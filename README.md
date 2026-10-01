# Dynamic Content Agent — installable package

An Agentforce agent (`Dynamic_Content_Agent_v3`) that builds CMS emails from content elements and can wire in Data Cloud dynamic-content personalization. This repo is a deployable Salesforce metadata package for installing it into any org.

## Install via link (no CLI needed)

[Deploy this package to Salesforce](#) *(link filled in once the deploy tool is live)*

Click the link, log into your target org, and deploy. That covers the metadata only (the agent, its Apex actions, prompt templates, a fresh certificate, and a base External Client App record) — five more manual steps are required afterward and can't be automated by any link, on any platform, by design (Salesforce doesn't allow OAuth app authorization to be scripted). See "Manual setup after deploying" below.

## Install via CLI instead

This repo is laid out as **classic (non-SFDX) Metadata API format** — `package.xml` and every metadata type folder (`classes/`, `objects/`, `aiAuthoringBundles/`, etc.) sit directly at the repo root, not nested under `force-app/main/default/`. This is deliberate: the "Install via link" tool above shells out to the `sfdx` CLI to convert genuine SFDX-formatted repos (ones with an `sfdx-project.json`), and that binary isn't installed on the host running that tool — using classic format avoids that conversion step entirely and lets the tool deploy directly via the Metadata API.

```
sf project deploy start --metadata-dir . -o <target-org-alias>
```

(Older `sf`/`sfdx` versions: `sf force:mdapi:deploy --deploydir . --wait 10 -o <target-org-alias>`.)

Before deploying to a brand-new org, open `aiAuthoringBundles/Dynamic_Content_Agent_v3/Dynamic_Content_Agent_v3.bundle-meta.xml` and make sure `<target>` is blank (`<target></target>`) — a blank target creates a fresh v1 in the new org; a version reference from wherever you retrieved this (e.g. `Dynamic_Content_Agent_v3.v12`) won't exist there and the deploy will fail.

## What gets deployed

- The agent's Agent Script bundle (`AiAuthoringBundle`)
- 2 GenAI prompt templates: `AuraPoc_PlanEmailStructureV2` (bound **natively** as an agent action — structure planning only, no Apex mediation) and `AuraPoc_FillSlot` (called from Apex by `FillCopyAction`, one narrow LLM call per copy cell — not agent-bound directly)
- 14 Apex classes: 10 agent actions (`FindBrandAssetsAction`, `FindBrandRecordAction`, `DataGraphDetailsAction`, `ResolveBrandingAction`, `AssembleContentPlanAction`, `FillCopyAction`, `ValidateContentPlanAction`, `BuildDynamicEmailAction`, `ConfirmBuildAction`, `AuthDiagnosticAction`) plus 4 shared utility/auth classes (`AuraPocTokenProvider`, `AuraPocTokenSource`, `AuraServiceClient`, `AuraSessionMinter`)

  `AuthDiagnosticAction` ("Test Connection") is new: a read-only, in-conversation self-check that mints a token via the same JWT flow the real actions use, then lists email-capable (Enhanced + Marketing) CMS workspaces. Ask the agent to "test the connection" any time setup seems broken — it returns pass/fail plus the exact fix, instead of failing cryptically mid-build.

  Structure planning stays a direct native prompt-template binding in the agent script. Copywriting changed: the old monolithic `AuraPoc_WriteEmailCopy` step (one LLM call asked to emit an entire copy matrix in one JSON blob) was replaced by `FillCopyAction`, which drives a deterministic per-cell loop in Apex and makes one narrow LLM call per cell via `AuraPoc_FillSlot` — the model never sees rules, slot keys, or JSON shape, only one element's text at a time. Fixes a copy-coverage-gap failure class where the old single-call approach was repeatedly under-filling the matrix.
- The `AuraPoc_Config__mdt` custom metadata type (its **type only** — the `Default` record ships with placeholder values you must fill in, see Step 4 below)
- A fresh self-signed `AuraPoc_JwtCert` certificate — Salesforce generates a brand-new private key for whichever org you deploy into; nothing is copied from anywhere
- A base `AuraPoc_JwtApp` External Client App record (name/label only — its OAuth/JWT settings are not deployable metadata, see Step 2)

**This does not make the agent live.** It only lands the draft source — see Step 5.

## Manual setup after deploying

### Step 1 — Enable OAuth on the External Client App

The agent's Apex actions authenticate back into the org itself using a JWT Bearer flow (certificate-based server-to-server login, not a client secret).

1. Setup → Quick Find → **External Client Apps Manager** → open **AuraPoc_JwtApp** → **Edit Settings**
2. Check **Enable OAuth**
3. **Callback URL**: any syntactically valid HTTPS URL works — JWT Bearer flow never actually redirects to it. Use `https://<your-domain>.my.salesforce.com/services/oauth2/callback`
4. **OAuth Scopes** — add:
   - `Manage user data via APIs (api)`
   - `Full access (full)` — **required, do not skip.** Confirmed live: an `api`-only token mints fine and simple builds even succeed, but the Build action's Personalization Point wiring step needs a real browser-capable Lightning session, not just an API token. Without `full`, `frontdoor.jsp` bounces the token back to itself (`ec=302`, no session cookie set) instead of promoting a session — this surfaces as the agent stalling after you approve a build plan, then eventually reporting something like "Build failed: Personalization failed AND rollback delete also failed." Reproduced side by side: `api`+Data Cloud+`refresh_token` alone reproduces the bounce every time; adding `full` clears it.
   - a Data Cloud scope (`cdp_api` if offered as a general scope; otherwise `cdp_query_api` or `cdp_profile_api`, whichever your org exposes)
   - `Perform requests on your behalf at any time (refresh_token, offline_access)` — **required**, even though this flow never actually returns or uses a refresh token. Omitting it is the single most common reason this setup fails on first test (`invalid_request: refresh_token scope is required...`)
5. Check **Enable JWT Bearer Flow**
6. **Certificate**: select the existing **AuraPoc_JwtCert** from the picker (already exists from the deploy — do not upload a new file)
7. Leave **"Issue JSON Web Token (JWT)-based access tokens for named users"** unchecked — unrelated setting, controls token *format*, not whether JWT Bearer auth works
8. Save

### Step 2 — Pre-authorize the run-as user

1. Same app → **Policies** tab → **OAuth Policies** → Permitted Users = **"Admin approved users are pre-authorized"** (not "self-authorize" — that requires a prior interactive approval that will never exist for a server-to-server flow, and the token exchange will fail as unauthorized)
2. Under **App Policies**, add the run-as user's Profile (e.g. System Administrator, if that's their profile) or a dedicated Permission Set to Selected Profiles/Permission Sets
3. Confirm that user also has the **Prompt Template User** permission set (`EinsteinGPTPromptTemplateUser`) assigned — separate gate required for Apex/API-invoked LLM generation, not included in System Administrator by default
4. Save

### Step 3 — Get the Consumer Key and finish the config record

1. Same app's page → **Manage Consumer Details** → copy the **Consumer Key**
2. Setup → Custom Metadata Types → **AuraPoc Config** → Manage Records → edit the **Default** record and replace the placeholder values:
   - `ConsumerKey__c` = the Consumer Key you just copied
   - `CertDevName__c` = `AuraPoc_JwtCert`
   - `RunAsUser__c` = the run-as user's exact username
   - `InstanceUrl__c` = this org's My Domain URL

**Never copy these four values from another org.** Every value is org-specific — pasting another org's values will make the agent silently authenticate against the wrong org.

### Step 4 — Allow the session-minting callouts (Remote Site Settings)

Building an email with a Personalization Point promotes the JWT bearer token into a real Lightning session via `frontdoor.jsp`, then makes follow-up Apex HTTP callouts to complete that hop. `Auth.JWTBearerTokenExchange` (Steps 1–3's token fetch) is exempt from the outbound-callout allowlist, but these follow-up requests are not — each needs an explicit, active entry in Setup → Security → **Remote Site Settings**, or they fail with `System.CalloutException: Unauthorized endpoint`.

1. Setup → Quick Find → **Remote Site Settings** → New Remote Site
2. Add an entry pointing at `https://<your-my-domain>.file.force.com`
3. Add a second entry pointing at `https://<your-my-domain>.lightning.force.com`
4. Confirm both are checked **Active**, then Save

Both hosts are org-specific (your own My Domain, different suffix) — they can't be shipped as deployable metadata. Every target org needs its own pair.

### Step 5 — Compile the draft into a live agent

Setup → Agents (Agent Builder) → open **Dynamic Content Agent** → click **Commit Version**.

**Save ≠ Commit Version — confirmed live.** Clicking Save (or making a trivial edit and saving) keeps the agent in **Draft** state and does *not* produce a queryable `BotDefinition`/`BotVersion`, even though Agent Builder's Preview pane will still happily chat with it off raw draft source — which is exactly what masks this being unfinished. Symptom if you skip this: the plan-generation turn works fine (every Apex action fires and succeeds), but the moment the conversation tries to transition into the build subagent after you approve the plan, it silently goes nowhere — no error, no further Apex call, every single time. Only **Commit Version** creates the real compiled planner/plugin graph that transition needs to land on.

### Step 6 — Grant Agent Access (make it visible to users)

Committing a version makes the agent *live and queryable*, but an internal (Employee) agent is still invisible to users until you grant **Agent Access** — a Profile/Permission Set grant, not a connection (internal agents have none).

1. Setup → the target **Profile** or **Permission Set** (the one you pre-authorized in Step 2 is a convenient choice) → **App → Agent Access**
2. Add **Dynamic Content Agent** (`Dynamic_Content_Agent_v3`)
3. Save

Without this, the agent runs but no one can see or launch it from the UI.

## Verifying it worked

```
sf data query --query "SELECT DeveloperName FROM BotDefinition WHERE DeveloperName = 'Dynamic_Content_Agent_v3'" -o <target-org-alias>
```

Should return one row once Step 5 above is done (not just opened without error — Draft agents open fine too). Then test a real build in Agent Builder's test chat **with a personalized/dynamic element**, not just a static one, to confirm the full JWT + LLM chain and the session-minting callouts (Step 4) actually work together — a static-only build can succeed even with Step 4 missing, since it never touches Personalization Points.
