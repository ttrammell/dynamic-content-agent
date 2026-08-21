// Closes the "Fetch_Email_Context" gap: brand image discovery, so the agent doesn't
// need hardcoded content keys for logo/header/etc. ContentTypeFullyQualifiedName on
// ManagedContent is real and describe-visible (isFilterable=true) but Apex's SOQL
// engine rejects it in BOTH static and dynamic (Database.query) form -- confirmed live,
// not assumed. The REST /query endpoint accepts it fine, so that one lookup goes through
// a REST callout; the ManagedContentVariant lookup (no such restriction) stays native SOQL.
public with sharing class FindBrandAssetsAction {

    public class Request {
        @InvocableVariable(label='Search Term' required=true)
        public String searchTerm;

        @InvocableVariable(label='Max Results')
        public Integer maxResults;
    }

    public class Result {
        @InvocableVariable(label='Success')
        public Boolean success;

        // JSON array of {name, urlName, contentKey, managedContentId, workspaceId}.
        // workspaceId (AuthoredManagedContentSpaceId) is the CMS workspace this asset lives
        // in -- confirmed live that a brand's logo/header/brand-record all share the same
        // one, so it doubles as contentSpaceOrFolderId for building an email in that brand's
        // workspace without a separate workspace-lookup action.
        @InvocableVariable(label='Assets JSON')
        public String assetsJson;

        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    @TestVisible
    static AuraPocTokenSource tokenSource = new AuraPocTokenProvider();

    @InvocableMethod(label='Find Brand Assets' description='Searches CMS image content by name/URL slug (e.g. "logo", "header", "default-email-template") and returns each match\'s contentKey and managedContentId, for use as an image element\'s contentKey when building an email.')
    public static List<Result> findBrandAssets(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result res = new Result();
            try {
                Integer lim = req.maxResults != null ? req.maxResults : 10;
                String pattern = '%' + String.escapeSingleQuotes(req.searchTerm) + '%';
                String soql = 'SELECT Id, Name, AuthoredManagedContentSpaceId FROM ManagedContent '
                    + 'WHERE ContentTypeFullyQualifiedName = \'sfdc_cms__image\' AND Name LIKE \'' + pattern + '\' '
                    + 'LIMIT ' + lim;

                HttpRequest queryReq = new HttpRequest();
                queryReq.setMethod('GET');
                queryReq.setEndpoint(AuraPocTokenProvider.instanceUrl() + '/services/data/v66.0/query?q=' + EncodingUtil.urlEncode(soql, 'UTF-8'));
                queryReq.setHeader('Authorization', 'Bearer ' + tokenSource.getAccessToken());
                queryReq.setTimeout(30000);
                HttpResponse queryRes = new Http().send(queryReq);

                if (queryRes.getStatusCode() != 200) {
                    res.success = false;
                    res.errorMessage = 'Image content search failed: HTTP ' + queryRes.getStatusCode() + ': ' + queryRes.getBody();
                    results.add(res);
                    continue;
                }

                Map<String, Object> queryResult = (Map<String, Object>) JSON.deserializeUntyped(queryRes.getBody());
                List<Object> records = (List<Object>) queryResult.get('records');

                if (records.isEmpty()) {
                    res.success = true;
                    res.assetsJson = '[]';
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
                    SELECT Id, Name, UrlName, ManagedContentId, ManagedContentKey
                    FROM ManagedContentVariant
                    WHERE ManagedContentId IN :contentIds
                ]) {
                    if (!variantByContentId.containsKey(v.ManagedContentId)) {
                        variantByContentId.put(v.ManagedContentId, v);
                    }
                }

                List<Object> assets = new List<Object>();
                for (Id contentId : contentIds) {
                    ManagedContentVariant v = variantByContentId.get(contentId);
                    if (v == null) {
                        continue;
                    }
                    assets.add(new Map<String, Object>{
                        'name' => nameByContentId.get(contentId),
                        'urlName' => v.UrlName,
                        'contentKey' => v.ManagedContentKey,
                        'managedContentId' => contentId,
                        'workspaceId' => workspaceIdByContentId.get(contentId)
                    });
                }

                res.success = true;
                res.assetsJson = JSON.serialize(assets);
            } catch (Exception e) {
                res.success = false;
                res.errorMessage = e.getMessage();
            }
            results.add(res);
        }
        return results;
    }
}