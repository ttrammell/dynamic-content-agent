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

    // Reusable CMS image search -- used by both the Find Brand Assets LLM tool (brand-name
    // terms like "Epicor") and ResolveBrandingAction's org-default fallback (the hyphenated slug
    // "default-email-template"). Returns {name, urlName, contentKey, managedContentId,
    // workspaceId}; empty list on no match.
    //
    // Matches on BOTH the human Name AND the URL slug (UrlName). The org-default convention names
    // assets "Default Email Template Logo" (spaces, title case) but slugs them
    // "default-email-template-logo" (hyphens) -- a caller searching the hyphenated slug matched
    // NEITHER when we filtered ManagedContent.Name alone, so the org default logo/header were
    // reported missing though they exist (confirmed live: the slug is the correct field to match
    // the hyphenated form). The slug lives on ManagedContentVariant, so the match is anchored
    // there via native SOQL. Type can't be filtered here: ContentTypeFullyQualifiedName is
    // rejected by the Apex class compiler in SELECT/WHERE -- on ManagedContent directly AND via
    // the variant relationship (the REST /query endpoint accepts it, anonymous Apex is more
    // lenient than a deployed class, but a class hard-fails to compile). So step 2 confirms which
    // matched contents are images through the same REST /query the original code used.
    public static List<Object> searchAssets(String searchTerm, Integer maxResults) {
        Integer lim = maxResults != null ? maxResults : 25;
        String pattern = '%' + searchTerm + '%';

        // Step 1 -- candidates matched by slug OR name (native SOQL on the variant; carries slug).
        List<ManagedContentVariant> candidates = [
            SELECT ManagedContentId, ManagedContentKey, UrlName,
                   ManagedContent.Name, ManagedContent.AuthoredManagedContentSpaceId
            FROM ManagedContentVariant
            WHERE (UrlName LIKE :pattern OR ManagedContent.Name LIKE :pattern)
            ORDER BY UrlName ASC
            LIMIT :lim];
        if (candidates.isEmpty()) { return new List<Object>(); }

        // Step 2 -- keep only image content (type filter via REST, the Apex-SOQL-rejected column).
        Set<Id> contentIds = new Set<Id>();
        for (ManagedContentVariant v : candidates) { contentIds.add(v.ManagedContentId); }
        Set<Id> imageContentIds = filterToImageContentIds(contentIds);

        List<Object> assets = new List<Object>();
        Set<Id> seen = new Set<Id>();
        for (ManagedContentVariant v : candidates) {
            if (!imageContentIds.contains(v.ManagedContentId)) { continue; }  // non-image -> skip
            if (seen.contains(v.ManagedContentId)) { continue; }              // one variant per content
            seen.add(v.ManagedContentId);
            assets.add(new Map<String, Object>{
                'name' => v.ManagedContent.Name,
                'urlName' => v.UrlName,
                'contentKey' => v.ManagedContentKey,
                'managedContentId' => v.ManagedContentId,
                'workspaceId' => v.ManagedContent.AuthoredManagedContentSpaceId
            });
        }
        return assets;
    }

    // Confirm which of the given content Ids are images. ContentTypeFullyQualifiedName can only be
    // queried through the REST /query endpoint (Apex SOQL rejects it), so this one filter is a
    // callout. Ids are Salesforce Ids (no injection risk) bound into an IN list.
    private static Set<Id> filterToImageContentIds(Set<Id> contentIds) {
        Set<Id> out = new Set<Id>();
        if (contentIds.isEmpty()) { return out; }
        List<String> quoted = new List<String>();
        for (Id cid : contentIds) { quoted.add('\'' + cid + '\''); }
        String soql = 'SELECT Id FROM ManagedContent '
            + 'WHERE ContentTypeFullyQualifiedName = \'sfdc_cms__image\' '
            + 'AND Id IN (' + String.join(quoted, ',') + ')';

        HttpRequest queryReq = new HttpRequest();
        queryReq.setMethod('GET');
        queryReq.setEndpoint(AuraPocTokenProvider.instanceUrl() + '/services/data/v66.0/query?q=' + EncodingUtil.urlEncode(soql, 'UTF-8'));
        queryReq.setHeader('Authorization', 'Bearer ' + tokenSource.getAccessToken());
        queryReq.setTimeout(30000);
        HttpResponse queryRes = new Http().send(queryReq);
        if (queryRes.getStatusCode() != 200) {
            throw new CalloutException('Image content type filter failed: HTTP ' + queryRes.getStatusCode() + ': ' + queryRes.getBody());
        }
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(queryRes.getBody());
        List<Object> records = (List<Object>) body.get('records');
        if (records != null) {
            for (Object recObj : records) {
                out.add((Id) String.valueOf(((Map<String, Object>) recObj).get('Id')));
            }
        }
        return out;
    }

    @InvocableMethod(label='Find Brand Assets' description='Searches CMS image content by name/URL slug (e.g. "logo", "header", "default-email-template") and returns each match\'s contentKey and managedContentId, for use as an image element\'s contentKey when building an email.')
    public static List<Result> findBrandAssets(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result res = new Result();
            // Confirmed live (DataGraphDetailsAction had the same gap): a null String output
            // binds to a null agent-script variable, and Salesforce's LLM gateway hard-rejects
            // any prompt template call with a null input. Default before the try so no
            // exception path can leave this null.
            res.assetsJson = '[]';
            try {
                res.assetsJson = JSON.serialize(searchAssets(req.searchTerm, req.maxResults));
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