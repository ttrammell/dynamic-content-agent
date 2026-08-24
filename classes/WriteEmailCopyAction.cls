// Stage 2 of the planning/copywriting split: writes final creative copy for an
// already-decided structure plan, with no JSON-shape example in its own prompt context (the
// planning stage's shape example is a separate prompt template, never shown to this one) --
// that separation is what stops the model from reusing shape-example placeholder text as if
// it were real content, confirmed as a recurring bug when one prompt did both jobs at once.
public with sharing class WriteEmailCopyAction {

    public class Request {
        @InvocableVariable(label='Structure Plan JSON' required=true)
        public String structurePlanJson;

        @InvocableVariable(label='User Intent')
        public String userIntent;

        @InvocableVariable(label='Brand Context')
        public String brandContext;
    }

    public class Result {
        @InvocableVariable(label='Success')
        public Boolean success;

        // JSON: {title, subjectLine, preheader, copyBySlot:{<slotKey>:{default, url,
        // byPersonalization:{<personalizationName>: text}}}}.
        @InvocableVariable(label='Copy JSON')
        public String copyJson;

        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    @TestVisible
    static LlmCompletionProvider llmProvider = new NativePromptTemplateProvider();

    @InvocableMethod(label='Write Email Copy' description='Writes final creative copy (title, subject line, preheader, and text for every content slot) for an already-decided structure plan from Plan Email Structure. Creates nothing, makes no changes.')
    public static List<Result> writeEmailCopy(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result res = new Result();
            try {
                Map<String, String> inputs = new Map<String, String>{
                    'Input:StructurePlan' => req.structurePlanJson,
                    'Input:UserIntent' => String.isNotBlank(req.userIntent) ? req.userIntent : '',
                    'Input:BrandContext' => String.isNotBlank(req.brandContext) ? req.brandContext : 'None available'
                };
                res.copyJson = llmProvider.generateCompletion('AuraPoc_WriteEmailCopy', inputs);
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