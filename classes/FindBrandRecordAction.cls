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

        // JSON array of {name, contentKey, workspaceId}. workspaceId
        // (AuthoredManagedContentSpaceId) is the CMS workspace this brand record lives in --
        // usable as contentSpaceOrFolderId to build an email in that brand's workspace.
        @InvocableVariable(label='Brands JSON')
        public String brandsJson;

        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    @TestVisible
    static AuraPocTokenSource tokenSource = new AuraPocTokenProvider();

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
                    brands.add(new Map<String, Object>{
                        'name' => nameByContentId.get(contentId),
                        'contentKey' => v.ManagedContentKey,
                        'workspaceId' => workspaceIdByContentId.get(contentId)
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