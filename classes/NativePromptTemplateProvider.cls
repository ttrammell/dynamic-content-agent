// Default LlmCompletionProvider -- calls a GenAiPromptTemplate directly via
// ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate. Confirmed against a live org:
// inputParams must be a plain Map<String, ConnectApi.WrappedValue> assigned directly
// (input.inputParams = valueMap), NOT wrapped in an outer WrappedValue -- that throws
// "Illegal assignment from ConnectApi.WrappedValue to Map<String,ConnectApi.WrappedValue>"
// despite the REST JSON example showing an outer wrapper shape.
//
// Two more requirements, found only by bisecting against Salesforce's own official Apex
// example (neither is documented as required, and omitting either produces a useless generic
// "Failed to generate Einstein LLM generations response" with no real reason given):
// 1. additionalConfig.applicationName must be set to some non-blank value, or the service
//    appears to take a different, less-validated code path that swallows the real error.
// 2. inputParams keys must be prefixed "Input:" (matching each GenAiPromptTemplate input's
//    declared referenceName, e.g. "Input:UserIntent") -- NOT the bare apiName ("UserIntent").
//    Passing bare names silently fails to bind and reports "Required input is missing" even
//    though the key IS present, just under the wrong name. Callers (PlanEmailStructureAction,
//    WriteEmailCopyAction) already build their `inputs` map with this "Input:" prefix baked
//    into each key -- this class must pass keys through AS-IS, not add another prefix, or
//    keys end up double-prefixed ("Input:Input:UserIntent") and fail the same way.
public with sharing class NativePromptTemplateProvider implements LlmCompletionProvider {

    public class LlmException extends Exception {}

    // Every prompt template here instructs the model to output ONLY raw JSON, no markdown
    // fences -- but that instruction isn't reliably followed (confirmed: the same model, same
    // template, returns fenced ```json...``` on some calls and bare JSON on others with no
    // discernible pattern). Callers deserialize this text directly, so strip a wrapping fence
    // here once, centrally, rather than have every caller guess whether this particular
    // response happened to include one.
    private static String stripMarkdownFence(String text) {
        if (text == null) {
            return text;
        }
        String trimmed = text.trim();
        if (!trimmed.startsWith('```')) {
            return trimmed;
        }
        Integer firstNewline = trimmed.indexOf('\n');
        if (firstNewline == -1) {
            return trimmed;
        }
        trimmed = trimmed.substring(firstNewline + 1);
        if (trimmed.endsWith('```')) {
            trimmed = trimmed.substring(0, trimmed.length() - 3);
        }
        return trimmed.trim();
    }

    public String generateCompletion(String promptKey, Map<String, String> inputs) {
        Map<String, ConnectApi.WrappedValue> valueMap = new Map<String, ConnectApi.WrappedValue>();
        for (String key : inputs.keySet()) {
            ConnectApi.WrappedValue wrapped = new ConnectApi.WrappedValue();
            wrapped.value = inputs.get(key);
            valueMap.put(key, wrapped);
        }

        ConnectApi.EinsteinPromptTemplateGenerationsInput input = new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        input.inputParams = valueMap;
        input.isPreview = false;
        input.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        input.additionalConfig.applicationName = 'PromptTemplateGenerationsInvocable';

        try {
            ConnectApi.EinsteinPromptTemplateGenerationsRepresentation output =
                ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(promptKey, input);
            if (output == null || output.generations == null || output.generations.isEmpty()) {
                throw new LlmException('No generation returned for prompt template "' + promptKey + '".');
            }
            return stripMarkdownFence(output.generations[0].text);
        } catch (LlmException le) {
            throw le;
        } catch (Exception e) {
            throw new LlmException('LLM generation failed for prompt template "' + promptKey + '": ' + e.getMessage(), e);
        }
    }
}