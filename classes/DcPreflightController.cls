// Read-only controller for the "DC Agent Preflight" LWC companion panel. Runs as the USER (with
// sharing) and needs NO JWT: the inspect reads go through a self-callout to THIS org's own REST
// /query using UserInfo.getSessionId() (the org's My Domain is auto-allowlisted for self-callouts,
// so no Remote Site Setting is needed). The one thing the browser/user session can't do -- mint the
// JWT and probe the Aura leg -- is delegated to the existing server-side AuthDiagnosticAction via
// runFullTest(). Nothing here writes or creates anything.
//
// WHY a self-callout and not inline SOQL: PersonalizationPoint and ManagedContent are exposed by the
// REST query API but are NOT Apex-queryable SObjects (verified 2026-09-23 on SIC2025: Apex
// `[SELECT ... FROM PersonalizationPoint]` won't compile; the /query self-callout returns them 200).
// AuraPoc_Config__mdt IS Apex-queryable, so that one stays plain SOQL (and cacheable).
// Deploys as normal metadata (paired LWC: dcAgentPreflight); NOT part of the agent bundle.
public with sharing class DcPreflightController {

    private static final String API = 'v66.0';

    // Self-callout to the org's own REST /query as the current user (no JWT).
    private static List<Object> queryAsUser(String soql) {
        HttpRequest req = new HttpRequest();
        req.setMethod('GET');
        req.setEndpoint(URL.getOrgDomainUrl().toExternalForm()
            + '/services/data/' + API + '/query?q=' + EncodingUtil.urlEncode(soql, 'UTF-8'));
        req.setHeader('Authorization', 'Bearer ' + UserInfo.getSessionId());
        req.setTimeout(30000);
        HttpResponse r = new Http().send(req);
        if (r.getStatusCode() != 200) {
            throw new AuraHandledException('Query failed (HTTP ' + r.getStatusCode() + '): ' + r.getBody());
        }
        Object recs = ((Map<String, Object>) JSON.deserializeUntyped(r.getBody())).get('records');
        return recs instanceof List<Object> ? (List<Object>) recs : new List<Object>();
    }

    // Real value = non-blank and not an install placeholder (REPLACE_ME…).
    private static Boolean isReal(String v) {
        return String.isNotBlank(v) && !v.contains('REPLACE');
    }

    private static String str(Map<String, Object> m, String k) {
        Object v = m.get(k);
        return v == null ? null : String.valueOf(v);
    }

    // ── Tab 1: "DC in This Email" ── PersonalizationPoints wired into one content item.
    // contentId = the ManagedContent record Id (SourceRecordId on the PP). Read-only.
    @AuraEnabled
    public static List<Map<String, Object>> getDcInEmail(String contentId) {
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        if (String.isBlank(contentId)) { return out; }
        String soql = 'SELECT Name, DeveloperName, PersonalizationSchemaEnum, RootPersonalizationPoint, '
            + 'ProfileDataGraphId, Status FROM PersonalizationPoint WHERE SourceRecordId = \''
            + String.escapeSingleQuotes(contentId) + '\' ORDER BY Name';
        for (Object o : queryAsUser(soql)) {
            Map<String, Object> pp = (Map<String, Object>) o;
            out.add(new Map<String, Object>{
                'name' => str(pp, 'DeveloperName'),
                'label' => str(pp, 'Name'),
                'schema' => str(pp, 'PersonalizationSchemaEnum'),
                'status' => str(pp, 'Status'),
                'isRoot' => pp.get('RootPersonalizationPoint'),
                'dataGraphId' => str(pp, 'ProfileDataGraphId')
            });
        }
        return out;
    }

    // ── Tab 1 detail: CMS element/block structure of one email, EP-style, via the Connect CMS
    // content API (user-session self-callout, verified 2026-09-23). Returns block count + any
    // personalization operations (targetId → PP name → variant count). Best-effort/defensive on the
    // contentBody nesting; getDcInEmail (PersonalizationPoint SOQL) carries the authoritative DC list.
    @AuraEnabled
    public static Map<String, Object> getEmailElements(String contentKey) {
        Map<String, Object> res = new Map<String, Object>{ 'blockCount' => 0, 'operations' => new List<Object>() };
        if (String.isBlank(contentKey)) { return res; }
        HttpRequest req = new HttpRequest();
        req.setMethod('GET');
        req.setEndpoint(URL.getOrgDomainUrl().toExternalForm()
            + '/services/data/' + API + '/connect/cms/contents/' + EncodingUtil.urlEncode(contentKey, 'UTF-8'));
        req.setHeader('Authorization', 'Bearer ' + UserInfo.getSessionId());
        req.setTimeout(30000);
        HttpResponse r = new Http().send(req);
        if (r.getStatusCode() != 200) {
            throw new AuraHandledException('Content details failed (HTTP ' + r.getStatusCode() + ')');
        }
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(r.getBody());
        res.put('name', body.containsKey('title') ? body.get('title') : body.get('apiName'));
        if (body.get('contentBody') instanceof Map<String, Object>) {
            Map<String, Object> cb = (Map<String, Object>) body.get('contentBody');
            if (cb.get('sfdc_cms:block') instanceof List<Object>) {
                res.put('blockCount', ((List<Object>) cb.get('sfdc_cms:block')).size());
            }
            List<Object> ops = new List<Object>();
            if (cb.get('sfdc_cms:operations') instanceof List<Object>) {
                for (Object o : (List<Object>) cb.get('sfdc_cms:operations')) {
                    if (!(o instanceof Map<String, Object>)) { continue; }
                    Map<String, Object> op = (Map<String, Object>) o;
                    String ppName = op.get('personalizationPoint') instanceof Map<String, Object>
                        ? str((Map<String, Object>) op.get('personalizationPoint'), 'name') : null;
                    Integer vc = op.get('decisionToVariantList') instanceof List<Object>
                        ? ((List<Object>) op.get('decisionToVariantList')).size() : 0;
                    ops.add(new Map<String, Object>{
                        'targetId' => op.get('targetId'), 'ppName' => ppName, 'variantCount' => vc });
                }
            }
            res.put('operations', ops);
        }
        return res;
    }

    // ── Tab 2: "DC Agent Configs" ── config-record readiness (Apex SOQL; works pre-auth, cacheable).
    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getConfigStatus() {
        Map<String, Object> res = new Map<String, Object>{ 'configRecordPresent' => false };
        // Org base URL for building Setup deep links in the panel (read-only). Always present, even
        // when the config record is absent, so the walkthrough's fix links resolve on a fresh org.
        res.put('orgBaseUrl', URL.getOrgDomainUrl().toExternalForm());
        // ECA Id so the panel can deep-link straight to the installed External Client App
        // (AuraPoc_JwtApp) in Setup -- where the admin copies the Consumer Key during setup. Inline
        // SOQL (ExternalClientApplication is Apex-queryable; no callout, keeps this method cacheable).
        // Best-effort: absent on a fresh org before install -> panel falls back to the ECA Manager list.
        try {
            List<ExternalClientApplication> eca = [
                SELECT Id FROM ExternalClientApplication WHERE DeveloperName = 'AuraPoc_JwtApp' LIMIT 1];
            if (!eca.isEmpty()) { res.put('externalClientAppId', eca[0].Id); }
        } catch (Exception ignore) { /* ECA object unavailable -> fall back to the manager list link */ }
        List<AuraPoc_Config__mdt> cfg = [
            SELECT Id, DeveloperName, ConsumerKey__c, CertDevName__c, RunAsUser__c, InstanceUrl__c
            FROM AuraPoc_Config__mdt WHERE DeveloperName = 'Default' LIMIT 1 ];
        if (!cfg.isEmpty()) {
            AuraPoc_Config__mdt c = cfg[0];
            res.put('configRecordPresent', true);
            // Record Id so the panel can deep-link straight to the Default config record in Setup
            // (works whether the record is placeholder-only or fully configured -- present in both).
            res.put('configRecordId', c.Id);
            // A field is "set" only if it's non-blank AND not a REPLACE_ME install placeholder --
            // the shipped Default record carries placeholders until an admin fills the real values,
            // and a non-blank placeholder must NOT read as configured (that hid a down auth here).
            res.put('consumerKeySet', isReal(c.ConsumerKey__c));
            res.put('instanceUrlSet', isReal(c.InstanceUrl__c));
            res.put('runAsUserSet', isReal(c.RunAsUser__c));
            res.put('certDevName', c.CertDevName__c);
            res.put('runAsUser', c.RunAsUser__c);
            res.put('instanceUrl', c.InstanceUrl__c);
        }
        return res;
    }

    // ── Tab 2 "Environment health" ── the highest-value health-check probe reachable from the user
    // session (no JWT): Data Cloud reachable + permsets. Mirrors the toolkit's read-only health-check
    // probe semantics (pass/warn/fail). Self-heals to a 'fail'/'warn' row on error rather than
    // throwing. Read-only, cacheable, and CALLOUT-FREE: an earlier version self-called the org's REST
    // API with UserInfo.getSessionId(), which works in anonymous Apex but is BLOCKED from an LWC
    // @AuraEnabled context (the Lightning session isn't a valid REST bearer there), so every probe
    // returned "probe error" in the live panel. This one uses only inline SOQL (MarketSegment,
    // verified queryable on SIC2025 v66). The other panel indicators are sourced elsewhere in the
    // LWC: brands + scoring CI via the GraphQL wire, CMS workspaces via getWorkspaces (SOQL), the
    // profile data graph from the PersonalizationPoint data tab 1 loads.
    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getEnvHealth() {
        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        rows.add(probeDataCloud());
        return rows;
    }

    // Image-catalog readiness for IMAGE dynamic content: personalizing an image = swapping a distinct
    // picture per audience, which needs >= MIN_IMAGES_FOR_SWAP distinct images in the org. This is its
    // OWN method (not folded into cacheable getEnvHealth) because counting images requires a REST
    // self-callout -- the sfdc_cms__image type filter isn't Apex-SOQL-able, and a cacheable method can't
    // make callouts. The panel calls this alongside getEnvHealth and appends the row. Returns a tri-state
    // row {key,label,status,detail} plus count, so the panel can render it like the other health rows.
    // Self-heals to 'warn' on any error rather than throwing (image DC is optional, not a hard gate).
    private static final Integer MIN_IMAGES_FOR_SWAP = 2;
    @AuraEnabled
    public static Map<String, Object> getImageCatalogHealth() {
        try {
            String soql = 'SELECT Id FROM ManagedContent WHERE ContentTypeFullyQualifiedName = '
                + '\'sfdc_cms__image\' LIMIT 200';
            Integer n = queryAsUser(soql).size();
            Map<String, Object> r;
            if (n >= MIN_IMAGES_FOR_SWAP) {
                r = row('img', 'Images for personalization', 'ok', n + '+ images available to swap');
            } else if (n == 1) {
                r = row('img', 'Images for personalization', 'warn',
                    '1 image only -- add more to personalize images (need ' + MIN_IMAGES_FOR_SWAP + '+)');
            } else {
                r = row('img', 'Images for personalization', 'warn',
                    'no CMS images -- image dynamic content unavailable until you add some');
            }
            r.put('count', n);
            return r;
        } catch (Exception e) {
            Map<String, Object> r = row('img', 'Images for personalization', 'warn', 'could not count images');
            r.put('count', 0);
            return r;
        }
    }

    private static Map<String, Object> row(String key, String label, String status, String detail) {
        return new Map<String, Object>{ 'key' => key, 'label' => label, 'status' => status, 'detail' => detail };
    }

    // Data Cloud ready = segments exist (DC provisioned AND the running user can read them) AND the
    // user holds a DC permset family. Modern (DataCloud*) OR legacy (CDPAdmin/GenieAdmin +
    // GenieUserEnhancedSecurity); many SDOs ship legacy-only, so treating either family as canonical
    // avoids false-failing them. MarketSegment is inline-SOQL-able (no callout).
    private static Map<String, Object> probeDataCloud() {
        try {
            Set<String> held = new Set<String>();
            for (PermissionSetAssignment psa : [
                SELECT PermissionSet.Name FROM PermissionSetAssignment
                WHERE AssigneeId = :UserInfo.getUserId()
                  AND (PermissionSet.Name LIKE '%DataCloud%' OR PermissionSet.Name LIKE '%CDP%'
                       OR PermissionSet.Name LIKE '%Genie%') ]) {
                held.add(psa.PermissionSet.Name);
            }
            Boolean modern = held.contains('DataCloudAdmin') || held.contains('DataCloudUserBase')
                || held.contains('DataCloudIdentityResolutionAccess');
            Boolean legacyAdmin = held.contains('CDPAdmin') || held.contains('GenieAdmin');
            Boolean legacyUser = held.contains('GenieUserEnhancedSecurity');
            Boolean permsetOk = modern || (legacyAdmin && legacyUser);
            Boolean permsetPartial = !permsetOk && (legacyAdmin || legacyUser || !held.isEmpty());

            Integer segCount = 0;
            Boolean dcQueryable = true;
            try { segCount = [SELECT COUNT() FROM MarketSegment]; }
            catch (Exception qe) { dcQueryable = false; }

            if (!dcQueryable) {
                return row('dc', 'Data Cloud reachable', 'fail', 'not provisioned on this org');
            }
            if (permsetOk) {
                return row('dc', 'Data Cloud reachable', 'ok', segCount + ' segments, permsets assigned');
            }
            if (permsetPartial) {
                return row('dc', 'Data Cloud reachable', 'warn', segCount + ' segments, partial permset family');
            }
            return row('dc', 'Data Cloud reachable', 'warn', segCount + ' segments, no DC permsets on running user');
        } catch (Exception e) {
            return row('dc', 'Data Cloud reachable', 'fail', e.getMessage());
        }
    }

    // CMS workspaces for the read-only browse dropdown. ManagedContentSpace.Name is inline-SOQL-able
    // (verified SIC2025 v66; no callout), so this is cacheable. Read-only; the panel does not write.
    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getWorkspaces() {
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        for (ManagedContentSpace s : [SELECT Id, Name FROM ManagedContentSpace ORDER BY Name]) {
            out.add(new Map<String, Object>{ 'id' => s.Id, 'name' => s.Name });
        }
        return out;
    }

    // ── Tab 2 inventory: CMS content (brands/assets) via the user-session query. Optional type
    // filter (a content-type API name); null/blank = all types.
    @AuraEnabled
    public static List<Map<String, Object>> getContentInventory(String contentType) {
        String whereClause = String.isBlank(contentType) ? ''
            : (' WHERE ContentTypeFullyQualifiedName = \'' + String.escapeSingleQuotes(contentType) + '\'');
        String soql = 'SELECT Name, ContentKey, ContentTypeFullyQualifiedName FROM ManagedContent'
            + whereClause + ' ORDER BY Name LIMIT 100';
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        for (Object o : queryAsUser(soql)) {
            Map<String, Object> mc = (Map<String, Object>) o;
            out.add(new Map<String, Object>{
                'name' => str(mc, 'Name'), 'contentKey' => str(mc, 'ContentKey'),
                'type' => str(mc, 'ContentTypeFullyQualifiedName')
            });
        }
        return out;
    }

    // ── Tab 2: the models the agent's prompt templates actually use. "selected" mirrors each
    // GenAiPromptTemplate's active-version <primaryModel> (the model that step runs on), sourced from
    // the template metadata this package ships/retrieves. We deliberately do NOT ship a hardcoded
    // "available models" list: verified on SIC2025 (v66) that there is NO queryable catalog of the
    // SF-managed foundation models -- the connect/ai/models + connect/einstein/llm/models REST
    // endpoints 404, and AiModel / AIModelConfig / ConfiguredConfig / GenAiModelConfig are not
    // sObjects here (AiExternalModelReference exists but lists only BYO/custom models, none on this
    // org). The catalog also churns (deprecations/re-routes), so a static list would mislead. The LWC
    // instead deep-links to Setup > Einstein > Models as the authoritative, live catalog.
    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getModels() {
        List<Map<String, Object>> selected = new List<Map<String, Object>>{
            new Map<String, Object>{ 'step' => 'Plan email structure',
                'template' => 'AuraPoc_PlanEmailStructureV2', 'model' => 'sfdc_ai__DefaultBedrockAnthropicClaude45Sonnet' },
            new Map<String, Object>{ 'step' => 'Write per-cell copy (FillSlot)',
                'template' => 'AuraPoc_FillSlot', 'model' => 'sfdc_ai__DefaultBedrockAnthropicClaude45Haiku' }
        };
        // Setup now lives on the my.salesforce-setup.com domain, not my.salesforce.com; the model
        // picker/catalog is under Einstein Prompt Studio (verified SIC2025). Derive the setup host
        // from the org My Domain host so this resolves per-org.
        String orgUrl = URL.getOrgDomainUrl().toExternalForm();       // https://<my>.my.salesforce.com
        String setupUrl = orgUrl.replace('.my.salesforce.com', '.my.salesforce-setup.com')
            + '/lightning/setup/EinsteinPromptStudio/home';
        return new Map<String, Object>{
            'selected' => selected,
            'catalogSetupUrl' => setupUrl
        };
    }

    // ── Tab 2 "Run full test" ── the definitive 3-leg verdict (JWT mint + CMS REST + Aura session)
    // the user session can't do itself. Delegates to the existing server-side diagnostic. Callout →
    // not cacheable. Never returns the token.
    @AuraEnabled
    public static Map<String, Object> runFullTest() {
        AuthDiagnosticAction.Result r = AuthDiagnosticAction.run(
            new List<AuthDiagnosticAction.Request>{ new AuthDiagnosticAction.Request() })[0];
        return new Map<String, Object>{
            'success' => r.success,
            'tokenMinted' => r.tokenMinted,
            'auraSessionReady' => r.auraSessionReady,
            'emailWorkspaceCount' => r.emailWorkspaceCount,
            'workspacesJson' => r.workspacesJson,
            'recommendedWorkspaceId' => r.recommendedWorkspaceId,
            'diagnostic' => r.diagnostic
        };
    }

    // ── Dry-run PLAN PREVIEW (Feature 3) ── show which slot(s) WILL bind for a candidate axis
    // BEFORE the user approves the agent's write. Runs the SAME pipeline the agent runs
    // (Read -> Assemble(update) -> Validate) with a synthesized single-axis plan; NO LLM, NO write.
    // Copy text is irrelevant to binding, so copyJson is a stub. Returns will-bind slots, the
    // decision list, validity, and any "dropped: field not in graph"/ineligible warnings.
    //
    // contentKey  = MC... or 20Y... (resolved by ReadDynamicEmailAction)
    // slotNumbers = "3" or "3,4" -- the slot(s) to preview personalizing
    // fieldTerm   = natural field word, e.g. "industry" (the planner/Assemble resolve to a fieldApiName)
    // valuesCsv   = optional "Healthcare, Technology, Finance" -> one Equals decision each; blank = HasValue
    // graphApiName= optional; blank = auto-resolve the org's data graph
    @AuraEnabled
    public static Map<String, Object> previewPlan(String contentKey, String slotNumbers,
                                                  String fieldTerm, String valuesCsv, String graphApiName) {
        Map<String, Object> out = new Map<String, Object>{
            'ok' => false, 'valid' => false, 'willBind' => new List<Object>(),
            'decisions' => new List<Object>(), 'warnings' => new List<Object>(),
            'planSummary' => '', 'error' => '' };
        try {
            if (String.isBlank(contentKey)) { out.put('error', 'No email content key.'); return out; }
            if (String.isBlank(slotNumbers)) { out.put('error', 'Pick at least one slot to preview.'); return out; }
            if (String.isBlank(fieldTerm)) { out.put('error', 'Enter a field to personalize by (e.g. industry).'); return out; }

            // 1. Read the real blocks (resolver handles MC.../20Y...).
            ReadDynamicEmailAction.Request rr = new ReadDynamicEmailAction.Request();
            rr.contentKey = contentKey;
            ReadDynamicEmailAction.Result rres =
                ReadDynamicEmailAction.readDynamicEmail(new List<ReadDynamicEmailAction.Request>{ rr })[0];
            if (String.isNotBlank(rres.errorMessage)) { out.put('error', rres.errorMessage); return out; }
            String blocksJson = String.isBlank(rres.blocksJson) ? '[]' : rres.blocksJson;

            // 2. Resolve the data graph + field catalog (same source the agent uses).
            DataGraphDetailsAction.Request gr = new DataGraphDetailsAction.Request();
            gr.graphApiName = graphApiName;  // blank => auto
            DataGraphDetailsAction.Result gres =
                DataGraphDetailsAction.getDataGraphDetails(new List<DataGraphDetailsAction.Request>{ gr })[0];
            if (!gres.success && String.isBlank(gres.fieldsJson)) {
                out.put('error', String.isNotBlank(gres.errorMessage) ? gres.errorMessage
                    : 'No data graph is available to personalize from.'); return out;
            }
            String resolvedGraph = gres.resolvedGraphApiName;
            String fieldsJson = String.isBlank(gres.fieldsJson) ? '[]' : gres.fieldsJson;

            // 3a. Pre-filter requested slots against the read's ELIGIBLE set, so an image /
            //     already-personalized / out-of-range slot is reported as ineligible (matching what
            //     the agent surfaces) instead of being force-bound. eligibleSlotsJson = [{slot,type,...}].
            Set<Integer> eligibleSet = new Set<Integer>();
            Map<Integer, String> eligibleType = new Map<Integer, String>();
            if (String.isNotBlank(rres.eligibleSlotsJson) && rres.eligibleSlotsJson != '[]') {
                for (Object o : (List<Object>) JSON.deserializeUntyped(rres.eligibleSlotsJson)) {
                    if (!(o instanceof Map<String, Object>)) { continue; }
                    Map<String, Object> es = (Map<String, Object>) o;
                    if (es.get('slot') == null) { continue; }   // e.g. the subject_preheader component
                    Integer sn = Integer.valueOf(String.valueOf(es.get('slot')));
                    eligibleSet.add(sn);
                    eligibleType.put(sn, String.valueOf(es.get('type')));
                }
            }

            // 3b. Synthesize the plan. Slot keys are exactly "slot<N>" so Assemble's exact-slot binding
            //     resolves them against the real blocks. Emit ONE personalization per value (a proper
            //     single-value Equals, matching the real planner) so Validate is satisfied; blank values
            //     => one HasValue presence axis.
            List<Object> slots = new List<Object>();
            List<String> slotKeys = new List<String>();
            for (String sRaw : slotNumbers.split(',')) {
                String s = sRaw.trim();
                if (String.isBlank(s) || !s.isNumeric()) { continue; }
                Integer sn = Integer.valueOf(s);
                if (!eligibleSet.contains(sn)) {
                    ((List<Object>) out.get('warnings')).add('Slot ' + sn
                        + ' is not eligible (image, already personalized, or out of range) -- it will be skipped.');
                    continue;
                }
                String key = 'slot' + s;
                slotKeys.add(key);
                slots.add(new Map<String, Object>{ 'key' => key,
                    'type' => (eligibleType.containsKey(sn) ? eligibleType.get(sn) : 'paragraph'),
                    'goal' => 'preview' });
            }
            if (slotKeys.isEmpty()) {
                out.put('planSummary', 'No eligible slot to preview.');
                out.put('ok', true); return out;   // honest empty preview, not an error
            }

            List<Object> values = new List<Object>();
            if (String.isNotBlank(valuesCsv)) {
                for (String v : valuesCsv.split(',')) { if (String.isNotBlank(v.trim())) values.add(v.trim()); }
            }
            List<Object> pers = new List<Object>();
            List<String> decisionNames = new List<String>();
            if (values.isEmpty()) {
                pers.add(new Map<String, Object>{ 'name' => 'preview_has_value', 'label' => fieldTerm,
                    'scope' => 'RecipientAccount', 'fieldApiName' => fieldTerm,
                    'matchType' => 'HasValue', 'appliesToSlots' => slotKeys });
                decisionNames.add('preview_has_value');
            } else {
                Integer i = 0;
                for (Object v : values) {
                    String nm = 'preview_' + (i++);
                    pers.add(new Map<String, Object>{ 'name' => nm, 'label' => fieldTerm + ' = ' + v,
                        'scope' => 'RecipientAccount', 'fieldApiName' => fieldTerm,
                        'matchType' => 'Equals', 'value' => v, 'appliesToSlots' => slotKeys });
                    decisionNames.add(nm);
                }
            }
            Map<String, Object> plan = new Map<String, Object>{ 'slots' => slots, 'personalizations' => pers };

            // Minimal copy stub. Assemble's copy-coverage check needs a byPersonalization entry keyed by
            // EACH decision name for every slot it applies to. Binding does not depend on copy text.
            Map<String, Object> copyBySlot = new Map<String, Object>();
            for (String k : slotKeys) {
                Map<String, Object> byPers = new Map<String, Object>();
                for (String dn : decisionNames) { byPers.put(dn, 'preview'); }
                copyBySlot.put(k, new Map<String, Object>{ 'default' => 'preview', 'byPersonalization' => byPers });
            }
            String copyJson = JSON.serialize(new Map<String, Object>{ 'copyBySlot' => copyBySlot });

            // 4. Assemble in UPDATE mode (emailBlocksJson present => derives slot bindings).
            AssembleContentPlanAction.Request ar = new AssembleContentPlanAction.Request();
            ar.structurePlanJson = JSON.serialize(plan);
            ar.copyJson = copyJson;
            ar.resolvedGraphApiName = resolvedGraph;
            ar.availableFieldsJson = fieldsJson;
            ar.emailBlocksJson = blocksJson;
            ar.updateTargetKey = rres.contentKey;   // the resolved MC key
            AssembleContentPlanAction.Result ares =
                AssembleContentPlanAction.assembleContentPlan(new List<AssembleContentPlanAction.Request>{ ar })[0];
            if (String.isNotBlank(ares.errorMessage)) { out.put('error', ares.errorMessage); }
            out.put('planSummary', ares.planSummary == null ? '' : ares.planSummary);
            if (String.isNotBlank(ares.personalizationNote)) {
                ((List<Object>) out.get('warnings')).add(ares.personalizationNote);
            }

            // which slots bound
            List<Object> willBind = new List<Object>();
            if (String.isNotBlank(ares.slotBindingsJson) && ares.slotBindingsJson != '[]') {
                for (Object b : (List<Object>) JSON.deserializeUntyped(ares.slotBindingsJson)) {
                    willBind.add(b);
                }
            }
            out.put('willBind', willBind);

            // decision list for display
            out.put('decisions', values.isEmpty()
                ? new List<Object>{ 'has ' + fieldTerm + ' (single presence variant)' }
                : (List<Object>) values);

            // 5. Validate (same gate the agent hits before the confirm dialog).
            ValidateContentPlanAction.Request vr = new ValidateContentPlanAction.Request();
            vr.elementsJson = ares.elementsJson;
            vr.personalizationsJson = ares.personalizationsJson;
            vr.resolvedGraphApiName = resolvedGraph;
            vr.availableFieldsJson = fieldsJson;
            vr.emailBlocksJson = blocksJson;
            vr.targetSlotsJson = ares.slotBindingsJson;
            vr.updateTargetKey = rres.contentKey;
            ValidateContentPlanAction.Result vres =
                ValidateContentPlanAction.validateContentPlan(new List<ValidateContentPlanAction.Request>{ vr })[0];
            out.put('valid', vres.isValid == true);
            if (String.isNotBlank(vres.issuesJson) && vres.issuesJson != '[]') {
                for (Object iss : (List<Object>) JSON.deserializeUntyped(vres.issuesJson)) {
                    ((List<Object>) out.get('warnings')).add(iss);
                }
            }
            out.put('ok', true);
        } catch (Exception e) {
            out.put('error', e.getTypeName() + ': ' + e.getMessage());
        }
        return out;
    }
}
