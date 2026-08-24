// Finds the actual sfdc_cms__brand ManagedContent record (colorScheme/typography/button
// styling), distinct from FindBrandAssetsAction's sfdc_cms__image search (logo/header
// pictures). Confirmed live: AMD has both -- three sfdc_cms__image assets (logo, header,
// event details) AND its own separate sfdc_cms__brand record. Without attaching the brand
// record via lightning:brandSource, an email can show the right logo/header images while
// still rendering with generic default colors/fonts/buttons instead of the brand's own.
public with sharing class FindBrandRecordAction {

    public class Request {
        // Confirmed live: the LLM sometimes omits this even though it's marked required,
        // producing a hard platform-level REQUIRED_FIELD_MISSING rejection before this Apex
        // ever runs (no amount of Apex-side defensiveness can fix an omitted required param).
        // Optional here instead -- blank means "list every brand record in the org".
        @InvocableVariable(label='Search Term')
        public String searchTerm;

        @InvocableVariable(label='Max Results')
        public Integer maxResults;
    }

    public class Result {
        @InvocableVariable(label='Success')
        public Boolean success;

        // JSON array of {name, contentKey, workspaceId, description, identity, tone}.
        // workspaceId (AuthoredManagedContentSpaceId) is the CMS workspace this brand record
        // lives in -- usable as contentSpaceOrFolderId to build an email in that brand's
        // workspace. description/identity/tone are best-effort brand-voice enrichment (see
        // extractBrandVoice) -- empty strings when the brand record doesn't define them or the
        // body fetch fails; never blocks the search over this optional extra.
        @InvocableVariable(label='Brands JSON')
        public String brandsJson;

        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    @TestVisible
    static AuraPocTokenSource tokenSource = new AuraPocTokenProvider();

    // Pure extraction, no callout -- mirrors the marketing toolkit's own
    // _extract_brand_profile (web/app.py), which already does this same parsing for the
    // toolkit's native generation path. Description lives at sfdc_cms:description; identity +
    // tone live inside sfdc_cms:einsteinBrandProperties. Returns empty strings for any field
    // absent from contentBody -- never throws, since brand voice is optional enrichment.
    @TestVisible
    static Map<String, String> extractBrandVoice(Map<String, Object> contentBody) {
        Map<String, Object> body = contentBody != null ? contentBody : new Map<String, Object>();
        String description = body.get('sfdc_cms:description') != null ? String.valueOf(body.get('sfdc_cms:description')) : '';

        Map<String, Object> einstein = body.get('sfdc_cms:einsteinBrandProperties') instanceof Map<String, Object>
            ? (Map<String, Object>) body.get('sfdc_cms:einsteinBrandProperties') : new Map<String, Object>();
        String identity = einstein.get('identity') != null ? String.valueOf(einstein.get('identity')) : '';

        Map<String, Object> personality = einstein.get('personality') instanceof Map<String, Object>
            ? (Map<String, Object>) einstein.get('personality') : new Map<String, Object>();
        String tone = personality.get('defaultPersonality') != null ? String.valueOf(personality.get('defaultPersonality')) : '';

        return new Map<String, String>{ 'description' => description, 'identity' => identity, 'tone' => tone };
    }

    // Best-effort fetch of a brand record's full contentBody, for brand-voice extraction only.
    // Failures here (404, timeout, malformed body) must never fail the overall brand search --
    // voice is an enrichment, not a requirement, unlike the name/contentKey/workspaceId the
    // caller actually needs to build the email.
    private static Map<String, String> fetchBrandVoice(String contentKey) {
        try {
            HttpRequest bodyReq = new HttpRequest();
            bodyReq.setMethod('GET');
            bodyReq.setEndpoint(AuraPocTokenProvider.instanceUrl() + '/services/data/v66.0/connect/cms/contents/' + contentKey);
            bodyReq.setHeader('Authorization', 'Bearer ' + tokenSource.getAccessToken());
            bodyReq.setTimeout(30000);
            HttpResponse bodyRes = new Http().send(bodyReq);
            if (bodyRes.getStatusCode() != 200) {
                return new Map<String, String>{ 'description' => '', 'identity' => '', 'tone' => '' };
            }
            Map<String, Object> content = (Map<String, Object>) JSON.deserializeUntyped(bodyRes.getBody());
            Map<String, Object> contentBody = content.get('contentBody') instanceof Map<String, Object>
                ? (Map<String, Object>) content.get('contentBody') : new Map<String, Object>();
            return extractBrandVoice(contentBody);
        } catch (Exception ignored) {
            return new Map<String, String>{ 'description' => '', 'identity' => '', 'tone' => '' };
        }
    }

    @InvocableMethod(label='Find Brand Record' description='Searches CMS brand records (colorScheme/typography/button styling) by name and returns each match\'s contentKey, for use as lightning:brandSource so an email actually renders with that brand\'s colors/fonts -- not just its logo/header images. Omit searchTerm to list every brand record in the org.')
    public static List<Result> findBrandRecord(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result res = new Result();
            try {
                Integer lim = req.maxResults != null ? req.maxResults : 10;
                String pattern = '%' + (String.isBlank(req.searchTerm) ? '' : String.escapeSingleQuotes(req.searchTerm)) + '%';
                String soql = 'SELECT Id, Name, AuthoredManagedContentSpaceId FROM ManagedContent '
                    + 'WHERE ContentTypeFullyQualifiedName = \'sfdc_cms__brand\' AND Name LIKE \'' + pattern + '\' '
                    + 'LIMIT ' + lim;

                HttpRequest queryReq = new HttpRequest();
                queryReq.setMethod('GET');
                queryReq.setEndpoint(AuraPocTokenProvider.instanceUrl() + '/services/data/v66.0/query?q=' + EncodingUtil.urlEncode(soql, 'UTF-8'));
                queryReq.setHeader('Authorization', 'Bearer ' + tokenSource.getAccessToken());
                queryReq.setTimeout(30000);
                HttpResponse queryRes = new Http().send(queryReq);

                if (queryRes.getStatusCode() != 200) {
                    res.success = false;
                    res.errorMessage = 'Brand record search failed: HTTP ' + queryRes.getStatusCode() + ': ' + queryRes.getBody();
                    results.add(res);
                    continue;
                }

                Map<String, Object> queryResult = (Map<String, Object>) JSON.deserializeUntyped(queryRes.getBody());
                List<Object> records = (List<Object>) queryResult.get('records');

                if (records.isEmpty()) {
                    res.success = true;
                    res.brandsJson = '[]';
                    results.add(res);
                    continue;
                }

                Set<Id> contentIds = new Set<Id>();
                Map<Id, String> nameByContentId = new Map<Id, String>();
                Map<Id, String> workspaceIdByContentId = new Map<Id, String>();
                for (Object recObj : records) {
                    Map<String, Object> rec = (Map<String, Object>) recObj;
                    Id contentId = (Id) String.valueOf(rec.get('Id'));
                    contentIds.add(contentId);
                    nameByContentId.put(contentId, String.valueOf(rec.get('Name')));
                    workspaceIdByContentId.put(contentId, String.valueOf(rec.get('AuthoredManagedContentSpaceId')));
                }

                Map<Id, ManagedContentVariant> variantByContentId = new Map<Id, ManagedContentVariant>();
                for (ManagedContentVariant v : [
                    SELECT Id, ManagedContentId, ManagedContentKey
                    FROM ManagedContentVariant
                    WHERE ManagedContentId IN :contentIds
                ]) {
                    if (!variantByContentId.containsKey(v.ManagedContentId)) {
                        variantByContentId.put(v.ManagedContentId, v);
                    }
                }

                List<Object> brands = new List<Object>();
                for (Id contentId : contentIds) {
                    ManagedContentVariant v = variantByContentId.get(contentId);
                    if (v == null) {
                        continue;
                    }
                    Map<String, String> voice = fetchBrandVoice(v.ManagedContentKey);
                    brands.add(new Map<String, Object>{
                        'name' => nameByContentId.get(contentId),
                        'contentKey' => v.ManagedContentKey,
                        'workspaceId' => workspaceIdByContentId.get(contentId),
                        'description' => voice.get('description'),
                        'identity' => voice.get('identity'),
                        'tone' => voice.get('tone')
                    });
                }

                res.success = true;
                res.brandsJson = JSON.serialize(brands);
            } catch (Exception e) {
                res.success = false;
                res.errorMessage = e.getMessage();
            }
            results.add(res);
        }
        return results;
    }
}