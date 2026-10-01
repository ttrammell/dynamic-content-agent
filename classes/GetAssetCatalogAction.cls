// Returns the image-asset catalog the plan/build resolve image elements against, as ONE assetsJson:
// the named brand's assets (logo/header/etc.) UNIONED with the org's stock image library ("Stock *"
// sfdc_cms__image records). The agent binds base_brand_context to this so image elements -- base AND
// dynamic-content variants -- can be placed by assetName and resolved to a real contentKey
// deterministically (the LLM never transcribes an MC-key). Reuses FindBrandAssetsAction.searchAssets;
// makes only the read-only callouts that helper already makes. Creates nothing.
public with sharing class GetAssetCatalogAction {

    public class Request {
        @InvocableVariable(label='Brand Name')
        public String brandName;                 // the named brand (e.g. "Konica Minolta"); may be blank
        @InvocableVariable(label='Include Stock')
        public Boolean includeStock;             // default true -- union the org's "Stock *" images
    }

    public class Result {
        @InvocableVariable(label='Assets JSON')
        public String assetsJson;                // JSON array of {name, urlName, contentKey, ...}
        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    @InvocableMethod(label='Get Asset Catalog' description='Returns the image-asset catalog for building/updating an email: the named brand\'s assets unioned with the org\'s stock image library, as one assetsJson. Deterministic input for image resolution -- the model references images by name, never a raw content key. Read-only; creates nothing.')
    public static List<Result> getAssetCatalog(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result res = new Result();
            res.assetsJson = '[]';
            res.errorMessage = '';
            try {
                Map<String, Object> byKey = new Map<String, Object>();  // dedup on contentKey
                // Brand assets (only if a brand was named).
                if (String.isNotBlank(req.brandName)) {
                    for (Object o : FindBrandAssetsAction.searchAssets(req.brandName, 25)) {
                        addAsset(byKey, o);
                    }
                }
                // Stock library -- default on. "Stock " is the upload-naming convention for the
                // toolkit's stock photos, so a name search returns them; they're real sfdc_cms__image
                // records (already resolved keys), not the toolkit's install-time {{STOCK:id}} tokens.
                Boolean wantStock = req.includeStock == null ? true : req.includeStock;
                if (wantStock) {
                    for (Object o : FindBrandAssetsAction.searchAssets('Stock ', 50)) {
                        addAsset(byKey, o);
                    }
                }
                res.assetsJson = JSON.serialize(byKey.values());
            } catch (Exception e) {
                res.errorMessage = e.getMessage();
            }
            results.add(res);
        }
        return results;
    }

    private static void addAsset(Map<String, Object> byKey, Object o) {
        if (!(o instanceof Map<String, Object>)) { return; }
        Map<String, Object> a = (Map<String, Object>) o;
        String ck = a.get('contentKey') == null ? '' : String.valueOf(a.get('contentKey'));
        if (String.isNotBlank(ck) && !byKey.containsKey(ck)) { byKey.put(ck, a); }
    }
}
