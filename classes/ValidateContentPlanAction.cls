// Structural checks on a drafted plan, BEFORE the user is asked to approve it -- confirmed
// live that a plan with a missing textByDecision entry (or an invalid criteriaType/path)
// only ever surfaced as a failure at BUILD time, after the user had already said yes to a
// plan that was guaranteed to fail. Makes no callouts and creates nothing -- pure local JSON
// validation, reusing BuildDynamicEmailAction.buildDecisionCriteria so there's no risk of this
// validator and the real build disagreeing on what's valid.
public with sharing class ValidateContentPlanAction {

    public class Request {
        @InvocableVariable(label='Elements JSON' required=true)
        public String elementsJson;

        // JSON array of {ppName, ppLabel, decisionsJson, targetsJson} -- one entry per
        // independent personalization axis, same shape Build Dynamic Email expects. Omit for a
        // plain, unpersonalized plan.
        @InvocableVariable(label='Personalizations JSON')
        public String personalizationsJson;

        // The data graph resolved for this plan (blank if none). A plan with personalization but
        // no resolved graph is invalid -- it would build against a null graph and wire nothing.
        @InvocableVariable(label='Resolved Data Graph API Name')
        public String resolvedGraphApiName;

        // Flattened field catalog for the resolved graph ([{dmoName, fieldApiName, ...}]). When
        // present, every decision's (criteriaObjectApiName, criteriaFieldApiName) must appear in
        // it -- a defense-in-depth backstop to the same check in AssembleContentPlanAction.
        @InvocableVariable(label='Available Fields JSON')
        public String availableFieldsJson;

        // Every REQUIRED Build Dynamic Email input, re-checked here so validation is the single
        // consolidated "all required artifacts present" gate before confirm/build -- lists exactly
        // what is missing in one place, rather than surfacing as a build-time "Missing required
        // input parameter". Blank on any of these is a validation failure.
        @InvocableVariable(label='Workspace Id')
        public String workspaceId;
        @InvocableVariable(label='Title')
        public String title;
        @InvocableVariable(label='Subject Line')
        public String subjectLine;
        @InvocableVariable(label='Preheader')
        public String preheader;
        @InvocableVariable(label='Url Name')
        public String urlName;

        // UPDATE mode: the existing email's blocks (ReadDynamicEmailAction.blocksJson --
        // [{slot, id, def, text, contentKey, personalized}]) and the {elementKey, slot} bindings
        // (base_update_targetSlotsJson). When both are present this is an update; validate each
        // target's slot HERE, at plan time, so a bad slot is caught before the user approves --
        // wrong type, out of range, or already personalized -- rather than failing at build.
        @InvocableVariable(label='Existing Blocks JSON')
        public String emailBlocksJson;
        @InvocableVariable(label='Target Slots JSON')
        public String targetSlotsJson;
        // Non-blank when this is an UPDATE (the content key of the email being updated). The
        // authoritative "this is an update" signal -- set even if the model forgot to read the email
        // or bind slots, so validation can REQUIRE both instead of silently skipping the update guard.
        @InvocableVariable(label='Update Target Key')
        public String updateTargetKey;
    }

    public class Result {
        @InvocableVariable(label='Valid')
        public Boolean isValid;

        // JSON array of human-readable problem strings; empty array when valid.
        @InvocableVariable(label='Issues JSON')
        public String issuesJson;

        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    // Flatten the resolved graph's field catalog into "dmoName|fieldApiName" keys for O(1)
    // existence checks. Empty set = no catalog passed = treat as unverifiable (skip the check),
    // never as "all invalid".
    private static Set<String> buildAvailableFieldSet(String availableFieldsJson) {
        Set<String> out = new Set<String>();
        if (String.isBlank(availableFieldsJson)) { return out; }
        try {
            for (Object o : (List<Object>) JSON.deserializeUntyped(availableFieldsJson)) {
                Map<String, Object> f = (Map<String, Object>) o;
                out.add(String.valueOf(f.get('dmoName')) + '|' + String.valueOf(f.get('fieldApiName')));
            }
        } catch (Exception ignore) { /* malformed catalog -> unverifiable, not fatal */ }
        return out;
    }

    @InvocableMethod(label='Validate Content Plan' description='Checks a drafted content plan (elementsJson/personalizationsJson) for structural problems -- unfilled elements (empty text/url/contentKey), missing textByDecision entries, unknown element keys, invalid decision criteria, too many PersonalizationPoints or decisions -- before asking the user to approve it. Makes no changes and creates nothing.')
    public static List<Result> validateContentPlan(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result res = new Result();
            List<String> issues = new List<String>();
            // These meta fields (workspace/title/subject/preheader/url) are what BUILD needs to
            // CREATE a new email. An UPDATE reuses the existing email's shell -- it has its own
            // workspace/title/subject already -- so requiring them would wrongly stall every update
            // (confirmed live: an update stalled on "Missing required CMS workspace"). Skip the whole
            // build-meta check when this is an update (updateTargetKey present).
            Boolean isUpdateMode = String.isNotBlank(req.updateTargetKey);
            try {
                // Consolidated required-artifact check -- every input Build Dynamic Email requires,
                // asserted in one place so a blank is caught before confirm, not at build time.
                if (!isUpdateMode) {
                    Map<String, String> requiredMeta = new Map<String, String>{
                        'CMS workspace' => req.workspaceId,
                        'title' => req.title,
                        'subject line' => req.subjectLine,
                        'preheader' => req.preheader,
                        'URL slug' => req.urlName
                    };
                    for (String label : requiredMeta.keySet()) {
                        String v = requiredMeta.get(label);
                        if (String.isBlank(v) || v == 'null') {
                            issues.add('Missing required ' + label + ' -- it must be filled before building.');
                        }
                    }
                }

                Set<String> elementKeys = new Set<String>();
                List<Object> elements = (List<Object>) JSON.deserializeUntyped(AuraPocJson.stripFence(req.elementsJson));
                if (elements.isEmpty()) {
                    issues.add('The plan has no content elements to build.');
                }
                // Every element must be FILLED before build -- confirmed live that an empty text
                // slot (or an image with no contentKey) only surfaced as a build-time failure. Assert
                // it here so a blank element fails validation (and the build gate) up front, not at build.
                for (Object elObj : elements) {
                    Map<String, Object> el = (Map<String, Object>) elObj;
                    String key = String.valueOf(el.get('key'));
                    elementKeys.add(key);
                    String type = el.get('type') == null ? '' : String.valueOf(el.get('type'));
                    if (type == 'subject_preheader') {
                        // The subject/preheader COMPONENT has no base text/contentKey element -- the
                        // email's existing subject/preheader stay as the default and the per-decision
                        // variants (checked below) hold the overrides. Nothing to require on the element.
                    } else if (type == 'image') {
                        // UPDATE image DC: an image slot that personalizes an EXISTING block keeps that
                        // block's current image as its base -- the element carries no contentKey by design
                        // (the swap-per-decision variants, not this element, hold the images, and any
                        // decision without an assetName is auto-assigned a catalog image at build). So a
                        // blank contentKey on an image element is only a failure for a BUILD-mode invented
                        // image (no existing block behind it). Skip the requirement in update mode.
                        Boolean isUpdate = String.isNotBlank(req.updateTargetKey);
                        String ck = el.get('contentKey') == null ? '' : String.valueOf(el.get('contentKey'));
                        if (!isUpdate && (String.isBlank(ck) || ck == 'null' || !ck.startsWith('MC'))) {
                            issues.add('Element "' + key + '" (image) has no valid contentKey -- every element must be filled before building.');
                        }
                    } else {
                        String txt = el.get('text') == null ? '' : String.valueOf(el.get('text'));
                        if (String.isBlank(txt) || txt == 'null') {
                            issues.add('Element "' + key + '" (' + (String.isBlank(type) ? 'text' : type)
                                + ') has no text -- every element must be filled before building.');
                        }
                        if (type == 'button') {
                            String url = el.get('url') == null ? '' : String.valueOf(el.get('url'));
                            if (String.isBlank(url) || url == 'null') {
                                issues.add('Button element "' + key + '" has no link URL -- every element must be filled before building.');
                            }
                        }
                    }
                }

                if (String.isNotBlank(req.personalizationsJson)) {
                    List<Object> ppSpecs = (List<Object>) JSON.deserializeUntyped(AuraPocJson.stripFence(req.personalizationsJson));

                    // A personalized plan MUST have a resolved data graph to evaluate against --
                    // otherwise it builds against a null graph and silently wires no dynamic
                    // content. This is the deterministic backstop for the failure where a plan
                    // reached build with resolvedGraphApiName still empty.
                    if (!ppSpecs.isEmpty() && String.isBlank(req.resolvedGraphApiName)) {
                        issues.add('This plan is personalized but no data graph has been resolved to '
                            + 'evaluate the decisions against. Choose/confirm a data graph before building, '
                            + 'or drop personalization for a static email.');
                    }

                    // When a field catalog is present, every decision must reference a real
                    // (object, field) in the resolved graph. Backstops AssembleContentPlanAction's
                    // own drop step so an unverified field can never reach build.
                    Set<String> availableFields = buildAvailableFieldSet(req.availableFieldsJson);

                    if (ppSpecs.size() > BuildDynamicEmailAction.MAX_PPS_PER_EMAIL) {
                        issues.add('Plan has ' + ppSpecs.size() + ' PersonalizationPoints, but at most '
                            + BuildDynamicEmailAction.MAX_PPS_PER_EMAIL + ' are supported per email.');
                    }

                    // Confirmed live: a plan with two independent PersonalizationPoints that both
                    // target the same element (e.g. "tailor copy to each combination of persona
                    // AND tier" built as one PP per axis, both on the same paragraph) creates both
                    // PPs successfully, then fails at build time with "duplicate targetId in the
                    // operations array" -- one CMS block can carry only one PP operation. Catch
                    // this before approval instead of after two orphaned PersonalizationPoint
                    // records are already sitting in the org.
                    Map<String, List<String>> ppLabelsByElementKey = new Map<String, List<String>>();

                    for (Object ppSpecObj : ppSpecs) {
                        Map<String, Object> ppSpec = (Map<String, Object>) ppSpecObj;
                        String ppLabel = String.valueOf(ppSpec.get('ppLabel'));

                        List<Object> decisionSpecs;
                        List<Object> targetSpecs;
                        try {
                            decisionSpecs = (List<Object>) JSON.deserializeUntyped(String.valueOf(ppSpec.get('decisionsJson')));
                            targetSpecs = (List<Object>) JSON.deserializeUntyped(String.valueOf(ppSpec.get('targetsJson')));
                        } catch (Exception parseEx) {
                            issues.add('PersonalizationPoint "' + ppLabel + '": could not parse decisionsJson/targetsJson: ' + parseEx.getMessage());
                            continue;
                        }

                        if (decisionSpecs.size() > BuildDynamicEmailAction.MAX_DECISIONS_PER_PP) {
                            issues.add('PersonalizationPoint "' + ppLabel + '" has ' + decisionSpecs.size()
                                + ' decisions, but at most ' + BuildDynamicEmailAction.MAX_DECISIONS_PER_PP + ' are supported.');
                        }

                        List<String> decisionNames = new List<String>();
                        for (Object specObj : decisionSpecs) {
                            Map<String, Object> spec = (Map<String, Object>) specObj;
                            decisionNames.add(String.valueOf(spec.get('name')));
                            try {
                                BuildDynamicEmailAction.buildDecisionCriteria(spec);
                            } catch (Exception criteriaEx) {
                                issues.add('PersonalizationPoint "' + ppLabel + '" decision "' + spec.get('name') + '": ' + criteriaEx.getMessage());
                            }
                            if (!availableFields.isEmpty()) {
                                String objectApiName = String.valueOf(spec.get('criteriaObjectApiName'));
                                String fieldApiName = String.valueOf(spec.get('criteriaFieldApiName'));
                                if (!availableFields.contains(objectApiName + '|' + fieldApiName)) {
                                    issues.add('PersonalizationPoint "' + ppLabel + '" decision "' + spec.get('name')
                                        + '" references field "' + fieldApiName + '" on "' + objectApiName
                                        + '", which is not in the resolved data graph'
                                        + (String.isNotBlank(req.resolvedGraphApiName) ? ' "' + req.resolvedGraphApiName + '"' : '')
                                        + '. Only fields present in the graph can drive personalization.');
                                }
                            }
                        }

                        for (Object targetObj : targetSpecs) {
                            Map<String, Object> target = (Map<String, Object>) targetObj;
                            String elementKey = String.valueOf(target.get('elementKey'));
                            if (!elementKeys.contains(elementKey)) {
                                issues.add('PersonalizationPoint "' + ppLabel + '" target references unknown element key "' + elementKey
                                    + '" -- must match a "key" from elementsJson.');
                                continue;
                            }
                            if (!ppLabelsByElementKey.containsKey(elementKey)) {
                                ppLabelsByElementKey.put(elementKey, new List<String>());
                            }
                            ppLabelsByElementKey.get(elementKey).add(ppLabel);
                            String blockDefinition = target.get('blockDefinition') != null
                                ? String.valueOf(target.get('blockDefinition')) : 'lightning/paragraph';
                            Map<String, Object> textByDecision = (Map<String, Object>) target.get('textByDecision');

                            for (String decisionName : decisionNames) {
                                if (textByDecision == null || !textByDecision.containsKey(decisionName)) {
                                    issues.add('PersonalizationPoint "' + ppLabel + '" target "' + elementKey
                                        + '" is missing a rule for decision "' + decisionName + '".');
                                    continue;
                                }
                                if (blockDefinition == 'sfdc_cms__subjectPreheader') {
                                    // Subject/preheader component decision. Its variant is an OBJECT
                                    // carrying subjectLine and/or preheader (an empty {} = keep the base
                                    // for a non-applying decision). Only a non-object is invalid.
                                    Object decisionValue = textByDecision.get(decisionName);
                                    if (!(decisionValue instanceof Map<String, Object>)) {
                                        issues.add('PersonalizationPoint "' + ppLabel + '" target "' + elementKey
                                            + '" (subject/preheader) has an invalid variant for decision "' + decisionName
                                            + '" -- must be an object with subjectLine and/or preheader, not text.');
                                    }
                                } else if (blockDefinition == 'lightning/image') {
                                    // Image-swap decision. Its variant is an OBJECT that resolves to an
                                    // image at build: a literal contentKey, an assetName/assetRole (looked
                                    // up in the catalog), OR an empty {} which Build's resolveVariantImageRefs
                                    // deterministically AUTO-ASSIGNS a distinct catalog image to. So the only
                                    // invalid shape here is a non-object (e.g. a text string) -- an empty or
                                    // asset-ref object is valid and will be filled downstream. (Previously
                                    // this required a resolved contentKey at plan time, which blocked every
                                    // auto-assigned image swap from validating -> Confirm never appeared.)
                                    Object decisionValue = textByDecision.get(decisionName);
                                    if (!(decisionValue instanceof Map<String, Object>)) {
                                        issues.add('PersonalizationPoint "' + ppLabel + '" target "' + elementKey
                                            + '" (image) has an invalid variant for decision "' + decisionName
                                            + '" -- an image variant must be an object (assetName/contentKey or empty for auto-assign), not text.');
                                    }
                                }
                            }
                        }
                    }

                    for (String elementKey : ppLabelsByElementKey.keySet()) {
                        List<String> labels = ppLabelsByElementKey.get(elementKey);
                        if (labels.size() > 1) {
                            issues.add('Element "' + elementKey + '" is targeted by ' + labels.size()
                                + ' PersonalizationPoints (' + String.join(labels, ', ') + '), but a CMS block can '
                                + 'only carry one PersonalizationPoint operation -- this will create every '
                                + 'PersonalizationPoint successfully and then fail at build time with '
                                + '"duplicate targetId in the operations array", leaving the extra '
                                + 'PersonalizationPoints orphaned. Combine these into ONE PersonalizationPoint '
                                + 'whose decisions use compound (AND) criteria for each real combination, or '
                                + 'target separate elements/paragraphs instead.');
                        }
                    }
                }
                // UPDATE-mode validation -- keyed off updateTargetKey (the authoritative update
                // signal), NOT off whether bindings happen to be present. This is the fix for the
                // model skipping note_update_targets: previously the guard only ran when slot bindings
                // existed, so a forgotten binding silently passed and failed at build ("matched no
                // block"). Now, when it's an update with personalizations, we REQUIRE the read blocks
                // and the slot bindings, and validate every axis is bound to a good slot.
                Boolean isUpdate = String.isNotBlank(req.updateTargetKey);
                Boolean hasPersonalization = String.isNotBlank(req.personalizationsJson)
                    && req.personalizationsJson != '[]' && req.personalizationsJson != 'null';
                // An UPDATE that reaches validate with NO surviving personalization (every axis was
                // dropped -- e.g. the only requested slot was ineligible) must NOT pass vacuously:
                // there is nothing to apply. Fail loud instead of a silent "valid" empty update.
                if (isUpdate && !hasPersonalization) {
                    // Name the real cause specifically, in priority order:
                    // (a) subject/preheader already personalized (a targetId-less op exists) -- the exact
                    //     case where a "personalize the subject line + preheader" request produced nothing;
                    // (b) every text area already personalized (no free heading/paragraph/button slot);
                    // else the generic reason.
                    String reason;
                    if (subjectPreheaderAlreadyPersonalized(req.emailBlocksJson)) {
                        reason = 'This update produced no personalization to apply because the subject line '
                          + '+ preheader on this email are already personalized by an existing axis. A '
                          + 'component can carry only one personalization, and editing existing dynamic '
                          + 'content is not supported -- to vary the subject/preheader differently, use an '
                          + 'email whose subject line + preheader are not yet personalized.';
                    } else if (allEligibleTextAlreadyPersonalized(req.emailBlocksJson)) {
                        reason = 'This update produced no personalization to apply because every text area on '
                          + 'this email is already personalized -- there is no free heading/paragraph/button '
                          + 'slot to add new dynamic content to (editing existing dynamic content is not '
                          + 'supported). Choose an email with an unpersonalized text area, or a different slot.';
                    } else {
                        reason = 'This update produced no personalization to apply -- the requested slot(s) '
                          + 'may be ineligible (image or already personalized) or the field could not be '
                          + 'resolved. Choose an eligible slot and a valid field, then try again.';
                    }
                    issues.add(reason);
                }
                if (isUpdate && hasPersonalization) {
                    Boolean haveBlocks = String.isNotBlank(req.emailBlocksJson) && req.emailBlocksJson != '[]';
                    Boolean haveSlots = String.isNotBlank(req.targetSlotsJson) && req.targetSlotsJson != '[]';
                    // Whether ANY axis targets a real BLOCK (needs a slot binding) vs ONLY the
                    // subject/preheader component (a metadata target with no slot). A subject/preheader-only
                    // update legitimately has no slot bindings, so don't demand them.
                    Boolean hasBlockAxis = updateHasBlockTarget(req.personalizationsJson);
                    // Subject/preheader RE-personalization guard. A subject/preheader-only update
                    // (no block axis) whose email ALREADY carries a subject/preheader op will fail at
                    // the CMS PUT with "nullTargetId is a duplicate targetId in the operations array"
                    // (a component can hold only ONE personalization; the targetId-less op collides).
                    // hasPersonalization is TRUE here (a fresh subject/preheader op survived), so the
                    // !hasPersonalization vacuous guard above never catches it -- without this branch the
                    // user sees a raw HTTP 400 instead of a friendly refusal. Refuse loud BEFORE build.
                    if (!hasBlockAxis && subjectPreheaderAlreadyPersonalized(req.emailBlocksJson)) {
                        issues.add('This update cannot be applied because the subject line + preheader on '
                          + 'this email are already personalized by an existing axis. A component can carry '
                          + 'only one personalization, and editing existing dynamic content is not supported '
                          + '-- to vary the subject/preheader differently, use an email whose subject line + '
                          + 'preheader are not yet personalized.');
                    }
                    if (!haveBlocks) {
                        issues.add('This is an update to an existing email, but its blocks were not read. '
                            + 'Read the email first (Read Dynamic Email) so its slots are known.');
                    }
                    if (hasBlockAxis && !haveSlots) {
                        issues.add('This is an update, but no slots were chosen. Call note_update_targets '
                            + 'with an {elementKey, slot} pair for EVERY personalization axis, choosing '
                            + 'existing, not-already-personalized slots by number.');
                    }
                    if (haveBlocks && haveSlots) {
                        validateUpdateSlots(req.emailBlocksJson, req.targetSlotsJson, req.personalizationsJson, issues);
                    }
                }
            } catch (Exception e) {
                issues.add('Could not validate: ' + e.getMessage());
            }
            res.isValid = issues.isEmpty();
            res.issuesJson = JSON.serialize(issues);
            // Also surface the reason as a plain string so the .agent can map it to base_error_pipeline
            // (the var the stall-report reasoning reads). Previously errorMessage was left blank on a
            // validation stall, so a validate-origin stall had an EMPTY pipeline reason -- the stall
            // report rendered with no cause and the confirm summary slipped through. Now every validate
            // failure carries an actionable reason (the issues, joined) for that surfacing.
            res.errorMessage = issues.isEmpty() ? '' : String.join(issues, ' ');
            results.add(res);
        }
        return results;
    }

    // True when the email HAS text areas (heading/paragraph/button) but EVERY one of them is already
    // personalized -- i.e. there is no free text slot to add a new axis to (the common cause of a
    // vacuous update, e.g. translate on an already-personalized email). Mirrors the eligibility rule:
    // text = def heading/paragraph/actionButton AND role != logo/footer; images are not text. Returns
    // false if we can't tell (no/unparseable blocks, or no text areas at all) so the generic reason is used.
    private static Boolean allEligibleTextAlreadyPersonalized(String emailBlocksJson) {
        if (String.isBlank(emailBlocksJson) || emailBlocksJson == '[]') { return false; }
        Set<String> TEXT_DEFS = new Set<String>{ 'lightning/heading', 'lightning/paragraph', 'lightning/actionButton' };
        Integer textCount = 0;
        Integer freeText = 0;
        try {
            for (Object o : (List<Object>) JSON.deserializeUntyped(AuraPocJson.stripFence(emailBlocksJson))) {
                if (!(o instanceof Map<String, Object>)) { continue; }
                Map<String, Object> b = (Map<String, Object>) o;
                String def = b.get('def') == null ? '' : String.valueOf(b.get('def'));
                String role = b.get('role') == null ? '' : String.valueOf(b.get('role'));
                if (!TEXT_DEFS.contains(def)) { continue; }         // not a text area
                if (role == 'footer' || role == 'logo') { continue; } // boilerplate/mark -- not axis-eligible
                textCount++;
                if (b.get('personalized') != true) { freeText++; }
            }
        } catch (Exception ignore) { return false; }
        return textCount > 0 && freeText == 0;   // has text areas, none free
    }

    // True when the read blocks carry the subject/preheader sentinel row (added by ReadDynamicEmailAction)
    // marked personalized -- i.e. a targetId-less op already personalizes the subject line + preheader, so
    // a new subject/preheader axis can't be added. Lets a vacuous subject/preheader update explain itself.
    private static Boolean subjectPreheaderAlreadyPersonalized(String emailBlocksJson) {
        if (String.isBlank(emailBlocksJson) || emailBlocksJson == '[]') { return false; }
        try {
            for (Object o : (List<Object>) JSON.deserializeUntyped(AuraPocJson.stripFence(emailBlocksJson))) {
                if (!(o instanceof Map<String, Object>)) { continue; }
                Map<String, Object> b = (Map<String, Object>) o;
                if (String.valueOf(b.get('type')) == 'subject_preheader' && b.get('personalized') == true) {
                    return true;
                }
            }
        } catch (Exception ignore) { return false; }
        return false;
    }

    // True if any personalization axis targets a real BLOCK (heading/paragraph/button/image) -- which
    // needs a slot binding. Returns false when the ONLY target is the subject/preheader component
    // (blockDefinition sfdc_cms__subjectPreheader / elementKey subject_preheader), which has no slot.
    private static Boolean updateHasBlockTarget(String personalizationsJson) {
        try {
            for (Object ppObj : (List<Object>) JSON.deserializeUntyped(AuraPocJson.stripFence(personalizationsJson))) {
                if (!(ppObj instanceof Map<String, Object>)) { continue; }
                Object tj = ((Map<String, Object>) ppObj).get('targetsJson');
                if (tj == null) { continue; }
                for (Object tObj : (List<Object>) JSON.deserializeUntyped(String.valueOf(tj))) {
                    if (!(tObj instanceof Map<String, Object>)) { continue; }
                    Map<String, Object> t = (Map<String, Object>) tObj;
                    String def = t.get('blockDefinition') == null ? '' : String.valueOf(t.get('blockDefinition'));
                    String ek = t.get('elementKey') == null ? '' : String.valueOf(t.get('elementKey'));
                    if (def != 'sfdc_cms__subjectPreheader' && ek != 'subject_preheader') { return true; }
                }
            }
        } catch (Exception ignore) { return true; /* on parse trouble, keep the stricter (block) requirement */ }
        return false;
    }

    // Plan-time mirror of UpdateDynamicEmailAction's slot guards: for each {elementKey, slot} binding,
    // confirm the slot exists, matches the axis's block type, and is not already personalized -- adding
    // a specific issue (which stalls the plan) instead of letting it fail at build. emailBlocksJson
    // is ReadDynamicEmailAction's output ([{slot, def, personalized, ...}] over content blocks only).
    private static void validateUpdateSlots(String emailBlocksJson, String targetSlotsJson,
            String personalizationsJson, List<String> issues) {
        // Existing content slots, keyed by slot number.
        Map<Integer, Map<String, Object>> bySlot = new Map<Integer, Map<String, Object>>();
        Integer slotCount = 0;
        try {
            for (Object o : (List<Object>) JSON.deserializeUntyped(AuraPocJson.stripFence(emailBlocksJson))) {
                if (!(o instanceof Map<String, Object>)) { continue; }
                Map<String, Object> b = (Map<String, Object>) o;
                if (b.get('slot') == null) { continue; }
                Integer s = Integer.valueOf(String.valueOf(b.get('slot')));
                bySlot.put(s, b);
                if (s > slotCount) { slotCount = s; }
            }
        } catch (Exception ignore) { return; /* unparseable -> Update's own guards still backstop */ }

        // Each axis's expected block type, from the plan's targets (elementKey -> blockDefinition).
        Map<String, String> defByElementKey = new Map<String, String>();
        if (String.isNotBlank(personalizationsJson)) {
            try {
                for (Object ppObj : (List<Object>) JSON.deserializeUntyped(AuraPocJson.stripFence(personalizationsJson))) {
                    Map<String, Object> pp = (Map<String, Object>) ppObj;
                    for (Object tObj : (List<Object>) JSON.deserializeUntyped(String.valueOf(pp.get('targetsJson')))) {
                        Map<String, Object> t = (Map<String, Object>) tObj;
                        defByElementKey.put(String.valueOf(t.get('elementKey')),
                            t.get('blockDefinition') == null ? '' : String.valueOf(t.get('blockDefinition')));
                    }
                }
            } catch (Exception ignore) { /* leave types unknown -> type check skipped */ }
        }

        Set<String> boundElementKeys = new Set<String>();
        try {
            for (Object o : (List<Object>) JSON.deserializeUntyped(AuraPocJson.stripFence(targetSlotsJson))) {
                if (!(o instanceof Map<String, Object>)) { continue; }
                Map<String, Object> pair = (Map<String, Object>) o;
                if (pair.get('elementKey') == null || pair.get('slot') == null) { continue; }
                String ek = String.valueOf(pair.get('elementKey'));
                boundElementKeys.add(ek);
                Integer slotNum;
                try { slotNum = Integer.valueOf(String.valueOf(pair.get('slot'))); }
                catch (Exception ignore) { issues.add('Update target "' + ek + '" has a non-numeric slot.'); continue; }

                if (!bySlot.containsKey(slotNum)) {
                    issues.add('Update target "' + ek + '" points at slot ' + slotNum + ', but this email has only '
                        + slotCount + ' content slot(s). Read the email and pick an existing slot number.');
                    continue;
                }
                Map<String, Object> blk = bySlot.get(slotNum);
                String blkDef = String.valueOf(blk.get('def'));
                String wantDef = defByElementKey.get(ek);
                if (String.isNotBlank(wantDef) && wantDef != blkDef) {
                    issues.add('Update target "' + ek + '" expects a ' + wantDef + ' but slot ' + slotNum
                        + ' is a ' + blkDef + '. Bind this axis to a slot of the matching type.');
                }
                if (blk.get('personalized') == true) {
                    issues.add('Slot ' + slotNum + ' already has dynamic content -- editing an existing '
                        + 'personalized block is not supported. Choose a slot that is not already personalized.');
                }
            }
        } catch (Exception ignore) { /* unparseable bindings -> Update's guards still backstop */ }

        // EVERY personalization axis in an update MUST be bound to a slot. An axis in the plan with no
        // {elementKey, slot} binding (e.g. an unrequested greeting the model added, or a binding it
        // forgot) would fall through to the brittle matchText path at build and fail "matched no
        // block". Catch it HERE so the plan is rejected before approval -- the agent must bind it to an
        // eligible slot or drop the axis. This is the deterministic backstop for LLM over-planning.
        for (String ek : defByElementKey.keySet()) {
            if (!boundElementKeys.contains(ek)) {
                issues.add('Update axis "' + ek + '" has no slot binding. For an update, every '
                    + 'personalization must target an existing slot by number (note_update_targets). '
                    + 'Bind it to an eligible slot, or remove this axis if it was not requested.');
            }
        }
    }
}