// Stage 1 of the planning/copywriting split: decides content slots + personalization needs
// only, no final copy. Calls through LlmCompletionProvider (not directly through
// ConnectApi.EinsteinLLM) so the underlying LLM callout is swappable -- e.g. for an external
// API -- without touching this action or its caller.
public with sharing class PlanEmailStructureAction {

    public class Request {
        @InvocableVariable(label='User Intent' required=true)
        public String userIntent;

        @InvocableVariable(label='Brand Context')
        public String brandContext;

        @InvocableVariable(label='Data Graph Context')
        public String dataGraphContext;
    }

    public class Result {
        @InvocableVariable(label='Success')
        public Boolean success;

        // JSON: {titleGoal, subjectLineGoal, preheaderGoal,
        // slots:[{key,type,goal,linkGoal,contentKey,altText,widthPercent}],
        // personalizations:[{name,label,fieldApiName,scope,matchType,value,values,
        // appliesToSlots}]}. No final copy -- see WriteEmailCopyAction.
        @InvocableVariable(label='Structure Plan JSON')
        public String structurePlanJson;

        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    @TestVisible
    static LlmCompletionProvider llmProvider = new NativePromptTemplateProvider();

    @InvocableMethod(label='Plan Email Structure' description='Decides email structure (content slots and personalization needs) from a plain-language request, without writing any final copy. Creates nothing, makes no changes.')
    public static List<Result> planEmailStructure(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result res = new Result();
            try {
                Map<String, String> inputs = new Map<String, String>{
                    'Input:UserIntent' => req.userIntent,
                    'Input:BrandContext' => String.isNotBlank(req.brandContext) ? req.brandContext : 'None available',
                    'Input:DataGraphContext' => String.isNotBlank(req.dataGraphContext) ? req.dataGraphContext : 'None available'
                };
                res.structurePlanJson = llmProvider.generateCompletion('AuraPoc_PlanEmailStructure', inputs);
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