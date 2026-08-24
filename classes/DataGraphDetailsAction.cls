public with sharing class DataGraphDetailsAction {

    public class Request {
        @InvocableVariable(label='Data Graph API Name' description='Optional. Leave blank to auto-detect the org\'s data graph. Only needed if an org has more than one and you want a specific one.' required=false)
        public String graphApiName;
    }

    public class Result {
        @InvocableVariable(label='Success')
        public Boolean success;

        @InvocableVariable(label='Fields JSON')
        public String fieldsJson;

        @InvocableVariable(label='Resolved Data Graph API Name')
        public String resolvedGraphApiName;

        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    // Test seam -- Auth.JWTBearerTokenExchange (inside AuraPocTokenProvider) is a
    // "Web service callout" and can't be intercepted by Test.setMock(HttpCalloutMock).
    @TestVisible
    static AuraPocTokenSource tokenSource = new AuraPocTokenProvider();

    // The raw data-graph definition is a deeply nested ~80KB blob (confirmed live on
    // Real_Time_Data_Graph). Handing that to the LLM as-is meant it only ever noticed the
    // primary DMO's own handful of projected fields (e.g. Salutation/First Name/Last
    // Name/Title on UnifiedIndividual) and silently ignored every related DMO -- which is
    // exactly where the fields actually useful for dynamic-content decisions live (e.g.
    // Case status, Contact Point Email domain). So this flattens fields.sourceObject plus
    // every nested relatedObjects entry, recursively, into one flat list grouped by DMO.
    private static void collectFields(Map<String, Object> dmo, List<Object> outFields, Set<String> visitedDmoNames) {
        if (dmo == null) {
            return;
        }
        String dmoName = String.valueOf(dmo.get('name'));
        if (visitedDmoNames.contains(dmoName)) {
            return;
        }
        visitedDmoNames.add(dmoName);

        String dmoLabel = String.valueOf(dmo.get('label'));
        List<Object> fields = (List<Object>) dmo.get('fields');
        if (fields != null) {
            for (Object fieldObj : fields) {
                Map<String, Object> field = (Map<String, Object>) fieldObj;
                outFields.add(new Map<String, Object>{
                    'dmoLabel' => dmoLabel,
                    'dmoName' => dmoName,
                    'fieldApiName' => field.get('sourceFieldName'),
                    'fieldLabel' => field.get('sourceFieldLabel'),
                    'dataType' => field.get('dataType')
                });
            }
        }

        List<Object> relatedObjects = (List<Object>) dmo.get('relatedObjects');
        if (relatedObjects != null) {
            for (Object relatedObj : relatedObjects) {
                collectFields((Map<String, Object>) relatedObj, outFields, visitedDmoNames);
            }
        }
    }

    public class NoGraphFoundException extends Exception {}

    // The Data Cloud Connect API's data-graphs endpoint is get-by-name only -- it has no
    // "list" operation. Every org can (and does) use a different developer name for its data
    // graph, so hardcoding or guessing a name (e.g. copying the name from this action's own
    // description) silently 404s in any org that named it differently. Tooling API's
    // DataGraphDefinition is the only way to discover what actually exists.
    private static List<String> listDataGraphApiNames(String accessToken) {
        HttpRequest httpReq = new HttpRequest();
        httpReq.setMethod('GET');
        httpReq.setEndpoint(AuraPocTokenProvider.instanceUrl()
            + '/services/data/v66.0/tooling/query?q='
            + EncodingUtil.urlEncode('SELECT DeveloperName FROM DataGraphDefinition', 'UTF-8'));
        httpReq.setHeader('Authorization', 'Bearer ' + accessToken);
        httpReq.setTimeout(30000);

        HttpResponse httpRes = new Http().send(httpReq);
        if (httpRes.getStatusCode() != 200) {
            throw new NoGraphFoundException('Could not list data graphs: HTTP ' + httpRes.getStatusCode() + ': ' + httpRes.getBody());
        }
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(httpRes.getBody());
        List<Object> records = (List<Object>) body.get('records');
        List<String> names = new List<String>();
        if (records != null) {
            for (Object recordObj : records) {
                names.add(String.valueOf(((Map<String, Object>) recordObj).get('DeveloperName')));
            }
        }
        return names;
    }

    private static HttpResponse fetchGraph(String accessToken, String graphApiName) {
        HttpRequest httpReq = new HttpRequest();
        httpReq.setMethod('GET');
        httpReq.setEndpoint(AuraPocTokenProvider.instanceUrl() + '/services/data/v66.0/ssot/data-graphs/'
            + EncodingUtil.urlEncode(graphApiName, 'UTF-8'));
        httpReq.setHeader('Authorization', 'Bearer ' + accessToken);
        httpReq.setTimeout(30000);
        return new Http().send(httpReq);
    }

    // Resolves the graph to actually query: use the requested name if it's valid, otherwise
    // fall back to discovery via Tooling API. Auto-picks when exactly one graph exists in the
    // org (the common case); otherwise fails loudly with the real list of names rather than
    // guessing, so the agent can ask the user instead of reporting a false "none configured".
    // PUBLIC because BuildDynamicEmailAction.cls also calls this.
    public static String resolveGraphApiName(String accessToken, String requestedName) {
        if (String.isNotBlank(requestedName)) {
            HttpResponse probe = fetchGraph(accessToken, requestedName);
            if (probe.getStatusCode() == 200) {
                return requestedName;
            }
        }
        List<String> available = listDataGraphApiNames(accessToken);
        if (available.isEmpty()) {
            throw new NoGraphFoundException('No data graphs are configured in this org (checked via Tooling API DataGraphDefinition).');
        }
        if (available.size() == 1) {
            return available[0];
        }
        String requestedNote = String.isNotBlank(requestedName)
            ? ('"' + requestedName + '" was not found. ')
            : '';
        throw new NoGraphFoundException(requestedNote + 'This org has ' + available.size()
            + ' data graphs -- specify one: ' + String.join(available, ', '));
    }

    @InvocableMethod(label='Get Data Graph Details' description='Fetches a Data Cloud data graph\'s full field topology -- the primary object plus every related object, flattened into one list grouped by DMO -- via the Data Cloud Connect API. Includes fields beyond plain identity/personalization fields (e.g. Case status, engagement data) that are useful for dynamic-content decisions. Auto-detects the org\'s data graph if none is specified.')
    public static List<Result> getDataGraphDetails(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result res = new Result();
            try {
                String accessToken = tokenSource.getAccessToken();
                String graphApiName = resolveGraphApiName(accessToken, req.graphApiName);

                HttpResponse httpRes = fetchGraph(accessToken, graphApiName);
                if (httpRes.getStatusCode() == 200) {
                    Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(httpRes.getBody());
                    Map<String, Object> sourceObject = (Map<String, Object>) body.get('sourceObject');
                    List<Object> fields = new List<Object>();
                    collectFields(sourceObject, fields, new Set<String>());
                    res.success = true;
                    res.resolvedGraphApiName = graphApiName;
                    res.fieldsJson = JSON.serialize(fields);
                } else {
                    res.success = false;
                    res.errorMessage = 'HTTP ' + httpRes.getStatusCode() + ': ' + httpRes.getBody();
                }
            } catch (Exception e) {
                res.success = false;
                res.errorMessage = e.getMessage();
            }
            results.add(res);
        }
        return results;
    }
}