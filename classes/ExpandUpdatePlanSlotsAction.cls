// Deterministic "all eligible slots" expander for UPDATE plans. Runs AFTER the planner and BEFORE
// FillCopy, so the copy step sees the full expanded slot list and generates copy for every slot.
//
// Why this exists: the create-planner LLM only receives the user's words (userIntent), NOT the
// existing email's real slot NUMBERS, so it cannot emit slot1/slot2/... for "personalize all
// eligible slots". Instead the prompt has it set applyToAllEligible:true on the personalization
// when the user says all/every/each. This action then does the enumeration the LLM can't: it reads
// the email's real blocks and expands that personalization to EVERY eligible slot (unpersonalized,
// non-image text block), adding the matching slot<N> entries to slots[] so FillCopy fills them.
//
// The explicit multi-slot path (appliesToSlots already listing slot1/slot2/...) already works; this
// just synthesizes that list deterministically for the "all" intent. No LLM callout.
public with sharing class ExpandUpdatePlanSlotsAction {

    public class Request {
        @InvocableVariable(label='Structure Plan JSON' required=true)
        public String structurePlanJson;
        // Existing email blocks from ReadDynamicEmailAction ([{slot,def,personalized,text}]).
        @InvocableVariable(label='Existing Blocks JSON')
        public String emailBlocksJson;
        // The update target key -- when set and blocks are blank/unparseable, re-read (self-heal,
        // same reason as AssembleContentPlanAction: the agent runtime can corrupt the passed blocks).
        @InvocableVariable(label='Update Target Key')
        public String updateTargetKey;
        // The user's request text -- lets us detect an "all/every/each eligible slot" intent even
        // when the planner ignored the applyToAllEligible flag (Option-3 deterministic repair).
        @InvocableVariable(label='User Intent')
        public String userIntent;
    }

    public class Result {
        @InvocableVariable(label='Success')
        public Boolean success;
        // The plan with any applyToAllEligible personalization expanded across all eligible slots.
        // Equals the input plan unchanged when nothing needed expanding.
        @InvocableVariable(label='Expanded Plan JSON')
        public String expandedPlanJson;
        @InvocableVariable(label='Note')
        public String note;
    }

    // Read-block def -> plan slot type (image excluded: not text-personalizable).
    private static final Map<String, String> BLOCK_DEF_TO_SLOT_TYPE = new Map<String, String>{
        'lightning/heading' => 'heading',
        'lightning/paragraph' => 'paragraph',
        'lightning/actionButton' => 'button'
    };

    @InvocableMethod(label='Expand Update Plan Slots' description='UPDATE-only: expands a personalization flagged applyToAllEligible across every eligible existing slot (unpersonalized, non-image), adding the real slot numbers to the plan before copy is filled. Deterministic, no callout. Pass-through when nothing is flagged.')
    public static List<Result> expand(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result res = new Result();
            res.success = true;
            res.expandedPlanJson = req.structurePlanJson == null ? '' : req.structurePlanJson;
            res.note = '';
            try {
                expandPlan(req, res);
            } catch (Exception e) {
                // Never block the pipeline: on any error, pass the plan through unchanged.
                res.success = true;
                res.expandedPlanJson = req.structurePlanJson == null ? '' : req.structurePlanJson;
                res.note = 'Expansion skipped: ' + e.getMessage();
            }
            results.add(res);
        }
        return results;
    }

    private static void expandPlan(Request req, Result res) {
        if (String.isBlank(req.structurePlanJson)) { return; }
        Object planObj;
        try { planObj = JSON.deserializeUntyped(AuraPocJson.stripFence(req.structurePlanJson)); }
        catch (Exception e) { return; }   // unparseable plan -> pass through
        if (!(planObj instanceof Map<String, Object>)) { return; }
        Map<String, Object> plan = (Map<String, Object>) planObj;

        List<Object> personalizations = plan.get('personalizations') instanceof List<Object>
            ? (List<Object>) plan.get('personalizations') : new List<Object>();
        // Detect the "all eligible slots" intent from EITHER the planner's flag OR the request text
        // (Option-3 deterministic repair: the create-planner often ignores the flag and invents its
        // own slot keys for an "all" request, so we key off userIntent too and remap to reality).
        Boolean anyAll = false;
        for (Object pObj : personalizations) {
            if (pObj instanceof Map<String, Object> && ((Map<String, Object>) pObj).get('applyToAllEligible') == true) {
                anyAll = true; break;
            }
        }
        Boolean intentAll = intentSaysAllEligible(req.userIntent);
        if (!anyAll && !intentAll) { return; }   // nothing to do -> pass through

        // Resolve the eligible slots from the REAL blocks (self-heal re-read if the passed blocks are
        // blank or don't parse -- same runtime-corruption guard as AssembleContentPlanAction).
        List<Object> blocks = parseBlocks(req.emailBlocksJson);
        if (blocks.isEmpty() && String.isNotBlank(req.updateTargetKey)) {
            blocks = reReadBlocks(req.updateTargetKey);
        }
        if (blocks.isEmpty()) { return; }   // no blocks -> can't expand, pass through (assemble will fail loud)

        // eligible slot number -> its slot type (heading/paragraph/button), in document order.
        List<Integer> eligibleSlots = new List<Integer>();
        Map<Integer, String> typeBySlot = new Map<Integer, String>();
        for (Object o : blocks) {
            if (!(o instanceof Map<String, Object>)) { continue; }
            Map<String, Object> b = (Map<String, Object>) o;
            if (b.get('slot') == null || b.get('def') == null) { continue; }
            if (b.get('personalized') == true) { continue; }
            String def = String.valueOf(b.get('def'));
            if (!BLOCK_DEF_TO_SLOT_TYPE.containsKey(def)) { continue; }   // image / unknown
            // Honor ReadDynamicEmailAction's role classification: never sweep a logo or a footer/
            // boilerplate paragraph into "all eligible" -- those must not vary by a content axis.
            // (role is absent on older reads -> treated as body text, preserving prior behavior.)
            String role = b.get('role') == null ? '' : String.valueOf(b.get('role'));
            if (role == 'logo' || role == 'footer') { continue; }
            Integer sn = Integer.valueOf(String.valueOf(b.get('slot')));
            eligibleSlots.add(sn);
            typeBySlot.put(sn, BLOCK_DEF_TO_SLOT_TYPE.get(def));
        }
        if (eligibleSlots.isEmpty()) { return; }

        // The real slot keys for every eligible slot, in document order.
        List<Object> allKeys = new List<Object>();
        for (Integer sn : eligibleSlots) { allKeys.add('slot' + sn); }

        // REBUILD slots[] from the real eligible slots (discarding any invented keys the planner
        // produced -- for an "all" request they don't map to real blocks anyway). One clean slot
        // entry per eligible slot, typed from the real block.
        List<Object> newSlots = new List<Object>();
        for (Integer sn : eligibleSlots) {
            newSlots.add(new Map<String, Object>{
                'key' => 'slot' + sn,
                'type' => typeBySlot.get(sn),
                'goal' => 'Personalize this existing ' + typeBySlot.get(sn) + ' per the requested field.'
            });
        }

        // Point EVERY axis at every eligible slot. When intentAll (request said "all") we treat every
        // personalization as all-eligible even if unflagged; when only the flag was set, expand just
        // the flagged ones (and leave others as the planner placed them -- but for safety, if intentAll
        // is false we only touch flagged axes and keep the planner's slots for the rest).
        Integer expandedCount = 0;
        for (Object pObj : personalizations) {
            if (!(pObj instanceof Map<String, Object>)) { continue; }
            Map<String, Object> p = (Map<String, Object>) pObj;
            Boolean thisAll = intentAll || (p.get('applyToAllEligible') == true);
            if (!thisAll) { continue; }
            p.put('appliesToSlots', allKeys.clone());
            p.remove('applyToAllEligible');   // consumed
            expandedCount++;
        }

        // Only replace slots wholesale when the intent was a clear "all" request (or every axis got
        // expanded); otherwise keep the planner's slots and just ensure the flagged axes' slots exist.
        if (intentAll || expandedCount == personalizations.size()) {
            plan.put('slots', newSlots);
        } else {
            // Flag-only, mixed: merge the eligible slot entries into the existing slots list.
            List<Object> slots = plan.get('slots') instanceof List<Object>
                ? (List<Object>) plan.get('slots') : new List<Object>();
            Set<String> have = new Set<String>();
            for (Object sObj : slots) {
                if (sObj instanceof Map<String, Object>) {
                    Object k = ((Map<String, Object>) sObj).get('key');
                    if (k != null) { have.add(String.valueOf(k)); }
                }
            }
            for (Integer sn : eligibleSlots) {
                if (!have.contains('slot' + sn)) {
                    slots.add(new Map<String, Object>{ 'key' => 'slot' + sn, 'type' => typeBySlot.get(sn),
                        'goal' => 'Personalize this existing ' + typeBySlot.get(sn) + ' per the requested field.' });
                }
            }
            plan.put('slots', slots);
        }
        plan.put('personalizations', personalizations);
        res.expandedPlanJson = JSON.serialize(plan);
        res.note = expandedCount > 0
            ? ('Expanded ' + expandedCount + ' personalization axis/axes across ' + eligibleSlots.size()
               + ' eligible slot(s): ' + slotList(eligibleSlots) + '.')
            : '';
    }

    // True when the request clearly asks to personalize ALL/EVERY/EACH eligible slot(s), rather than
    // naming specific numbers -- the case the planner can't enumerate (it lacks the slot numbers).
    private static Boolean intentSaysAllEligible(String intent) {
        if (String.isBlank(intent)) { return false; }
        String t = intent.toLowerCase();
        // "all ... slot", "every ... slot", "each ... slot", or "all eligible"
        if (Pattern.compile('(?is)\\b(all|every|each)\\b.{0,30}\\bslots?\\b').matcher(t).find()) { return true; }
        if (Pattern.compile('(?is)\\b(all|every|each)\\b.{0,20}\\beligible\\b').matcher(t).find()) { return true; }
        // A whole-email TRANSLATE is inherently an all-eligible-slots operation (one Country axis
        // across every text slot). Without this, a translate intent -- which says neither "all" nor
        // "every slot" -- skipped this remap, so the planner's INVENTED slot keys (e.g. "greeting_heading",
        // "intro_paragraph", "cta") were passed through unchanged and never mapped to the real slot1..N
        // keys; assemble then threw "references unknown slot key" -> zero personalizations -> the update
        // stalled with "no personalization to apply". Confirmed live: the EMPTY-PLAN translate runs
        // carried appliesToSlots=["greeting_heading",...] against a slot1..7 email. Stem 'translat'
        // covers translate/translated/translating/translation/translations.
        if (t.contains('translat') || t.contains('multilingual') || t.contains('multi-lingual')
                || t.contains('multi lingual')) { return true; }
        return false;
    }

    private static List<Object> parseBlocks(String blocksJson) {
        if (String.isBlank(blocksJson) || blocksJson == '[]') { return new List<Object>(); }
        try {
            Object o = JSON.deserializeUntyped(AuraPocJson.stripFence(blocksJson));
            return (o instanceof List<Object>) ? (List<Object>) o : new List<Object>();
        } catch (Exception e) { return new List<Object>(); }
    }

    private static List<Object> reReadBlocks(String contentKey) {
        try {
            ReadDynamicEmailAction.Request rr = new ReadDynamicEmailAction.Request();
            rr.contentKey = contentKey;
            List<ReadDynamicEmailAction.Result> rres =
                ReadDynamicEmailAction.readDynamicEmail(new List<ReadDynamicEmailAction.Request>{ rr });
            if (rres != null && !rres.isEmpty()) { return parseBlocks(rres[0].blocksJson); }
        } catch (Exception e) { /* fall through */ }
        return new List<Object>();
    }

    private static String slotList(List<Integer> slots) {
        List<String> parts = new List<String>();
        for (Integer s : slots) { parts.add('slot ' + s); }
        return String.join(parts, ', ');
    }
}
