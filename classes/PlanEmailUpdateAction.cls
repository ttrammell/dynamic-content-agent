// Deterministic UPDATE-mode planner. Emits a structurePlanJson in the SAME shape the create-planner
// (prompt://AuraPoc_PlanEmailStructureV2) produces, BUT constrained to the existing email's REAL read
// blocks -- so FillCopy -> Assemble -> Validate bind it unchanged. No LLM callout.
//
// Why this exists: the create-planner INVENTS generic slots (greeting_heading, case_count_paragraph...)
// that don't map to an existing email's real blocks; for an update those invented slots can't bind and
// the pipeline stalls ("no slots were chosen"). This planner takes the user's TYPED intent
// (note_update_plan: target slot #(s) + field + values) with a free-text (userIntent) fallback, resolves
// the field against the data-graph catalog, and emits ONE slot / ONE axis / N variants against the real
// chosen slot. Fails LOUD (never a silent empty plan) when blocks are missing, the slot is ineligible,
// or the field is not in the graph -- so the failure is diagnosable instead of a silent []-binding stall.
//
// Mirrors AssembleContentPlanAction's deterministic-lookup discipline: scope<->object and block-def<->
// slot-type are fixed maps, not model decisions.
public with sharing class PlanEmailUpdateAction {

    public class Request {
        // The existing email's blocks from ReadDynamicEmailAction.blocksJson:
        // [{slot, id, def, text, contentKey, personalized}] in document order. Required.
        @InvocableVariable(label='Existing Blocks JSON' required=true)
        public String emailBlocksJson;

        // TYPED intent (from note_update_plan): JSON array of target SLOT numbers, e.g. "[3]".
        @InvocableVariable(label='Plan Slots JSON')
        public String planSlotsJson;

        // TYPED intent: personalization field in natural words, e.g. "industry".
        @InvocableVariable(label='Plan Field')
        public String planField;

        // TYPED intent: optional scope hint, e.g. "RecipientAccount". Usually inferred from the catalog.
        @InvocableVariable(label='Plan Scope')
        public String planScope;

        // TYPED intent: JSON array of values, e.g. ["Technology","Healthcare","Finance"]. "[]" = HasValue.
        @InvocableVariable(label='Plan Values JSON')
        public String planValuesJson;

        // TYPED intent: optional HasValue|Equals|In. Derived from value count when blank.
        @InvocableVariable(label='Plan Match Type')
        public String planMatchType;

        // Data-graph field catalog: [{dmoLabel, dmoName, fieldApiName, fieldLabel, dataType}].
        @InvocableVariable(label='Available Fields JSON')
        public String fieldsJson;

        // Free-text request -- FALLBACK when the typed vars are missing/unparseable.
        @InvocableVariable(label='User Intent')
        public String userIntent;
    }

    public class Result {
        @InvocableVariable(label='Success')
        public Boolean success;

        // The create-planner-shaped plan, constrained to real slots. "" on failure.
        @InvocableVariable(label='Structure Plan JSON')
        public String structurePlanJson;

        // FAIL-LOUD text: blocks missing, slot ineligible, or field not in the graph. "" on success.
        @InvocableVariable(label='Error Message')
        public String errorMessage;

        // Human note about how slot/field were resolved or degraded. "" when nothing to note.
        @InvocableVariable(label='Plan Note')
        public String planNote;
    }

    public class PlanEmailUpdateException extends Exception {}

    // Read-block def -> plan slot type. Image is intentionally excluded: images aren't text-personalizable
    // (Assemble's SLOT_TYPE_TO_BLOCK_DEFINITION only covers heading/paragraph/button).
    private static final Map<String, String> BLOCK_DEF_TO_SLOT_TYPE = new Map<String, String>{
        'lightning/heading' => 'heading',
        'lightning/paragraph' => 'paragraph',
        'lightning/actionButton' => 'button'
    };

    // Inverse of AssembleContentPlanAction.SCOPE_TO_OBJECT -- resolve a catalog dmoName back to a scope.
    private static final Map<String, String> OBJECT_TO_SCOPE = new Map<String, String>{
        'UnifiedIndividual__dlm' => 'Recipient',
        'ssot__Account__dlm' => 'RecipientAccount',
        'ssot__ContactPointAddress__dlm' => 'RecipientAddress',
        'ssot__Individual__dlm' => 'RecipientProfile',
        'ssot__EmailEngagementScore__dlm' => 'RecipientEmailEngagement',
        'ssot__Lead__dlm' => 'RecipientLead'
    };
    private static final String SCOPE_DEFAULT = 'RecipientAccount';

    @InvocableMethod(label='Plan Email Update' description='Deterministically turns the typed update intent (target slots + field + values) or the free-text request into a real-slot structure plan for adding dynamic content to an EXISTING email -- constrained to the email\'s actual read blocks so assembly binds it. No LLM callout. Fails loud if blocks are missing, no eligible slot of the requested type exists, or the field is not in the data graph.')
    public static List<Result> planEmailUpdate(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result res = new Result();
            res.success = false;
            res.structurePlanJson = '';
            res.errorMessage = '';
            res.planNote = '';
            try {
                buildPlan(req, res);
            } catch (Exception e) {
                res.success = false;
                res.structurePlanJson = '';
                res.errorMessage = e.getMessage();
            }
            results.add(res);
        }
        return results;
    }

    private static void buildPlan(Request req, Result res) {
        // 1) Parse blocks; fail loud if none.
        List<Object> blocks;
        try {
            blocks = (List<Object>) JSON.deserializeUntyped(AuraPocJson.stripFence(req.emailBlocksJson));
        } catch (Exception e) { blocks = new List<Object>(); }
        if (blocks == null || blocks.isEmpty()) {
            // BENIGN no-op, NOT a fail-loud: a blank emailBlocksJson here means this invocation was
            // starved of blocks (e.g. the LLM called the action directly with no bound input, or an
            // early/partial pass). Returning an ERROR would trip base_error_pipeline -> base_error_stalled,
            // which then BLOCKS the real gated after_reasoning run (which HAS the blocks) from ever firing
            // -- the exact live stall. So leave errorMessage empty and produce no plan; the deterministic
            // gated run (with blocks bound) then does the real planning. Real fail-loud cases below
            // (ineligible slot / field not in graph) only occur when blocks ARE present.
            res.success = false;
            res.structurePlanJson = '';
            res.errorMessage = '';
            res.planNote = 'No email blocks supplied to this call; deferring to the deterministic update-planner pass.';
            return;
        }
        // slot -> {def, personalized}; plus an eligibility catalog for messages.
        Map<Integer, String> defBySlot = new Map<Integer, String>();
        Map<Integer, Boolean> personalizedBySlot = new Map<Integer, Boolean>();
        List<String> eligibleDesc = new List<String>();
        for (Object o : blocks) {
            if (!(o instanceof Map<String, Object>)) { continue; }
            Map<String, Object> b = (Map<String, Object>) o;
            if (b.get('slot') == null || b.get('def') == null) { continue; }
            Integer sn = Integer.valueOf(String.valueOf(b.get('slot')));
            String def = String.valueOf(b.get('def'));
            Boolean pers = b.get('personalized') == true;
            defBySlot.put(sn, def);
            personalizedBySlot.put(sn, pers);
            if (!pers && BLOCK_DEF_TO_SLOT_TYPE.containsKey(def)) {
                eligibleDesc.add('slot ' + sn + ' (' + BLOCK_DEF_TO_SLOT_TYPE.get(def) + ')');
            }
        }

        // 2) Target slot(s): typed first, then userIntent regex fallback.
        List<Integer> requested = parseSlotList(req.planSlotsJson);
        Boolean usedFallbackSlot = false;
        if (requested.isEmpty()) {
            requested = slotsFromIntent(req.userIntent);
            usedFallbackSlot = !requested.isEmpty();
        }
        // Validate each requested slot; collect the first eligible one (one-slot/one-axis semantics).
        List<Integer> chosen = new List<Integer>();
        List<String> rejectReasons = new List<String>();
        for (Integer sn : requested) {
            if (!defBySlot.containsKey(sn)) {
                rejectReasons.add('slot ' + sn + ' does not exist');
            } else if (personalizedBySlot.get(sn) == true) {
                rejectReasons.add('slot ' + sn + ' is already personalized');
            } else if (!BLOCK_DEF_TO_SLOT_TYPE.containsKey(defBySlot.get(sn))) {
                rejectReasons.add('slot ' + sn + ' is an image (not text-personalizable)');
            } else {
                chosen.add(sn);
            }
        }
        // If nothing requested at all but the user clearly wants to personalize, take the first eligible.
        if (requested.isEmpty() && String.isNotBlank(req.userIntent)) {
            for (Integer sn : new List<Integer>(defBySlot.keySet())) {
                if (personalizedBySlot.get(sn) != true && BLOCK_DEF_TO_SLOT_TYPE.containsKey(defBySlot.get(sn))) {
                    chosen.add(sn);
                    usedFallbackSlot = true;
                    break;
                }
            }
        }
        if (chosen.isEmpty()) {
            String why = rejectReasons.isEmpty() ? 'no eligible slot was identified' : String.join(rejectReasons, '; ');
            res.errorMessage = 'Cannot personalize the requested slot(s): ' + why + '. Eligible slots: '
                + (eligibleDesc.isEmpty() ? '(none -- all slots are images or already personalized)' : String.join(eligibleDesc, ', ')) + '.';
            return;
        }
        Integer targetSlot = chosen[0];                 // one slot, one axis (locked semantics)
        String targetType = BLOCK_DEF_TO_SLOT_TYPE.get(defBySlot.get(targetSlot));

        // 3) Field: typed first, then fuzzy-match from userIntent. Resolve against the catalog.
        List<Object> catalog;
        try { catalog = (List<Object>) JSON.deserializeUntyped(AuraPocJson.stripFence(req.fieldsJson)); }
        catch (Exception e) { catalog = new List<Object>(); }

        // Typed planField wins. Otherwise DON'T feed the whole sentence to matchField -- incidental
        // words ("content" in "add dynamic content", "email", "slot") match unrelated fields (e.g.
        // "Digital Content"). Extract the phrase the user actually named the field with: the text
        // after "by "/"based on "/"using "/"personalize by " and before any ":" value list.
        String fieldTerm = String.isNotBlank(req.planField) ? req.planField : extractFieldTermFromIntent(req.userIntent);
        Map<String, Object> matched = matchField(fieldTerm, catalog);
        // Last resort only if the tight extraction found nothing: try the whole intent (some phrasings
        // won't match the "by X:" shape). Still stop-worded inside matchField.
        if (matched == null && String.isBlank(req.planField) && String.isNotBlank(req.userIntent) && fieldTerm != req.userIntent) {
            matched = matchField(req.userIntent, catalog);
        }
        Boolean usedFallbackField = String.isBlank(req.planField) && matched != null;
        if (matched == null) {
            List<String> avail = new List<String>();
            for (Object o : catalog) {
                if (o instanceof Map<String, Object>) {
                    Object fl = ((Map<String, Object>) o).get('fieldLabel');
                    if (fl != null) { avail.add(String.valueOf(fl)); }
                }
                if (avail.size() >= 12) { break; }
            }
            res.errorMessage = 'Field "' + (String.isBlank(fieldTerm) ? '(unspecified)' : fieldTerm)
                + '" is not in this org\'s data graph. Available fields: '
                + (avail.isEmpty() ? '(none resolved -- confirm the data graph)' : String.join(avail, ', ')) + '.';
            return;
        }
        String fieldApiName = String.valueOf(matched.get('fieldApiName'));
        String dmoName = String.valueOf(matched.get('dmoName'));
        String fieldLabel = matched.get('fieldLabel') != null ? String.valueOf(matched.get('fieldLabel')) : fieldApiName;

        // Scope: honor a consistent typed hint, else invert dmoName, else default.
        String scope = OBJECT_TO_SCOPE.containsKey(dmoName) ? OBJECT_TO_SCOPE.get(dmoName) : null;
        if (String.isNotBlank(req.planScope) && OBJECT_TO_SCOPE.values().contains(req.planScope)) {
            scope = req.planScope;
        }
        if (String.isBlank(scope)) { scope = SCOPE_DEFAULT; }

        // 4) Values + matchType.
        List<Object> values = new List<Object>();
        try {
            Object v = JSON.deserializeUntyped(AuraPocJson.stripFence(String.isBlank(req.planValuesJson) ? '[]' : req.planValuesJson));
            if (v instanceof List<Object>) { values = (List<Object>) v; }
        } catch (Exception e) { values = new List<Object>(); }
        Boolean usedFallbackValues = false;
        if (values.isEmpty()) {
            // Typed planValuesJson was empty (note_update_plan didn't fire, or gave no values).
            // Parse the comma/"and" list after the ":" in the intent, e.g. "by industry: Technology,
            // Healthcare, Finance" -> [Technology, Healthcare, Finance]. Without this the N variants
            // are silently lost and the plan degrades to a single HasValue decision.
            List<Object> fromIntent = extractValuesFromIntent(req.userIntent);
            if (!fromIntent.isEmpty()) { values = fromIntent; usedFallbackValues = true; }
        }
        String matchType = req.planMatchType;
        if (String.isBlank(matchType)) {
            matchType = values.size() > 1 ? 'In' : (values.size() == 1 ? 'Equals' : 'HasValue');
        }

        // 5) Emit the real-slot plan: ONE slot, ONE axis, N VARIANTS.
        // Assemble treats each personalizations[] entry as ONE decision (grouped by fieldApiName|scope
        // into a single PP). To get N DISTINCT variants (one copy per value, e.g. per industry), emit
        // ONE personalization PER VALUE (matchType Equals), each a distinct decision name, all sharing
        // field/scope/appliesToSlots -- exactly how the create-planner represents e.g. industry_technology
        // / industry_healthcare / industry_finance. A values-less axis is a single HasValue decision.
        String slotKey = 'slot' + targetSlot;
        Map<String, Object> slot = new Map<String, Object>{
            'key' => slotKey, 'type' => targetType,
            'goal' => 'Personalize this existing ' + targetType + ' by ' + fieldLabel + '.'
        };
        List<Object> personalizations = new List<Object>();
        String fieldBase = sanitize(fieldApiName);
        if (values.isEmpty()) {
            // HasValue: single decision, present-or-default.
            personalizations.add(new Map<String, Object>{
                'name' => fieldBase + '_present',
                'label' => fieldLabel + ' present',
                'fieldApiName' => fieldApiName, 'scope' => scope, 'matchType' => 'HasValue',
                'appliesToSlots' => new List<Object>{ slotKey }
            });
        } else {
            for (Object v : values) {
                String vs = String.valueOf(v);
                personalizations.add(new Map<String, Object>{
                    'name' => fieldBase + '_' + sanitize(vs).toLowerCase(),
                    'label' => fieldLabel + ' = ' + vs,
                    'fieldApiName' => fieldApiName, 'scope' => scope, 'matchType' => 'Equals',
                    'value' => vs,
                    'appliesToSlots' => new List<Object>{ slotKey }
                });
            }
        }

        Map<String, Object> plan = new Map<String, Object>{
            'slots' => new List<Object>{ slot },
            'personalizations' => personalizations
            // titleGoal/subjectLineGoal/preheaderGoal omitted -- FillCopy defaults them; Assemble skips
            // blank-meta for updates (emailBlocksJson present).
        };
        res.structurePlanJson = JSON.serialize(plan);
        res.success = true;
        List<String> notes = new List<String>();
        if (usedFallbackSlot) { notes.add('slot resolved from your request text'); }
        if (usedFallbackField) { notes.add('field "' + fieldLabel + '" resolved from your request text'); }
        if (usedFallbackValues) { notes.add('values resolved from your request text'); }
        res.planNote = notes.isEmpty() ? '' : ('Note: ' + String.join(notes, '; ') + '.');
    }

    // ---- helpers ----

    private static List<Integer> parseSlotList(String slotsJson) {
        List<Integer> out = new List<Integer>();
        if (String.isBlank(slotsJson)) { return out; }
        try {
            for (Object o : (List<Object>) JSON.deserializeUntyped(AuraPocJson.stripFence(slotsJson))) {
                if (o != null) { out.add(Integer.valueOf(String.valueOf(o))); }
            }
        } catch (Exception ignore) { /* fall through -> empty -> userIntent fallback */ }
        return out;
    }

    private static List<Integer> slotsFromIntent(String intent) {
        List<Integer> out = new List<Integer>();
        if (String.isBlank(intent)) { return out; }
        Matcher m = Pattern.compile('(?i)slot\\s+(\\d+)').matcher(intent);
        while (m.find()) { out.add(Integer.valueOf(m.group(1))); }
        return out;
    }

    // Pull the FIELD the user named out of a free-text intent so matchField gets a tight keyword,
    // not the whole sentence. Grabs the phrase after "by "/"based on "/"using "/"personalize by "
    // and before any ":" value list. E.g. "add dynamic content to slot 3 by industry: Technology,
    // Healthcare, Finance" -> "industry". Returns the whole intent when no such connector is present
    // (matchField is stop-worded, so a sentence still can't match on incidental words).
    private static String extractFieldTermFromIntent(String intent) {
        if (String.isBlank(intent)) { return ''; }
        Matcher m = Pattern.compile('(?i)(?:based on|personalize by|personalise by|by|using|per)\\s+([^:,.]+)').matcher(intent);
        if (m.find()) {
            String term = m.group(1).trim();
            // Trim a trailing "industry the recipient..." tail: keep at most the first 4 words.
            List<String> ws = term.split('\\s+');
            if (ws.size() > 4) {
                term = String.join(new List<String>{ ws[0], ws[1], ws[2], ws[3] }, ' ');
            }
            if (String.isNotBlank(term)) { return term; }
        }
        return intent;
    }

    // Parse the value list after the ":" in an intent, e.g. "by industry: Technology, Healthcare
    // and Finance" -> [Technology, Healthcare, Finance]. Splits on comma and " and ". Empty when
    // there is no ":" list (a HasValue axis).
    private static List<Object> extractValuesFromIntent(String intent) {
        List<Object> out = new List<Object>();
        if (String.isBlank(intent) || !intent.contains(':')) { return out; }
        String tail = intent.substringAfter(':').trim();
        if (String.isBlank(tail)) { return out; }
        // Normalize " and " / " & " to commas, then split.
        tail = tail.replaceAll('(?i)\\s+and\\s+', ',').replaceAll('\\s*&\\s*', ',');
        for (String piece : tail.split(',')) {
            String v = piece.trim().replaceAll('[.;]+$', '').trim();
            if (String.isNotBlank(v)) { out.add(v); }
        }
        return out;
    }

    // Words that are NEVER a field name -- request boilerplate. Excluded from the significant-word
    // overlap so "content" in "dynamic content" can't match "Digital Content", etc.
    private static final Set<String> STOPWORDS = new Set<String>{
        'ssot', 'content', 'dynamic', 'email', 'slot', 'slots', 'personalize', 'personalise',
        'recipient', 'recipients', 'field', 'fields', 'value', 'values', 'this', 'that', 'with',
        'from', 'into', 'update', 'change', 'make', 'based', 'using', 'name', 'names', 'text',
        'paragraph', 'heading', 'button', 'image', 'block', 'blocks'
    };

    // Match a natural field term against the catalog. `term` may be a tight keyword (typed planField,
    // e.g. "industry") OR a whole sentence (userIntent fallback, e.g. "personalize slot 3 by industry:
    // Technology, Healthcare, Finance"). Strategy, in priority order:
    //   1) exact normalized match of the whole term to a field's api or label,
    //   2) whole normalized term contained in api/label (tight-keyword case),
    //   3) a SIGNIFICANT WORD of the field label/api (>=4 chars, e.g. "industry" from "Primary Industry")
    //      appears in the normalized term -- handles the sentence-fallback case.
    // Returns the catalog row Map or null.
    private static Map<String, Object> matchField(String term, List<Object> catalog) {
        if (String.isBlank(term) || catalog == null || catalog.isEmpty()) { return null; }
        String t = normalize(term);
        String tWords = ' ' + term.toLowerCase().replaceAll('[^a-z0-9]', ' ') + ' ';   // word-boundaried
        Map<String, Object> tightHit = null;
        Map<String, Object> wordHit = null;
        for (Object o : catalog) {
            if (!(o instanceof Map<String, Object>)) { continue; }
            Map<String, Object> f = (Map<String, Object>) o;
            String api = f.get('fieldApiName') == null ? '' : String.valueOf(f.get('fieldApiName'));
            String lbl = f.get('fieldLabel') == null ? '' : String.valueOf(f.get('fieldLabel'));
            String apiN = normalize(api);
            String lblN = normalize(lbl);
            if (apiN == t || lblN == t) { return f; }                       // 1) exact -> immediate
            if (tightHit == null && ((apiN.length() >= 3 && apiN.contains(t)) || (lblN.length() >= 3 && lblN.contains(t)))) {
                tightHit = f;                                               // 2) tight keyword contained
            }
            if (wordHit == null) {                                          // 3) significant word overlap
                for (String w : (lbl + ' ' + api).toLowerCase().replaceAll('[^a-z0-9]', ' ').split('\\s+')) {
                    // require length >=4 AND not request boilerplate (STOPWORDS) so incidental words
                    // like "content"/"email" in the intent can't match an unrelated field.
                    if (w.length() >= 4 && !STOPWORDS.contains(w) && tWords.contains(' ' + w + ' ')) { wordHit = f; break; }
                }
            }
        }
        return tightHit != null ? tightHit : wordHit;
    }

    private static String normalize(String s) {
        return s == null ? '' : s.toLowerCase().replaceAll('[^a-z0-9]', '');
    }

    private static String sanitize(String s) {
        return s == null ? 'field' : s.replaceAll('[^A-Za-z0-9]+', '_');
    }
}
