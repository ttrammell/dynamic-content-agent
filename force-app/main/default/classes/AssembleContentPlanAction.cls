// Deterministically merges Stage 1 (Plan Email Structure -- slots + personalization needs)
// and Stage 2 (Write Email Copy -- the actual words) into the elementsJson/decisionsJson/
// targetsJson shape Build Dynamic Email expects. No LLM callout here -- every mapping below
// (scope -> criteriaObjectApiName/criteriaPath, matchType -> criteriaType, slot type ->
// blockDefinition) is a fixed lookup, not a model decision, per the "LLM only for planning and
// creative text, everything else deterministic" rule this whole build follows.
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

        // Null when the structure plan had no personalizations -- caller should omit
        // decisionsJson/targetsJson from Build Dynamic Email in that case.
        @InvocableVariable(label='Decisions JSON')
        public String decisionsJson;

        @InvocableVariable(label='Targets JSON')
        public String targetsJson;

        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    public class AssembleException extends Exception {}

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

    @InvocableMethod(label='Assemble Content Plan' description='Deterministically merges a structure plan (from Plan Email Structure) and its written copy (from Write Email Copy) into the elementsJson/decisionsJson/targetsJson shape Build Dynamic Email expects. Makes no callouts and creates nothing.')
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

                List<Object> decisions = new List<Object>();
                List<String> decisionNames = new List<String>();
                Map<String, Set<String>> slotKeysByDecisionName = new Map<String, Set<String>>();
                Set<String> targetSlotKeys = new Set<String>();

                for (Object pObj : personalizations) {
                    Map<String, Object> p = (Map<String, Object>) pObj;
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
                res.decisionsJson = JSON.serialize(decisions);

                // Every slot targeted by at least one personalization becomes a target -- and
                // per the platform's own PersonalizationPoint model (confirmed in
                // BuildDynamicEmailAction), EVERY target must carry a variant for EVERY
                // decision, not just the ones logically scoped to it. Decisions that don't
                // apply to a given slot simply fall back to that slot's default copy.
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
                        Boolean hasOverride = appliesToThisSlot != null && appliesToThisSlot.contains(slotKey)
                            && byPersonalization.containsKey(decisionName);
                        textByDecision.put(decisionName, hasOverride ? byPersonalization.get(decisionName) : defaultText);
                    }

                    targets.add(new Map<String, Object>{
                        'elementKey' => slotKey,
                        'blockDefinition' => SLOT_TYPE_TO_BLOCK_DEFINITION.get(slotType),
                        'textByDecision' => textByDecision
                    });
                }
                res.targetsJson = JSON.serialize(targets);
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