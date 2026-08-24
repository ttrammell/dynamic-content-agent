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

        @InvocableVariable(label='Elements JSON')
        public String elementsJson;

        // JSON array of {ppName, ppLabel, decisionsJson, targetsJson} -- one entry per
        // independent personalization axis. Null/omitted when the structure plan had no
        // personalizations. Pass straight through to Build Dynamic Email's personalizationsJson.
        @InvocableVariable(label='Personalizations JSON')
        public String personalizationsJson;

        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    public class AssembleException extends Exception {}

    private static final Integer MAX_PPS_PER_EMAIL = 3;
    private static final Integer MAX_DECISIONS_PER_PP = 10;

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

    @InvocableMethod(label='Assemble Content Plan' description='Deterministically merges a structure plan (from Plan Email Structure) and its written copy (from Write Email Copy) into the elementsJson/personalizationsJson shape Build Dynamic Email expects -- one PersonalizationPoint per independent personalization axis. Makes no callouts and creates nothing.')
    public static List<Result> assembleContentPlan(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result res = new Result();
            try {
                Map<String, Object> plan = (Map<String, Object>) JSON.deserializeUntyped(req.structurePlanJson);
                Map<String, Object> copy = (Map<String, Object>) JSON.deserializeUntyped(req.copyJson);

                res.title = String.valueOf(copy.get('title'));
                res.subjectLine = String.valueOf(copy.get('subjectLine'));
                res.preheader = String.valueOf(copy.get('preheader'));

                Map<String, Object> copyBySlot = copy.get('copyBySlot') instanceof Map<String, Object>
                    ? (Map<String, Object>) copy.get('copyBySlot') : new Map<String, Object>();
                List<Object> slots = plan.get('slots') instanceof List<Object>
                    ? (List<Object>) plan.get('slots') : new List<Object>();
                List<Object> personalizations = plan.get('personalizations') instanceof List<Object>
                    ? (List<Object>) plan.get('personalizations') : new List<Object>();

                Set<String> slotKeys = new Set<String>();
                Map<String, String> slotTypeByKey = new Map<String, String>();
                List<Object> elements = new List<Object>();

                for (Object slotObj : slots) {
                    Map<String, Object> slot = (Map<String, Object>) slotObj;
                    String key = String.valueOf(slot.get('key'));
                    String type = String.valueOf(slot.get('type'));
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

                if (personalizations.isEmpty()) {
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

                if (groupKeysInOrder.size() > MAX_PPS_PER_EMAIL) {
                    throw new AssembleException('This plan needs ' + groupKeysInOrder.size()
                        + ' independent personalization rule sets (one per distinct field), but at most '
                        + MAX_PPS_PER_EMAIL + ' personalization points are supported per email -- '
                        + 'ask the user to drop or combine some personalizations.');
                }

                List<Object> ppSpecs = new List<Object>();
                for (String groupKey : groupKeysInOrder) {
                    List<Map<String, Object>> groupMembers = groups.get(groupKey);
                    if (groupMembers.size() > MAX_DECISIONS_PER_PP) {
                        throw new AssembleException('Personalization axis "' + groupKey + '" has ' + groupMembers.size()
                            + ' decisions, but at most ' + MAX_DECISIONS_PER_PP + ' are supported per personalization point -- '
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
                        if (p.get('value') != null) {
                            decision.put('value', p.get('value'));
                        }
                        if (p.get('values') != null) {
                            decision.put('values', p.get('values'));
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
                    ppSpecs.add(new Map<String, Object>{
                        'ppName' => seedLabel.replaceAll('[^A-Za-z0-9]+', '_'),
                        'ppLabel' => seedLabel,
                        'decisionsJson' => JSON.serialize(decisions),
                        'targetsJson' => JSON.serialize(targets)
                    });
                }

                res.personalizationsJson = JSON.serialize(ppSpecs);
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