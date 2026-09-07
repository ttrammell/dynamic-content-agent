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

    private static final Map<String, String> SLOT_TYPE_TO_BLOCK_DEFINITION = new Map<String, String>{
        'heading' => 'lightning/heading', 'paragraph' => 'lightning/paragraph', 'button' => 'lightning/actionButton'
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
            // breaks downstream prompt/merge resolution.
            res.personalizationNote = '';
            res.needsGraphChoice = false;
            try {
                Map<String, Object> plan = (Map<String, Object>) JSON.deserializeUntyped(req.structurePlanJson);
                Map<String, Object> copy = (Map<String, Object>) JSON.deserializeUntyped(req.copyJson);

                res.title = String.valueOf(copy.get('title'));
                res.subjectLine = String.valueOf(copy.get('subjectLine'));
                res.preheader = String.valueOf(copy.get('preheader'));
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
                    // genuine CMS contentKey (starts with "MC"). The planner is instructed to omit
                    // the image when no brand asset matches, but confirmed live it can still emit an
                    // image slot with a blank/fabricated contentKey when the brand catalog came back
                    // empty ([]). Drop the slot and note the omission here rather than let Build
                    // Dynamic Email hard-fail the ENTIRE email on one bad contentKey -- graceful
                    // degrade, not error, same as a dropped personalization axis.
                    if (type == 'image') {
                        String ck = slot.get('contentKey') == null ? '' : String.valueOf(slot.get('contentKey'));
                        if (!ck.startsWith('MC')) {
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
                    if (type == 'image') {
                        element.put('contentKey', slot.get('contentKey'));
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
                        Map<String, Object> copyForSlot = copyBySlot.get(slotKey) instanceof Map<String, Object>
                            ? (Map<String, Object>) copyBySlot.get(slotKey) : new Map<String, Object>();
                        Map<String, Object> byPersonalization = copyForSlot.get('byPersonalization') instanceof Map<String, Object>
                            ? (Map<String, Object>) copyForSlot.get('byPersonalization') : new Map<String, Object>();
                        Object defaultText = copyForSlot.get('default');

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
}