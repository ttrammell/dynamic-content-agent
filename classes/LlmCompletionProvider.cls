// Extensibility point for LLM callouts. NativePromptTemplateProvider (below) wraps
// Salesforce's own GenAiPromptTemplate/ConnectApi.EinsteinLLM mechanism, but any other
// implementation -- e.g. an HTTP callout to an external LLM API via Named Credential -- can
// swap in here without touching PlanEmailStructureAction/WriteEmailCopyAction, the same way
// AuraPocTokenSource/AuraPocTokenProvider already decouples auth from its callers.
public interface LlmCompletionProvider {
    // promptKey identifies which prompt/model to use -- for the native provider, a
    // GenAiPromptTemplate developer name; for any other provider, a routing key of that
    // provider's own choosing (e.g. an external model + endpoint pair).
    String generateCompletion(String promptKey, Map<String, String> inputs);
}