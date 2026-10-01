// Deterministically merges Stage 1 (Plan Email Structure -- slots + personalization needs)
// and Stage 2 (Write Email Copy -- the actual words) into the elementsJson/personalizationsJson
// shape Build Dynamic Email expects. No LLM callout here -- every mapping below (scope ->
// criteriaObjectApiName/criteriaPath, matchType -> criteriaType, slot type -> blockDefinition)
// is a fixed lookup, not a model decision, per the "LLM only for planning and creative text,
// everything else deterministic" rule this whole build follows.
//
// Ported from the marketing toolkit's own deterministic DC pipeline (docs/dynamic-content.md
// SS5): Salesforce PersonalizationDecisions within ONE PersonalizationPoint are evaluated as
// MUTUALLY-EXCLUSIVE alternatives (priority-ordered), not independently-combinable facts. Two
// unrelated axes (e.g. industry AND has-first-name) dumped into one PP's decision list produces
// a confusing, semantically wrong rule set -- confirmed live. The toolkit's fix, ported here: one
// PersonalizationPoint PER independent axis, grouped by (fieldApiName, scope), capped at 3 PPs /
// 10 decisions per PP to match the toolkit's own silent install caps (project_dc_topology_caps).
public with sharing class AssembleContentPlanAction {

    public class Request {
        @InvocableVariable(label='Structure Plan JSON' required=true)
        public String structurePlanJson;

        @InvocableVariable(label='Copy JSON' required=true)
        public String copyJson;

        // The data graph actually resolved for this session (auto-detected when the org has
        // exactly one, or user-chosen when it has several). Blank when unresolved. Deterministic
        // gate input -- assembly refuses to emit personalization wired to a graph that was never
        // resolved, instead of letting a null-graph plan reach build (the failure this fixes).
        @InvocableVariable(label='Resolved Data Graph API Name')
        public String resolvedGraphApiName;

        // Flattened field catalog for the resolved graph (from Get Data Graph Details:
        // [{dmoName, fieldApiName, ...}]). Any personalization referencing a (dmo, field) absent
        // here is dropped with a note instead of shipped as dead dynamic content.
        @InvocableVariable(label='Available Fields JSON')
        public String availableFieldsJson;

        // Deterministic graph count from Get Data Graph Details: 0 = none configured (degrade to
        // a plain email), 1 = resolved, >1 = ambiguous (must be chosen before personalizing).
        @InvocableVariable(label='Data Graph Count')
        public Integer dataGraphCount;

        // Real graph names to offer the user when dataGraphCount > 1 and none is resolved yet.
        @InvocableVariable(label='Available Graph Names JSON')
        public String availableGraphNamesJson;
        // UPDATE mode: the existing email's blocks (ReadDynamicEmailAction.blocksJson --
        // [{def, text, contentKey, personalized}] in document order). When non-empty, this is an
        // update to an existing email: each personalization target is stamped with the REAL block's
        // matchText (heading/paragraph) or matchContentKey (image), mapped by (type, ordinal), so
        // UpdateDynamicEmailAction matches against actual blocks -- never LLM-invented text. Empty =
        // a normal new-email build (no stamping).
        @InvocableVariable(label='Existing Blocks JSON')
        public String emailBlocksJson;

        // UPDATE mode signal: the content key of the existing email being updated (base_update_targetKey).
        // Non-blank => this is an update. Used ONLY to fail loud when an update reaches assembly without
        // its read blocks (the Theory-A silent-[] path): without it, blank emailBlocksJson silently skips
        // slot-binding derivation and leaves slotBindingsJson='[]', which Validate later rejects as
        // "no slots were chosen" with no diagnosable cause.
        @InvocableVariable(label='Update Target Key')
        public String updateTargetKey;
    }

    public class Result {
        @InvocableVariable(label='Success')
        public Boolean success;

        @InvocableVariable(label='Title')
        public String title;

        @InvocableVariable(label='Subject Line')
        public String subjectLine;

        @InvocableVariable(label='Preheader')
        public String preheader;

        // Deterministic slug + short unique suffix -- previously only ever LLM-filled at
        // build time, which meant Build Dynamic Email could never be called without an LLM
        // turn present to supply it. Generated here instead, alongside the rest of the
        // deterministically-assembled plan.
        @InvocableVariable(label='Url Name')
        public String urlName;

        @InvocableVariable(label='Elements JSON')
        public String elementsJson;

        // JSON array of {ppName, ppLabel, decisionsJson, targetsJson} -- one entry per
        // independent personalization axis. Null/omitted when the structure plan had no
        // personalizations. Pass straight through to Build Dynamic Email's personalizationsJson.
        @InvocableVariable(label='Personalizations JSON')
        public String personalizationsJson;

        // UPDATE mode: derived {elementKey, slot} bindings mapping each surviving personalization
        // axis to an EXISTING read-block slot -- computed HERE (not by an LLM tool the model never
        // called). Each axis binds to the first eligible slot of its block type; axes with no
        // eligible slot are dropped (harmlessly discards over-planned axes). "[]" for a new build.
        @InvocableVariable(label='Slot Bindings JSON')
        public String slotBindingsJson;

        @InvocableVariable(label='Error Message')
        public String errorMessage;

        // Human-readable note about any personalization that was dropped or degraded (no data
        // graph configured, or a requested field not in the resolved graph). Empty when nothing
        // was dropped. Surfaced verbatim in the pre-approval summary so the downgrade is never
        // silent -- the caller must show this to the user.
        @InvocableVariable(label='Personalization Note')
        public String personalizationNote;

        // True only when personalization was requested but the org has multiple data graphs and
        // none is resolved yet -- the caller must ask the user which graph, look it up, then
        // re-plan. Distinct from the plain-email degrade (dataGraphCount == 0), which proceeds
        // without asking. Never true on the plain (no-personalization) path.
        @InvocableVariable(label='Needs Graph Choice')
        public Boolean needsGraphChoice;

        // Deterministic human summary of the personalization for the pre-build confirm dialog:
        // counts of PersonalizationPoints (PPs), variants/decisions (OPs), target slots, and the
        // backing data graph. "No personalization (static email)." on the plain path.
        @InvocableVariable(label='Plan Summary')
        public String planSummary;
    }

    public class AssembleException extends Exception {}

    // Flatten the resolved graph's field catalog into a set of "dmoName|fieldApiName" keys so a
    // requested personalization field can be checked for real existence in O(1). Empty set when
    // no catalog was passed -- callers treat "empty catalog" as "cannot verify", not "verified".
    private static Set<String> buildAvailableFieldSet(String availableFieldsJson) {
        Set<String> out = new Set<String>();
        if (String.isBlank(availableFieldsJson)) { return out; }
        try {
            for (Object o : (List<Object>) JSON.deserializeUntyped(availableFieldsJson)) {
                Map<String, Object> f = (Map<String, Object>) o;
                out.add(String.valueOf(f.get('dmoName')) + '|' + String.valueOf(f.get('fieldApiName')));
            }
        } catch (Exception ignore) { /* malformed catalog -> treated as unverifiable, not fatal */ }
        return out;
    }

    // Map fieldApiName -> dataType (Text / Number / DateTime / ...) from the graph catalog, so a
    // decision can carry its field's type and the criteria builder can emit a Number/Date predicate
    // instead of always Text (the DC platform rejects a Text predicate on a numeric/date field:
    // "Predicate type Text is not compatible with the data type of <field>").
    private static Map<String, String> buildFieldDataTypeMap(String availableFieldsJson) {
        Map<String, String> out = new Map<String, String>();
        if (String.isBlank(availableFieldsJson)) { return out; }
        try {
            for (Object o : (List<Object>) JSON.deserializeUntyped(availableFieldsJson)) {
                Map<String, Object> f = (Map<String, Object>) o;
                Object fn = f.get('fieldApiName'); Object dt = f.get('dataType');
                if (fn != null && dt != null) { out.put(String.valueOf(fn), String.valueOf(dt)); }
            }
        } catch (Exception ignore) { /* malformed catalog -> no types, defaults to Text downstream */ }
        return out;
    }

    // Human labels for a list of requested personalizations, for the drop/degrade note.
    private static String describeAxes(List<Object> personalizations) {
        List<String> labels = new List<String>();
        for (Object pObj : personalizations) {
            Map<String, Object> p = (Map<String, Object>) pObj;
            labels.add(p.get('label') != null ? String.valueOf(p.get('label')) : String.valueOf(p.get('fieldApiName')));
        }
        return labels.isEmpty() ? '(none)' : String.join(labels, ', ');
    }

    // Single source of truth on BuildDynamicEmailAction -- this class used to keep its own
    // private copies of both caps. Raising the build-time cap (after live scale-testing showed
    // 1-6 PersonalizationPoints all succeed cheaply) silently did nothing here, since assembly
    // runs BEFORE build and was still hard-rejecting anything past the old value of 3.
    private static Integer maxPpsPerEmail() { return BuildDynamicEmailAction.MAX_PPS_PER_EMAIL; }
    private static Integer maxDecisionsPerPp() { return BuildDynamicEmailAction.MAX_DECISIONS_PER_PP; }

    private static final Map<String, String> SCOPE_TO_OBJECT = new Map<String, String>{
        'Recipient' => 'UnifiedIndividual__dlm',
        'RecipientAccount' => 'ssot__Account__dlm',
        'RecipientAddress' => 'ssot__ContactPointAddress__dlm',
        'RecipientProfile' => 'ssot__Individual__dlm',
        'RecipientEmailEngagement' => 'ssot__EmailEngagementScore__dlm',
        'RecipientLead' => 'ssot__Lead__dlm'
    };

    private static final Map<String, String> SCOPE_TO_PATH = new Map<String, String>{
        'RecipientAccount' => 'ACCOUNT_PATH',
        'RecipientAddress' => 'CONTACT_POINT_ADDRESS_PATH',
        'RecipientProfile' => 'INDIVIDUAL_PATH',
        'RecipientEmailEngagement' => 'EMAIL_ENGAGEMENT_PATH',
        'RecipientLead' => 'LEAD_PATH'
    };

    private static final Map<String, String> MATCH_TYPE_TO_CRITERIA_TYPE = new Map<String, String>{
        'HasValue' => 'has_value', 'Equals' => 'equals', 'In' => 'in'
    };

    // Sentinel blockDefinition for the subject-line + preheader COMPONENT (not a real block). A
    // subject/preheader personalization targets email metadata, so its operation carries NO targetId
    // and its variant body is {subjectLine, preheader} (captured from a real UI example). This sentinel
    // flows through the same plan/assemble/validate/wire pipeline as a block def, and every block-lookup
    // path guards against it (there is no block UUID to resolve).
    public static final String SUBJECT_PREHEADER_DEF = 'sfdc_cms__subjectPreheader';

    private static final Map<String, String> SLOT_TYPE_TO_BLOCK_DEFINITION = new Map<String, String>{
        'heading' => 'lightning/heading', 'paragraph' => 'lightning/paragraph', 'button' => 'lightning/actionButton',
        // Image DC: an image slot is personalized by SWAPPING the asset per decision (a contentKey
        // variant resolved from assetName), not by text. Build/Update already consume {assetName}
        // variant objects; unlocking image here lets an image slot be planned/bound like a text one.
        'image' => 'lightning/image',
        // Subject/preheader DC: the email's subject line + preheader personalized TOGETHER as one
        // component (update path only). No block, no slot number -- see SUBJECT_PREHEADER_DEF.
        'subject_preheader' => 'sfdc_cms__subjectPreheader'
    };

    // Region -> 2-letter state-code sets. This is a DETERMINISTIC lookup, not a creative decision,
    // so it lives here per the "LLM only for creative text, everything else deterministic" rule --
    // NOT delegated to the plan LLM (confirmed live: GPT-4o-mini emitted matchType "In" for a
    // West/East region split but left the values array EMPTY, which failed validation and stalled
    // the whole build). The LLM now only has to NAME the region; resolveStateProvinceInValues
    // expands it to codes.
    private static final Map<String, List<String>> REGION_TO_STATE_CODES = new Map<String, List<String>>{
        'west' => new List<String>{ 'CA', 'WA', 'OR', 'NV', 'AZ' },
        'east' => new List<String>{ 'NY', 'NJ', 'MA', 'PA', 'FL', 'GA' },
        'central' => new List<String>{ 'IL', 'TX', 'CO', 'KS' }
    };

    private static final Map<String, String> US_STATE_NAME_TO_CODE = new Map<String, String>{
        'alabama'=>'AL','alaska'=>'AK','arizona'=>'AZ','arkansas'=>'AR','california'=>'CA','colorado'=>'CO',
        'connecticut'=>'CT','delaware'=>'DE','district of columbia'=>'DC','florida'=>'FL','georgia'=>'GA',
        'hawaii'=>'HI','idaho'=>'ID','illinois'=>'IL','indiana'=>'IN','iowa'=>'IA','kansas'=>'KS','kentucky'=>'KY',
        'louisiana'=>'LA','maine'=>'ME','maryland'=>'MD','massachusetts'=>'MA','michigan'=>'MI','minnesota'=>'MN',
        'mississippi'=>'MS','missouri'=>'MO','montana'=>'MT','nebraska'=>'NE','nevada'=>'NV','new hampshire'=>'NH',
        'new jersey'=>'NJ','new mexico'=>'NM','new york'=>'NY','north carolina'=>'NC','north dakota'=>'ND','ohio'=>'OH',
        'oklahoma'=>'OK','oregon'=>'OR','pennsylvania'=>'PA','rhode island'=>'RI','south carolina'=>'SC',
        'south dakota'=>'SD','tennessee'=>'TN','texas'=>'TX','utah'=>'UT','vermont'=>'VT','virginia'=>'VA',
        'washington'=>'WA','west virginia'=>'WV','wisconsin'=>'WI','wyoming'=>'WY'
    };

    // ---- Deterministic canonical-value catalog for common personalization fields ----------------
    // Mapping a user's phrasing to the exact value a DC decision needs is a FIXED lookup, not a
    // creative choice, so it lives here rather than trusting the plan LLM to emit exact values
    // (confirmed live: GPT-4o-mini emitted "In" with an empty state array, and reaches for loose
    // industry/tier synonyms). The LLM names the axis + a rough value; this normalizes it to the
    // canonical form the data actually stores. Fields whose canonical set isn't verified for this
    // org (country, title, etc.) are simply trimmed and passed through -- never force a canonical
    // that might not match the data. Industry/Account-Type lists come from the same real-usage
    // survey the plan prompt documents; state uses standard 2-letter codes.
    private static final List<String> INDUSTRY_CANONICAL = new List<String>{
        'Education','Healthcare','Technology','Retail','Finance','Manufacturing','Government',
        'Insurance','Communications','Hospitality','Consulting','Transportation','Environmental'
    };
    private static final Map<String, String> INDUSTRY_SYNONYM = new Map<String, String>{
        'tech'=>'Technology','it'=>'Technology','information technology'=>'Technology','software'=>'Technology','saas'=>'Technology',
        'health'=>'Healthcare','health care'=>'Healthcare','medical'=>'Healthcare','pharma'=>'Healthcare','life sciences'=>'Healthcare',
        'fin'=>'Finance','financial'=>'Finance','financial services'=>'Finance','banking'=>'Finance','fintech'=>'Finance',
        'edu'=>'Education','higher ed'=>'Education',
        'gov'=>'Government','public sector'=>'Government',
        'mfg'=>'Manufacturing','industrial'=>'Manufacturing',
        'telecom'=>'Communications','telecommunications'=>'Communications','media'=>'Communications',
        'logistics'=>'Transportation','transport'=>'Transportation'
    };
    private static final List<String> ACCOUNT_TYPE_CANONICAL = new List<String>{
        'Mid-Market','Enterprise','Small Business','Partner','Other'
    };
    private static final Map<String, String> ACCOUNT_TYPE_SYNONYM = new Map<String, String>{
        'smb'=>'Small Business','small'=>'Small Business','small-business'=>'Small Business',
        'midmarket'=>'Mid-Market','mid market'=>'Mid-Market','mm'=>'Mid-Market',
        'ent'=>'Enterprise','large'=>'Enterprise','large enterprise'=>'Enterprise',
        'channel'=>'Partner','reseller'=>'Partner'
    };

    // Which catalog (if any) applies to a field, detected from its API name.
    private static String fieldCatalog(String fieldApiName) {
        String f = (fieldApiName == null ? '' : fieldApiName).toLowerCase();
        if (f.contains('stateprovince')) { return 'STATE'; }
        if (f.contains('industry')) { return 'INDUSTRY'; }
        if (f.contains('accounttype')) { return 'ACCOUNT_TYPE'; }
        return '';   // country/title/etc. -> no catalog, trim + passthrough
    }

    // Normalize a single categorical value to its canonical form (exact known value or synonym).
    // Unknown values are trimmed and returned as-is, never dropped -- the org may hold a custom value.
    private static String canonicalizeValue(String catalog, String raw) {
        if (String.isBlank(raw)) { return raw; }
        String key = raw.trim().toLowerCase();
        if (catalog == 'INDUSTRY') {
            if (INDUSTRY_SYNONYM.containsKey(key)) { return INDUSTRY_SYNONYM.get(key); }
            for (String c : INDUSTRY_CANONICAL) { if (c.toLowerCase() == key) { return c; } }
        } else if (catalog == 'ACCOUNT_TYPE') {
            if (ACCOUNT_TYPE_SYNONYM.containsKey(key)) { return ACCOUNT_TYPE_SYNONYM.get(key); }
            for (String c : ACCOUNT_TYPE_CANONICAL) { if (c.toLowerCase() == key) { return c; } }
        }
        return raw.trim();
    }

    // Resolve the "In" values list for a decision. STATE expands region names ("West"/"East"/
    // "Central") and full state names to 2-letter codes, passes explicit codes through uppercased,
    // and -- if the plan left values empty -- infers the region from the decision name/label (e.g.
    // "region_west_coast"). Other catalogs canonicalize each value. Empty result only when nothing
    // could be resolved, in which case validation still fails loud as before.
    private static List<Object> resolveInValues(String catalog, String name, String label, List<Object> rawValues) {
        List<Object> out = new List<Object>();
        Set<String> seen = new Set<String>();
        if (rawValues != null) {
            for (Object v : rawValues) {
                String s = String.valueOf(v).trim();
                if (String.isBlank(s)) { continue; }
                if (catalog == 'STATE') {
                    String lc = s.toLowerCase();
                    if (REGION_TO_STATE_CODES.containsKey(lc)) {
                        for (String code : REGION_TO_STATE_CODES.get(lc)) { if (seen.add(code)) { out.add(code); } }
                    } else if (US_STATE_NAME_TO_CODE.containsKey(lc)) {
                        String code = US_STATE_NAME_TO_CODE.get(lc);
                        if (seen.add(code)) { out.add(code); }
                    } else {
                        String code = s.toUpperCase();
                        if (seen.add(code)) { out.add(code); }
                    }
                } else {
                    String cv = canonicalizeValue(catalog, s);
                    if (seen.add(cv.toLowerCase())) { out.add(cv); }
                }
            }
        }
        if (out.isEmpty() && catalog == 'STATE') {
            String hay = ((name == null ? '' : name) + ' ' + (label == null ? '' : label)).toLowerCase();
            for (String region : REGION_TO_STATE_CODES.keySet()) {
                if (hay.contains(region)) {
                    for (String code : REGION_TO_STATE_CODES.get(region)) { if (seen.add(code)) { out.add(code); } }
                }
            }
        }
        return out;
    }

    // "ssot__IndustryId__c" -> "Industry", "ssot__FirstName__c" -> "FirstName" -- best-effort
    // human label for the PP name/label seed; Build Dynamic Email's own uniquePpName() sanitizes
    // and uniquifies further at build time, so this only needs to be reasonable, not perfect.
    private static String humanizeFieldName(String fieldApiName) {
        String f = String.isBlank(fieldApiName) ? 'Field' : fieldApiName;
        if (f.startsWith('ssot__')) { f = f.substring(6); }
        if (f.endsWith('__c')) { f = f.substring(0, f.length() - 3); }
        if (f.endsWith('Id') && f.length() > 2) { f = f.substring(0, f.length() - 2); }
        return String.isBlank(f) ? 'Field' : f;
    }

    // Deterministic urlName generation -- lowercase, non-alphanumerics collapsed to single
    // hyphens, truncated, plus a short random suffix for uniqueness (same collision concern
    // BuildDynamicEmailAction.uniquePpName() already solves for PersonalizationPoint names --
    // two builds with similar titles must not collide on urlName within a CMS workspace).
    private static String slugify(String text) {
        String base = String.isBlank(text) ? 'email' : text.toLowerCase();
        base = base.replaceAll('[^a-z0-9]+', '-');
        base = base.replaceAll('^-+', '').replaceAll('-+$', '');
        if (String.isBlank(base)) { base = 'email'; }
        if (base.length() > 60) { base = base.substring(0, 60); }
        Blob b = Crypto.generateAesKey(128);
        String suffix = EncodingUtil.convertToHex(b).substring(0, 6);
        return base + '-' + suffix;
    }

    @InvocableMethod(label='Assemble Content Plan' description='Deterministically merges a structure plan (from Plan Email Structure) and its written copy (from Write Email Copy) into the elementsJson/personalizationsJson shape Build Dynamic Email expects -- one PersonalizationPoint per independent personalization axis. Makes no callouts and creates nothing.')
    public static List<Result> assembleContentPlan(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result res = new Result();
            // Default non-null up front -- a null String/Boolean output binds to a null
            // agent-script variable (same hazard DataGraphDetailsAction documents), which then
            // breaks downstream prompt/merge resolution. CRITICAL: personalizationsJson/elementsJson
            // MUST default to "" -- if assemble throws (e.g. too many decisions), the catch returns
            // without assigning them; a null then overwrites the agent's "" default, and the update
            // gate's `!= ""` check passes on null -> the tool fires with a null required input ->
            // REQUIRED_FIELD_MISSING (confirmed live). Defaulting here makes a thrown assemble leave
            // them "" so the gate correctly stays closed.
            res.personalizationNote = '';
            res.needsGraphChoice = false;
            res.personalizationsJson = '';
            res.elementsJson = '';
            res.slotBindingsJson = '[]';
            res.title = ''; res.subjectLine = ''; res.preheader = ''; res.urlName = '';
            // CRITICAL: errorMessage MUST default to '' -- on a SUCCESSFUL assemble it is otherwise
            // never assigned and stays null. The pipeline binds base_error_pipeline = errorMessage, and
            // the stall check `base_error_pipeline != ""` treats null as non-empty (null != "") -> it
            // stalled a perfectly good assembled plan, skipping validate, so the confirm/update tool
            // never appeared (confirmed live: assemble populated all outputs, then base_error_stalled
            // flipped True on the very next step). Same null-vs-"" trap fixed for personalizationsJson.
            res.errorMessage = '';
            try {
                Map<String, Object> plan = (Map<String, Object>) JSON.deserializeUntyped(AuraPocJson.stripFence(req.structurePlanJson));
                Map<String, Object> copy = (Map<String, Object>) JSON.deserializeUntyped(AuraPocJson.stripFence(req.copyJson));

                res.title = String.valueOf(copy.get('title'));
                res.subjectLine = String.valueOf(copy.get('subjectLine'));
                res.preheader = String.valueOf(copy.get('preheader'));

                // Fail LOUD on a blank required meta field -- title/subjectLine/preheader are all
                // REQUIRED inputs to Build Dynamic Email. If a copy fill came back empty, catch it
                // here (where they're produced) rather than letting a blank sail through to a
                // build-time "Missing required input parameter: subjectLine". BUILD only: an UPDATE
                // reuses the existing email's title/subject/preheader, so a blank here is irrelevant
                // to it -- requiring them would wrongly stall the update.
                // An UPDATE is identified by EITHER real read blocks OR a set updateTargetKey. Keying off
                // updateTargetKey too is important because base_update_emailBlocks does not always arrive
                // at this call live (the Theory-A value-delivery issue) -- without it, a blank emailBlocksJson
                // would make an update look like a build and wrongly demand title/subject/preheader.
                Boolean isUpdate = (String.isNotBlank(req.emailBlocksJson) && req.emailBlocksJson != '[]')
                    || String.isNotBlank(req.updateTargetKey);
                if (!isUpdate) {
                    List<String> blankMeta = new List<String>();
                    if (String.isBlank(res.title) || res.title == 'null') { blankMeta.add('title'); }
                    if (String.isBlank(res.subjectLine) || res.subjectLine == 'null') { blankMeta.add('subject line'); }
                    if (String.isBlank(res.preheader) || res.preheader == 'null') { blankMeta.add('preheader'); }
                    if (!blankMeta.isEmpty()) {
                        throw new AssembleException('The generated copy is missing required text for: '
                            + String.join(blankMeta, ', ') + '. Every email needs a title, subject line, and '
                            + 'preheader -- re-run the plan so these are written.');
                    }
                }

                res.urlName = slugify(res.title);

                Map<String, Object> copyBySlot = copy.get('copyBySlot') instanceof Map<String, Object>
                    ? (Map<String, Object>) copy.get('copyBySlot') : new Map<String, Object>();
                List<Object> slots = plan.get('slots') instanceof List<Object>
                    ? (List<Object>) plan.get('slots') : new List<Object>();
                List<Object> personalizations = plan.get('personalizations') instanceof List<Object>
                    ? (List<Object>) plan.get('personalizations') : new List<Object>();

                Set<String> slotKeys = new Set<String>();
                Map<String, String> slotTypeByKey = new Map<String, String>();
                List<Object> elements = new List<Object>();
                List<String> structureNotes = new List<String>();

                for (Object slotObj : slots) {
                    Map<String, Object> slot = (Map<String, Object>) slotObj;
                    String key = String.valueOf(slot.get('key'));
                    String type = String.valueOf(slot.get('type'));

                    // Deterministic asset gate (bulletproof step 2-3, image analogue of the
                    // data-graph gate below): an image slot is real only if the planner attached a
                    // resolvable asset REFERENCE -- an assetRole (logo/header) or an assetName -- NOT
                    // a raw contentKey. The planner used to hand-type the MC-key, which a capable
                    // model corrupted by a character (MC3.. vs the real MC4..); keys are now resolved
                    // deterministically in Build Dynamic Email from role/name. A back-compat literal
                    // contentKey is still accepted. When the slot carries none of these (planner had
                    // no matching asset), drop it and note the omission rather than hard-failing the
                    // whole email -- graceful degrade, same as a dropped personalization axis.
                    if (type == 'image') {
                        String role = slot.get('assetRole') == null ? '' : String.valueOf(slot.get('assetRole')).trim();
                        String assetName = slot.get('assetName') == null ? '' : String.valueOf(slot.get('assetName')).trim();
                        String ck = slot.get('contentKey') == null ? '' : String.valueOf(slot.get('contentKey'));
                        // UPDATE image DC: an image slot that names an EXISTING real block (key slot<N>
                        // present in the email's read blocks) needs no base asset ref -- the block's
                        // current image stays as the default, and per-decision swaps come from the
                        // personalizations. Only a BUILD-mode invented image slot (no such real block)
                        // still requires a base asset, else it's dropped with a note as before.
                        Boolean existingImageBlock = isExistingImageSlot(key, req.emailBlocksJson);
                        if (!existingImageBlock && String.isBlank(role) && String.isBlank(assetName) && !ck.startsWith('MC')) {
                            structureNotes.add('The planned image "' + key + '" was omitted because no matching '
                                + 'brand image asset was available; the email was built without it.');
                            continue;
                        }
                    }

                    if (slotKeys.contains(key)) {
                        throw new AssembleException('Duplicate slot key "' + key + '".');
                    }
                    slotKeys.add(key);
                    slotTypeByKey.put(key, type);

                    Map<String, Object> element = new Map<String, Object>{ 'key' => key, 'type' => type };
                    if (type == 'subject_preheader') {
                        // The subject/preheader COMPONENT: no block, no base text/contentKey element --
                        // the email's existing subjectLine/preheader stay as the default, and per-decision
                        // {subjectLine, preheader} variants override them (wired with a targetId-less op in
                        // Build). Nothing to put on the element beyond key+type.
                    } else if (type == 'image') {
                        // Carry the asset REFERENCE through to Build (which resolves it to a real
                        // contentKey). Pass a literal contentKey too only if the planner supplied one
                        // (back-compat); normally role/name is what's set.
                        if (slot.get('assetRole') != null) { element.put('assetRole', slot.get('assetRole')); }
                        if (slot.get('assetName') != null) { element.put('assetName', slot.get('assetName')); }
                        if (slot.get('contentKey') != null) { element.put('contentKey', slot.get('contentKey')); }
                        element.put('altText', slot.get('altText'));
                        if (slot.get('widthPercent') != null) {
                            element.put('widthPercent', slot.get('widthPercent'));
                        }
                    } else {
                        Map<String, Object> copyForSlot = copyBySlot.get(key) instanceof Map<String, Object>
                            ? (Map<String, Object>) copyBySlot.get(key) : null;
                        if (copyForSlot == null || copyForSlot.get('default') == null) {
                            throw new AssembleException('Copy JSON is missing default text for slot "' + key + '".');
                        }
                        element.put('text', copyForSlot.get('default'));
                        if (type == 'button') {
                            element.put('url', copyForSlot.get('url'));
                        }
                    }
                    elements.add(element);
                }
                res.elementsJson = JSON.serialize(elements);

                // ---- Deterministic data-graph gate (bulletproof steps 2-3) ------------------
                // Personalization can only be wired against fields that actually exist in a
                // RESOLVED data graph. Enforce that here, deterministically, instead of trusting
                // the LLM to have run the graph-disambiguation checklist first (the exact gap that
                // let a null-graph, empty-field-catalog plan reach build). Three outcomes:
                //   dataGraphCount == 0        -> no graph at all: drop personalization, degrade
                //                                 to a plain email, and say so (graceful, not error).
                //   graph unresolved (>1 case) -> ambiguous: stop and ask which graph (needsGraphChoice).
                //   graph resolved             -> drop only axes whose (object, field) isn't in
                //                                 the resolved graph's real schema; keep the rest.
                List<String> personalizationNotes = new List<String>();
                if (!personalizations.isEmpty()) {
                    Integer graphCount = req.dataGraphCount == null ? -1 : req.dataGraphCount;
                    Boolean graphResolved = String.isNotBlank(req.resolvedGraphApiName);

                    if (graphCount == 0) {
                        personalizationNotes.add('This org has no data graph configured, so this email '
                            + 'was built WITHOUT recipient personalization (a static email). Dropped: '
                            + describeAxes(personalizations) + '.');
                        personalizations = new List<Object>();
                    } else if (!graphResolved) {
                        List<String> names = new List<String>();
                        try {
                            for (Object n : (List<Object>) JSON.deserializeUntyped(
                                    String.isBlank(req.availableGraphNamesJson) ? '[]' : req.availableGraphNamesJson)) {
                                names.add(String.valueOf(n));
                            }
                        } catch (Exception ignore) { /* leave names empty */ }
                        res.success = false;
                        res.needsGraphChoice = true;
                        // CRITICAL: clear the elements serialized above. If we leave them, the
                        // early-return still carries a full (plain) elements array, which trips
                        // the downstream validate/branding/build gates and lets the LLM present a
                        // (hallucinated-personalized) plan for a graph that was never resolved.
                        // Empty elements = the pipeline genuinely halts here until a graph is chosen.
                        res.elementsJson = '';
                        res.personalizationsJson = '';
                        res.errorMessage = 'This request needs recipient personalization, but the data graph '
                            + 'to evaluate it against has not been chosen yet'
                            + (names.isEmpty() ? '' : ' (this org has ' + names.size() + ': ' + String.join(names, ', ') + ')')
                            + '. Ask the user which data graph to use, look it up, then re-plan.';
                        results.add(res);
                        continue;
                    } else {
                        Set<String> available = buildAvailableFieldSet(req.availableFieldsJson);
                        if (available.isEmpty()) {
                            // Graph resolved but no field catalog loaded -- cannot verify fields.
                            // Degrade to plain rather than ship unverified personalization.
                            personalizationNotes.add('Could not load the field catalog for data graph "'
                                + req.resolvedGraphApiName + '", so personalization could not be verified '
                                + 'and was dropped (built non-personalized): ' + describeAxes(personalizations) + '.');
                            personalizations = new List<Object>();
                        } else {
                            List<Object> kept = new List<Object>();
                            List<String> dropped = new List<String>();
                            for (Object pObj : personalizations) {
                                Map<String, Object> p = (Map<String, Object>) pObj;
                                String scope = String.valueOf(p.get('scope'));
                                String fieldApiName = String.valueOf(p.get('fieldApiName'));
                                String objectApiName = SCOPE_TO_OBJECT.get(scope);
                                if (objectApiName != null && available.contains(objectApiName + '|' + fieldApiName)) {
                                    kept.add(pObj);
                                } else {
                                    dropped.add((p.get('label') != null ? String.valueOf(p.get('label')) : fieldApiName)
                                        + ' (' + fieldApiName + ' on ' + scope + ')');
                                }
                            }
                            if (!dropped.isEmpty()) {
                                personalizationNotes.add('Dropped personalization not found in data graph "'
                                    + req.resolvedGraphApiName + '": ' + String.join(dropped, '; ')
                                    + (kept.isEmpty() ? ' -- this email was built non-personalized.'
                                                      : ' -- remaining personalization was kept.'));
                            }
                            personalizations = kept;
                        }
                    }
                }
                List<String> allNotes = new List<String>();
                allNotes.addAll(structureNotes);
                allNotes.addAll(personalizationNotes);
                res.personalizationNote = allNotes.isEmpty() ? '' : String.join(allNotes, ' ');
                // -----------------------------------------------------------------------------

                if (personalizations.isEmpty()) {
                    res.planSummary = 'No personalization (static email).';
                    res.success = true;
                    results.add(res);
                    continue;
                }

                // Field -> dataType (Text/Number/DateTime), so each decision carries its field's type
                // and the criteria builder emits a matching predicate (not always Text).
                Map<String, String> fieldDataTypes = buildFieldDataTypeMap(req.availableFieldsJson);

                // Group by (fieldApiName, scope) -- personalizations sharing a field+scope are
                // branches of the SAME axis (e.g. three "Equals Industry" values); a different
                // field/scope is a DIFFERENT axis and must become its own PersonalizationPoint.
                List<String> groupKeysInOrder = new List<String>();
                Map<String, List<Map<String, Object>>> groups = new Map<String, List<Map<String, Object>>>();
                for (Object pObj : personalizations) {
                    Map<String, Object> p = (Map<String, Object>) pObj;
                    String fieldApiName = String.valueOf(p.get('fieldApiName'));
                    String scope = String.valueOf(p.get('scope'));
                    String groupKey = fieldApiName + '|' + scope;
                    if (!groups.containsKey(groupKey)) {
                        groups.put(groupKey, new List<Map<String, Object>>());
                        groupKeysInOrder.add(groupKey);
                    }
                    groups.get(groupKey).add(p);
                }

                if (groupKeysInOrder.size() > maxPpsPerEmail()) {
                    throw new AssembleException('This plan needs ' + groupKeysInOrder.size()
                        + ' independent personalization rule sets (one per distinct field), but at most '
                        + maxPpsPerEmail() + ' personalization points are supported per email -- '
                        + 'ask the user to drop or combine some personalizations.');
                }

                // Confirmed live: two independent axes (e.g. persona + tier) whose plans both list
                // the SAME slot in appliesToSlots each get their own PersonalizationPoint here --
                // structurally correct per-axis, but the platform rejects two PP operations on one
                // block with "duplicate targetId" at BUILD time, after both PPs already got
                // created. Catch it here instead, before even a validate_content_plan_tool round
                // trip -- cheapest possible point to fail loud with an actionable message.
                Map<String, String> ppLabelBySlotKey = new Map<String, String>();

                List<Object> ppSpecs = new List<Object>();
                for (String groupKey : groupKeysInOrder) {
                    List<Map<String, Object>> groupMembers = groups.get(groupKey);
                    if (groupMembers.size() > maxDecisionsPerPp()) {
                        throw new AssembleException('Personalization axis "' + groupKey + '" has ' + groupMembers.size()
                            + ' decisions, but at most ' + maxDecisionsPerPp() + ' are supported per personalization point -- '
                            + 'ask the user to reduce the number of distinct values for this field.');
                    }

                    List<Object> decisions = new List<Object>();
                    List<String> decisionNames = new List<String>();
                    Map<String, Set<String>> slotKeysByDecisionName = new Map<String, Set<String>>();
                    Set<String> targetSlotKeys = new Set<String>();
                    // IMAGE DC: the asset the plan chose for each decision (from base_brand_context),
                    // used to build {assetName} variants for an image slot instead of text.
                    Map<String, String> assetByDecisionName = new Map<String, String>();
                    String seedFieldApiName = groupMembers[0].get('fieldApiName') == null ? '' : String.valueOf(groupMembers[0].get('fieldApiName'));

                    for (Map<String, Object> p : groupMembers) {
                        String name = String.valueOf(p.get('name'));
                        String scope = String.valueOf(p.get('scope'));
                        String matchType = String.isNotBlank(String.valueOf(p.get('matchType')))
                            ? String.valueOf(p.get('matchType')) : 'HasValue';

                        if (!SCOPE_TO_OBJECT.containsKey(scope)) {
                            throw new AssembleException('Personalization "' + name + '": unrecognized scope "' + scope + '".');
                        }
                        if (!MATCH_TYPE_TO_CRITERIA_TYPE.containsKey(matchType)) {
                            throw new AssembleException('Personalization "' + name + '": unrecognized matchType "' + matchType + '".');
                        }

                        Map<String, Object> decision = new Map<String, Object>{
                            'name' => name,
                            'label' => p.get('label'),
                            'criteriaFieldApiName' => p.get('fieldApiName'),
                            'criteriaObjectApiName' => SCOPE_TO_OBJECT.get(scope),
                            'criteriaType' => MATCH_TYPE_TO_CRITERIA_TYPE.get(matchType)
                        };
                        // Carry the field's data type so the criteria builder emits a Number/Date
                        // predicate (not Text) for numeric/date fields -- the platform rejects a Text
                        // predicate on e.g. ssot__AnnualRevenueAmount__c (Number).
                        String fdt = fieldDataTypes.get(String.valueOf(p.get('fieldApiName')));
                        if (String.isNotBlank(fdt)) { decision.put('dataType', fdt); }
                        if (SCOPE_TO_PATH.containsKey(scope)) {
                            decision.put('criteriaPath', SCOPE_TO_PATH.get(scope));
                        }
                        // Deterministic canonical-value mapping (see catalog above): normalize the
                        // plan LLM's loose values to the exact form the data stores -- synonym/case
                        // for Industry & Account Type, region/state-name -> 2-letter codes for State
                        // (incl. inferring an empty state array from the decision name). Fields with
                        // no catalog pass through trimmed. Keeps value-shaping deterministic instead
                        // of trusting a small model to emit exact values (principle 4).
                        String catalog = fieldCatalog(String.valueOf(p.get('fieldApiName')));
                        List<Object> rawValues = p.get('values') instanceof List<Object>
                            ? (List<Object>) p.get('values') : null;
                        if (catalog == 'STATE' && matchType != 'HasValue') {
                            // Region/state is ALWAYS an "In <2-letter codes>" decision. The plan LLM
                            // may express it as Equals "West", In ["West"], or a list of state names --
                            // normalize all of them here to the real codes (region names expand to
                            // their state sets; state names -> codes; empty -> inferred from the
                            // decision name). This is why the LLM never has to emit codes itself
                            // (principle 4), and why a plan that says Equals "West" -- which would
                            // otherwise match no recipient, since no state IS literally "West" -- now
                            // becomes a correct In [CA,WA,OR,NV,AZ] rule.
                            List<Object> raw = new List<Object>();
                            if (p.get('value') != null) { raw.add(p.get('value')); }
                            if (rawValues != null) { raw.addAll(rawValues); }
                            List<Object> codes = resolveInValues('STATE', name, String.valueOf(p.get('label')), raw);
                            decision.remove('value');
                            decision.put('criteriaType', 'in');
                            if (!codes.isEmpty()) { decision.put('values', codes); }
                        } else {
                            if (p.get('value') != null) {
                                decision.put('value', canonicalizeValue(catalog, String.valueOf(p.get('value'))));
                            }
                            if (matchType == 'In') {
                                List<Object> resolved = resolveInValues(
                                    catalog, name, String.valueOf(p.get('label')), rawValues);
                                if (!resolved.isEmpty()) {
                                    decision.put('values', resolved);
                                } else if (rawValues != null) {
                                    decision.put('values', rawValues);
                                }
                            } else if (rawValues != null) {
                                decision.put('values', rawValues);
                            }
                        }
                        decisions.add(decision);
                        decisionNames.add(name);
                        // Capture the plan's chosen image asset for this decision (image DC). The plan
                        // sets assetName on an image-slot personalization (an asset name picked from
                        // base_brand_context); resolveVariantImageRefs later turns it into a contentKey.
                        if (p.get('assetName') != null && String.isNotBlank(String.valueOf(p.get('assetName')))) {
                            assetByDecisionName.put(name, String.valueOf(p.get('assetName')).trim());
                        }

                        List<Object> appliesTo = p.get('appliesToSlots') instanceof List<Object>
                            ? (List<Object>) p.get('appliesToSlots') : new List<Object>();
                        Set<String> applySet = new Set<String>();
                        for (Object slotKeyObj : appliesTo) {
                            String slotKey = String.valueOf(slotKeyObj);
                            if (!slotKeys.contains(slotKey)) {
                                throw new AssembleException('Personalization "' + name + '" references unknown slot key "' + slotKey + '".');
                            }
                            applySet.add(slotKey);
                            targetSlotKeys.add(slotKey);
                        }
                        slotKeysByDecisionName.put(name, applySet);
                    }

                    // Every slot targeted by any member of THIS axis becomes a target -- and per
                    // the platform's PersonalizationPoint model, every target on THIS PP must
                    // carry a variant for every decision IN THIS PP (not decisions from other
                    // PPs). Decisions that don't apply to a given slot fall back to its default copy.
                    List<Object> targets = new List<Object>();
                    for (String slotKey : targetSlotKeys) {
                        String slotType = slotTypeByKey.get(slotKey);
                        if (!SLOT_TYPE_TO_BLOCK_DEFINITION.containsKey(slotType)) {
                            throw new AssembleException('Slot "' + slotKey + '" (type "' + slotType
                                + '") cannot be personalized yet -- only heading, paragraph, and button slots support per-decision copy.');
                        }
                        Boolean isImageSlot = (slotType == 'image');
                        Boolean isSubjectPreheader = (slotType == 'subject_preheader');
                        Map<String, Object> copyForSlot = copyBySlot.get(slotKey) instanceof Map<String, Object>
                            ? (Map<String, Object>) copyBySlot.get(slotKey) : new Map<String, Object>();
                        Map<String, Object> byPersonalization = copyForSlot.get('byPersonalization') instanceof Map<String, Object>
                            ? (Map<String, Object>) copyForSlot.get('byPersonalization') : new Map<String, Object>();
                        Object defaultText = copyForSlot.get('default');

                        // SUBJECT/PREHEADER DC: the component's per-decision variant is an object
                        // {subjectLine, preheader} (FillCopy writes it into byPersonalization). The op is
                        // targetId-less and the variant body is {subjectLine, preheader} (built in Build).
                        // Each applicable decision carries its {subjectLine, preheader}; a decision that
                        // doesn't apply here still needs a variant on this PP, so it gets an empty object
                        // (Build falls back to the email's existing base subject/preheader for it).
                        if (isSubjectPreheader) {
                            Map<String, Object> spByDecision = new Map<String, Object>();
                            for (String decisionName : decisionNames) {
                                Set<String> appliesToThisSlot = slotKeysByDecisionName.get(decisionName);
                                Boolean here = appliesToThisSlot != null && appliesToThisSlot.contains(slotKey);
                                if (here && byPersonalization.get(decisionName) instanceof Map<String, Object>) {
                                    Map<String, Object> sp = (Map<String, Object>) byPersonalization.get(decisionName);
                                    Map<String, Object> variant = new Map<String, Object>();
                                    if (sp.get('subjectLine') != null) { variant.put('subjectLine', sp.get('subjectLine')); }
                                    if (sp.get('preheader') != null) { variant.put('preheader', sp.get('preheader')); }
                                    if (variant.isEmpty()) {
                                        throw new AssembleException('Subject/preheader personalization decision "'
                                            + decisionName + '" has no subjectLine or preheader copy -- Write Email Copy '
                                            + 'must write at least a subject line for each decision on this component.');
                                    }
                                    spByDecision.put(decisionName, variant);
                                } else {
                                    spByDecision.put(decisionName, new Map<String, Object>());  // keep base subject/preheader
                                }
                            }
                            targets.add(new Map<String, Object>{
                                'elementKey' => slotKey,
                                'blockDefinition' => SUBJECT_PREHEADER_DEF,
                                'textByDecision' => spByDecision
                            });
                            continue;
                        }

                        // IMAGE DC: an image slot's per-decision variant is an image SWAP, not text.
                        // Each decision that applies here becomes {assetName:<the plan's chosen asset>}
                        // (resolveVariantImageRefs turns assetName -> real contentKey against the brand
                        // catalog, degrading if unresolvable). Decisions that don't apply to this image
                        // slot get an empty object (keeps the block's base image). No copy text is
                        // needed or expected for an image slot, so the text-coverage fail-loud is skipped.
                        if (isImageSlot) {
                            Map<String, Object> imgByDecision = new Map<String, Object>();
                            for (String decisionName : decisionNames) {
                                Set<String> appliesToThisSlot = slotKeysByDecisionName.get(decisionName);
                                Boolean here = appliesToThisSlot != null && appliesToThisSlot.contains(slotKey);
                                if (here && assetByDecisionName.containsKey(decisionName)) {
                                    imgByDecision.put(decisionName, new Map<String, Object>{ 'assetName' => assetByDecisionName.get(decisionName) });
                                } else {
                                    imgByDecision.put(decisionName, new Map<String, Object>());  // keep base image
                                }
                            }
                            targets.add(new Map<String, Object>{
                                'elementKey' => slotKey,
                                'blockDefinition' => 'lightning/image',
                                'textByDecision' => imgByDecision
                            });
                            continue;
                        }

                        Map<String, Object> textByDecision = new Map<String, Object>();
                        for (String decisionName : decisionNames) {
                            Set<String> appliesToThisSlot = slotKeysByDecisionName.get(decisionName);
                            Boolean decisionAppliesHere = appliesToThisSlot != null && appliesToThisSlot.contains(slotKey);
                            if (decisionAppliesHere) {
                                // Confirmed live: Write Email Copy can silently skip writing a
                                // byPersonalization entry for a decision the plan explicitly said
                                // applies to this slot (e.g. planned Manufacturing AND Healthcare
                                // variants, copy only wrote Manufacturing). Falling back to default
                                // text here would silently ship a "personalized" variant that's
                                // actually just the generic copy -- fail loud instead so the gap
                                // surfaces before build, not after a customer notices dead content.
                                if (!byPersonalization.containsKey(decisionName)) {
                                    throw new AssembleException('Copy JSON is missing a byPersonalization entry for decision "'
                                        + decisionName + '" on slot "' + slotKey + '", even though the structure plan says this '
                                        + 'personalization applies to that slot. Write Email Copy must write a variant for every '
                                        + 'personalization listed in that slot\'s appliesToSlots -- no partial coverage.');
                                }
                                textByDecision.put(decisionName, byPersonalization.get(decisionName));
                            } else {
                                // This decision belongs to the same PP (so it still needs SOME
                                // variant here) but was never meant to affect this particular slot
                                // -- falling back to the slot's own default copy is correct, not a gap.
                                textByDecision.put(decisionName, defaultText);
                            }
                        }

                        targets.add(new Map<String, Object>{
                            'elementKey' => slotKey,
                            'blockDefinition' => SLOT_TYPE_TO_BLOCK_DEFINITION.get(slotType),
                            'textByDecision' => textByDecision
                        });
                    }

                    String seedLabel = humanizeFieldName(seedFieldApiName) + ' Personalization';
                    for (String slotKey : targetSlotKeys) {
                        if (ppLabelBySlotKey.containsKey(slotKey)) {
                            throw new AssembleException('Slot "' + slotKey + '" is targeted by both "'
                                + ppLabelBySlotKey.get(slotKey) + '" and "' + seedLabel + '" -- a CMS block can only '
                                + 'carry one PersonalizationPoint operation. Either combine these into ONE '
                                + 'personalization whose decisions cover every real combination of both fields, or '
                                + 'target a different slot for one of them.');
                        }
                        ppLabelBySlotKey.put(slotKey, seedLabel);
                    }
                    ppSpecs.add(new Map<String, Object>{
                        'ppName' => seedLabel.replaceAll('[^A-Za-z0-9]+', '_'),
                        'ppLabel' => seedLabel,
                        'decisionsJson' => JSON.serialize(decisions),
                        'targetsJson' => JSON.serialize(targets)
                    });
                }

                // UPDATE mode: DERIVE slot bindings here (the LLM never calls a slot tool reliably).
                // Match each axis's target to the first eligible read-block slot of its type; drop
                // axes with no eligible slot (harmlessly discarding over-planned ones). Rewrites
                // ppSpecs to only the bound axes and emits the {elementKey, slot} bindings.
                res.slotBindingsJson = '[]';
                // SELF-HEAL the Theory-A stall: an update (updateTargetKey set) can reach assembly with a
                // BLANK emailBlocksJson even though the agent read the email earlier -- the bound
                // base_update_emailBlocks value does not always arrive at this action call (a live
                // value-delivery timing issue, proven repeatedly: the identical plan+blocks bind fine in
                // anon-Apex but live emailBlocksJson is empty here). Rather than fail loud (which stalls
                // the whole update), RE-READ the blocks straight from updateTargetKey so derivation always
                // has them. ReadDynamicEmailAction is a plain Apex call (no agent-runtime dependency).
                String effectiveBlocks = req.emailBlocksJson;
                // The passed-through base_update_emailBlocks is UNRELIABLE for real emails: the agent
                // runtime corrupts the JSON escaping of complex block text (HTML footers with quotes,
                // {!$merge} fields) so it fails to parse (proven live: JSONException "expecting comma"
                // at col 804 inside slot-4/5 HTML) -- even though ReadDynamicEmailAction serializes it
                // cleanly. So for an update, re-read the blocks directly from updateTargetKey (a plain
                // Apex call whose JSON.serialize output is always valid) whenever the passed value is
                // blank OR does not parse. This makes slot derivation robust to the runtime corruption.
                if (String.isNotBlank(req.updateTargetKey) && !ppSpecs.isEmpty()) {
                    Boolean passedParses = false;
                    if (String.isNotBlank(effectiveBlocks) && effectiveBlocks != '[]') {
                        try { Object p = JSON.deserializeUntyped(AuraPocJson.stripFence(effectiveBlocks));
                              passedParses = (p instanceof List<Object>); } catch (Exception e) { passedParses = false; }
                    }
                    if (!passedParses) {
                        try {
                            ReadDynamicEmailAction.Request rr = new ReadDynamicEmailAction.Request();
                            rr.contentKey = req.updateTargetKey;
                            List<ReadDynamicEmailAction.Result> rres =
                                ReadDynamicEmailAction.readDynamicEmail(new List<ReadDynamicEmailAction.Request>{ rr });
                            if (rres != null && !rres.isEmpty() && String.isNotBlank(rres[0].blocksJson)) {
                                effectiveBlocks = rres[0].blocksJson;
                            }
                        } catch (Exception e) { /* surfaced below */ }
                    }
                    if (String.isBlank(effectiveBlocks) || effectiveBlocks == '[]') {
                        throw new AssembleException('Update to "' + req.updateTargetKey + '" reached assembly but '
                            + 'the email\'s blocks were not provided and could not be re-read, so no slot could be bound.');
                    }
                }
                if (String.isNotBlank(effectiveBlocks) && effectiveBlocks != '[]' && !ppSpecs.isEmpty()) {
                    // MULTI-SLOT update: bind each planned axis to its explicitly-named real slot. We no
                    // longer prune to a single "primary" axis -- that was a guard against the create-
                    // planner over-planning an update, made obsolete by the UPDATE-MODE prompt (which
                    // plans ONLY the user's chosen slots) and harmful to legitimate multi-slot requests
                    // (it dropped every axis but one). deriveUpdateSlotBindings already drops a genuine
                    // collision (two different-field axes on the SAME slot -- the platform's hard limit)
                    // via its usedSlots tracking, so the one thing prune protected against is still safe.
                    ppSpecs = deriveUpdateSlotBindings(ppSpecs, effectiveBlocks, res);
                }
                res.personalizationsJson = JSON.serialize(ppSpecs);
                // Deterministic PP/OP/slot summary for the confirm dialog -- with the slot
                // name + type each axis targets, not just a count.
                Map<String, String> planSlotType = new Map<String, String>();
                for (Object sObj : (plan.get('slots') instanceof List<Object> ? (List<Object>) plan.get('slots') : new List<Object>())) {
                    if (sObj instanceof Map<String, Object>) {
                        Map<String, Object> s2 = (Map<String, Object>) sObj;
                        planSlotType.put(String.valueOf(s2.get('key')), String.valueOf(s2.get('type')));
                    }
                }
                Integer opCount = 0;
                Set<String> slotSet = new Set<String>();
                List<String> ppLines = new List<String>();
                for (Object pObj : ppSpecs) {
                    Map<String, Object> pp = (Map<String, Object>) pObj;
                    Object dj = JSON.deserializeUntyped(String.valueOf(pp.get('decisionsJson')));
                    Integer nd = (dj instanceof List<Object>) ? ((List<Object>) dj).size() : 0;
                    opCount += nd;
                    List<String> slotsForPp = new List<String>();
                    Object tj = JSON.deserializeUntyped(String.valueOf(pp.get('targetsJson')));
                    if (tj instanceof List<Object>) {
                        for (Object t : (List<Object>) tj) {
                            if (t instanceof Map<String, Object>) {
                                Object ek = ((Map<String, Object>) t).get('elementKey');
                                if (ek != null) {
                                    String k = String.valueOf(ek);
                                    slotSet.add(k);
                                    String ty = planSlotType.containsKey(k) ? planSlotType.get(k) : 'slot';
                                    slotsForPp.add(k + ' (' + ty + ')');
                                }
                            }
                        }
                    }
                    ppLines.add(String.valueOf(pp.get('ppLabel')) + ' -> ' + String.join(slotsForPp, ', ')
                        + ' [' + nd + ' variant(s)]');
                }
                String graphName = String.isBlank(req.resolvedGraphApiName) ? 'none' : req.resolvedGraphApiName;
                res.planSummary = ppSpecs.size() + ' PP(s), ' + opCount + ' variant(s)/OP(s) across '
                    + slotSet.size() + ' slot(s) | ' + String.join(ppLines, '; ') + ' | data graph: ' + graphName + '.';
                res.success = true;
            } catch (Exception e) {
                res.success = false;
                res.errorMessage = e.getMessage();
            }
            results.add(res);
        }
        return results;
    }

    // UPDATE-mode slot derivation. For each planned axis, bind its target(s) to the FIRST eligible
    // existing slot of the matching block type; an axis whose target(s) can't ALL be bound is dropped
    // (harmlessly discards over-planned axes the user didn't ask for). Returns the surviving ppSpecs
    // and sets res.slotBindingsJson = [{elementKey, slot}]. emailBlocksJson is ReadDynamicEmailAction
    // output: [{slot, id, def, personalized}] over content blocks, in order.
    // If an elementKey is an explicit real slot reference "slot<N>" (as UPDATE-MODE emits, e.g. "slot4"),
    // return N; otherwise null (a create-style descriptive key like "greeting_paragraph").
    private static Integer explicitSlotNumber(String elementKey) {
        if (String.isBlank(elementKey)) { return null; }
        Matcher m = Pattern.compile('(?i)^slot(\\d+)$').matcher(elementKey.trim());
        return m.matches() ? Integer.valueOf(m.group(1)) : null;
    }

    // True when slotKey is "slot<N>" and block N in the email's read blocks is an existing image block.
    // Lets an UPDATE personalize an existing image slot without a base asset ref (image DC).
    private static Boolean isExistingImageSlot(String slotKey, String emailBlocksJson) {
        Integer n = explicitSlotNumber(slotKey);
        if (n == null || String.isBlank(emailBlocksJson)) { return false; }
        try {
            for (Object o : (List<Object>) JSON.deserializeUntyped(AuraPocJson.stripFence(emailBlocksJson))) {
                if (!(o instanceof Map<String, Object>)) { continue; }
                Map<String, Object> b = (Map<String, Object>) o;
                if (b.get('slot') != null && Integer.valueOf(String.valueOf(b.get('slot'))) == n) {
                    return String.valueOf(b.get('def')) == 'lightning/image';
                }
            }
        } catch (Exception ignore) { }
        return false;
    }

    private static List<Object> deriveUpdateSlotBindings(List<Object> ppSpecs, String emailBlocksJson, Result res) {
        // Ordered eligible slots per block definition (skip already-personalized), plus per-slot
        // def + personalized maps so an EXPLICIT slotN request can be honored (or rejected) exactly.
        Map<String, List<Integer>> freeSlotsByDef = new Map<String, List<Integer>>();
        Map<Integer, String> defBySlot = new Map<Integer, String>();
        Map<Integer, Boolean> personalizedBySlot = new Map<Integer, Boolean>();
        try {
            for (Object o : (List<Object>) JSON.deserializeUntyped(AuraPocJson.stripFence(emailBlocksJson))) {
                if (!(o instanceof Map<String, Object>)) { continue; }
                Map<String, Object> b = (Map<String, Object>) o;
                if (b.get('slot') == null || b.get('def') == null) { continue; }
                Integer sn = Integer.valueOf(String.valueOf(b.get('slot')));
                String def = String.valueOf(b.get('def'));
                defBySlot.put(sn, def);
                personalizedBySlot.put(sn, b.get('personalized') == true);
                if (b.get('personalized') == true) { continue; }   // ineligible: already has DC
                if (!freeSlotsByDef.containsKey(def)) { freeSlotsByDef.put(def, new List<Integer>()); }
                freeSlotsByDef.get(def).add(sn);
            }
        } catch (Exception ignore) { return ppSpecs; /* unparseable -> leave plan as-is, validation backstops */ }

        List<Object> keptPpSpecs = new List<Object>();
        List<Object> bindings = new List<Object>();
        List<String> droppedLabels = new List<String>();
        // Track which slot index we've consumed per def (for non-explicit keys), and which concrete
        // slot numbers are already bound this pass (so two axes never double-book a slot).
        Map<String, Integer> nextIdxByDef = new Map<String, Integer>();
        Set<Integer> usedSlots = new Set<Integer>();

        for (Object ppObj : ppSpecs) {
            Map<String, Object> pp = (Map<String, Object>) ppObj;
            List<Object> targets;
            try { targets = (List<Object>) JSON.deserializeUntyped(String.valueOf(pp.get('targetsJson'))); }
            catch (Exception ignore) { targets = new List<Object>(); }

            // Bind EVERY target of this axis. An explicit slotN elementKey binds to EXACTLY slot N
            // (and is rejected if N is missing, already personalized, an image, or its real def does
            // not match the target's block type) -- so a request for a specific slot is honored or
            // cleanly dropped, never silently rebound to a different slot (the EC3 bug). A
            // non-explicit key (e.g. a create-style "greeting_paragraph") falls back to the first
            // free slot of its type.
            List<Object> axisBindings = new List<Object>();
            Boolean allBound = !targets.isEmpty();
            Boolean targetsCorrected = false;
            for (Object tObj : targets) {
                Map<String, Object> t = (Map<String, Object>) tObj;
                String ek = String.valueOf(t.get('elementKey'));
                String def = t.get('blockDefinition') == null ? '' : String.valueOf(t.get('blockDefinition'));
                // SUBJECT/PREHEADER component: not a block, no slot number to bind. It targets email
                // metadata via a targetId-less op (built in Build), so there is nothing to resolve here
                // -- pass it through as bound (no {elementKey,slot} entry) so the axis is kept, not dropped.
                if (def == SUBJECT_PREHEADER_DEF || ek == 'subject_preheader') {
                    continue;
                }
                Integer explicit = explicitSlotNumber(ek);
                if (explicit != null) {
                    // Honor the exact slot the user named. The SLOT NUMBER is authoritative; its TYPE
                    // is whatever the real block is -- NOT the plan's "type" (the create-planner often
                    // defaults an un-stated type to "paragraph", so a heading/button/IMAGE slot would
                    // carry the wrong blockDefinition and fail to bind). So: require the slot exists, is
                    // unpersonalized, and not already used -- and take the def from the REAL block,
                    // correcting the target's blockDefinition. IMAGE slots ARE now bindable (image DC:
                    // the swap-per-decision engine in resolveVariantImageRefs handles image variants);
                    // an image target's per-decision variants are {assetName} objects, not text.
                    String realDef = defBySlot.get(explicit);
                    Boolean eligible = defBySlot.containsKey(explicit)
                            && personalizedBySlot.get(explicit) != true
                            && !usedSlots.contains(explicit)
                            && realDef != null;
                    if (eligible) {
                        // IMAGE-DC: when the real block is an image, this target is an image SWAP -- its
                        // per-decision variants become {assetName}/{assetRole}/{contentKey} image objects.
                        // We do NOT require the plan to have named an asset here: if a decision has no
                        // asset (the planner typed the slot as text, or typed it image but picked no asset
                        // because none thematically fit the axis), Build's resolveVariantImageRefs
                        // deterministically auto-assigns a distinct catalog image per decision -- so the
                        // swap still works and shows a different picture per audience. The only genuine
                        // failure (org has zero image assets at all) is raised there with a clear message.
                        // We just correct the block type below so Build treats it as an image target.
                        if (realDef != def) {
                            t.put('blockDefinition', realDef);
                            targetsCorrected = true;   // correct the plan's guessed type
                            // If we corrected a TEXT target to image, its textByDecision holds copy
                            // STRINGS (from the plan's byPersonalization). resolveVariantImageRefs only
                            // processes image OBJECT variants, so rewrite each decision to an empty image
                            // object {} -- the auto-assign there then fills a distinct catalog image.
                            if (realDef == 'lightning/image') {
                                Object tbd = t.get('textByDecision');
                                if (tbd instanceof Map<String, Object>) {
                                    Map<String, Object> byDec = (Map<String, Object>) tbd;
                                    for (String dkey : new List<String>(byDec.keySet())) {
                                        if (!(byDec.get(dkey) instanceof Map<String, Object>)) {
                                            byDec.put(dkey, new Map<String, Object>());  // empty image variant -> auto-assigned
                                        }
                                    }
                                }
                            }
                        }
                        axisBindings.add(new Map<String, Object>{ 'elementKey' => ek, 'slot' => explicit });
                        usedSlots.add(explicit);
                    } else {
                        allBound = false;   // requested slot not eligible (missing / image / personalized) -> drop, no rebind
                    }
                } else {
                    List<Integer> free = freeSlotsByDef.get(def);
                    Integer idx = nextIdxByDef.containsKey(def) ? nextIdxByDef.get(def) : 0;
                    // advance past any slots already used by an explicit binding
                    while (free != null && idx < free.size() && usedSlots.contains(free[idx])) { idx++; }
                    if (free != null && idx < free.size()) {
                        axisBindings.add(new Map<String, Object>{ 'elementKey' => ek, 'slot' => free[idx] });
                        usedSlots.add(free[idx]);
                        nextIdxByDef.put(def, idx + 1);
                    } else {
                        allBound = false;   // no eligible slot of this type left
                    }
                }
            }

            if (allBound) {
                // If we corrected any target's blockDefinition to the real block type, write the
                // updated targets back into the ppSpec so the downstream update targets the right block.
                if (targetsCorrected) { pp.put('targetsJson', JSON.serialize(targets)); }
                keptPpSpecs.add(pp);
                bindings.addAll(axisBindings);
            } else {
                droppedLabels.add(String.valueOf(pp.get('ppLabel')));
                // Release any slots this dropped axis had reserved, so a later kept axis can use them.
                for (Object bObj : axisBindings) {
                    Object sn = ((Map<String,Object>) bObj).get('slot');
                    if (sn != null) { usedSlots.remove(Integer.valueOf(String.valueOf(sn))); }
                }
            }
        }

        res.slotBindingsJson = JSON.serialize(bindings);
        if (!droppedLabels.isEmpty()) {
            String note = 'These personalizations were skipped -- no eligible (unpersonalized) slot of '
                + 'the matching type: ' + String.join(droppedLabels, ', ') + '.';
            res.personalizationNote = String.isBlank(res.personalizationNote) ? note
                : (res.personalizationNote + ' ' + note);
        }
        return keptPpSpecs;
    }
}