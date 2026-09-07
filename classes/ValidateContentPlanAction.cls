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

    @InvocableMethod(label='Validate Content Plan' description='Checks a drafted content plan (elementsJson/personalizationsJson) for structural problems -- missing textByDecision entries, unknown element keys, invalid decision criteria, too many PersonalizationPoints or decisions -- before asking the user to approve it. Makes no changes and creates nothing.')
    public static List<Result> validateContentPlan(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result res = new Result();
            List<String> issues = new List<String>();
            try {
                Set<String> elementKeys = new Set<String>();
                List<Object> elements = (List<Object>) JSON.deserializeUntyped(req.elementsJson);
                for (Object elObj : elements) {
                    Map<String, Object> el = (Map<String, Object>) elObj;
                    elementKeys.add(String.valueOf(el.get('key')));
                }

                if (String.isNotBlank(req.personalizationsJson)) {
                    List<Object> ppSpecs = (List<Object>) JSON.deserializeUntyped(req.personalizationsJson);

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
                                if (blockDefinition == 'lightning/image') {
                                    Object decisionValue = textByDecision.get(decisionName);
                                    String contentKey = (decisionValue instanceof Map<String, Object>)
                                        ? String.valueOf(((Map<String, Object>) decisionValue).get('contentKey')) : null;
                                    if (String.isBlank(contentKey) || contentKey == 'null') {
                                        issues.add('PersonalizationPoint "' + ppLabel + '" target "' + elementKey
                                            + '" (image) is missing a valid contentKey for decision "' + decisionName + '".');
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
            } catch (Exception e) {
                issues.add('Could not validate: ' + e.getMessage());
            }
            res.isValid = issues.isEmpty();
            res.issuesJson = JSON.serialize(issues);
            results.add(res);
        }
        return results;
    }
}