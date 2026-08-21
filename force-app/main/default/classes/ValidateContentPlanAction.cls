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

        @InvocableVariable(label='Decisions JSON')
        public String decisionsJson;

        @InvocableVariable(label='Targets JSON')
        public String targetsJson;
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

    @InvocableMethod(label='Validate Content Plan' description='Checks a drafted content plan (elementsJson/decisionsJson/targetsJson) for structural problems -- missing textByDecision entries, unknown element keys, invalid decision criteria -- before asking the user to approve it. Makes no changes and creates nothing.')
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

                Boolean wantsPersonalization = String.isNotBlank(req.decisionsJson) && String.isNotBlank(req.targetsJson);
                if (wantsPersonalization) {
                    List<Object> decisionSpecs = (List<Object>) JSON.deserializeUntyped(req.decisionsJson);
                    List<Object> targetSpecs = (List<Object>) JSON.deserializeUntyped(req.targetsJson);
                    List<String> decisionNames = new List<String>();

                    for (Object specObj : decisionSpecs) {
                        Map<String, Object> spec = (Map<String, Object>) specObj;
                        decisionNames.add(String.valueOf(spec.get('name')));
                        try {
                            BuildDynamicEmailAction.buildDecisionCriteria(spec);
                        } catch (Exception criteriaEx) {
                            issues.add('Decision "' + spec.get('name') + '": ' + criteriaEx.getMessage());
                        }
                    }

                    for (Object targetObj : targetSpecs) {
                        Map<String, Object> target = (Map<String, Object>) targetObj;
                        String elementKey = String.valueOf(target.get('elementKey'));
                        if (!elementKeys.contains(elementKey)) {
                            issues.add('Target references unknown element key "' + elementKey + '" -- must match a "key" from elementsJson.');
                            continue;
                        }
                        String blockDefinition = target.get('blockDefinition') != null
                            ? String.valueOf(target.get('blockDefinition')) : 'lightning/paragraph';
                        Map<String, Object> textByDecision = (Map<String, Object>) target.get('textByDecision');

                        for (String decisionName : decisionNames) {
                            if (textByDecision == null || !textByDecision.containsKey(decisionName)) {
                                issues.add('Target "' + elementKey + '" is missing a rule for decision "' + decisionName + '".');
                                continue;
                            }
                            if (blockDefinition == 'lightning/image') {
                                Object decisionValue = textByDecision.get(decisionName);
                                String contentKey = (decisionValue instanceof Map<String, Object>)
                                    ? String.valueOf(((Map<String, Object>) decisionValue).get('contentKey')) : null;
                                if (String.isBlank(contentKey) || contentKey == 'null') {
                                    issues.add('Target "' + elementKey + '" (image) is missing a valid contentKey for decision "' + decisionName + '".');
                                }
                            }
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