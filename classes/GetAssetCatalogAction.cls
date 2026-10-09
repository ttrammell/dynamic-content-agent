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

    // Hard ceiling on the catalog size, regardless of org size. SIC2025 has 551 images; a blanket
    // "list all images" fallback would blow this and bloat both the plan prompt and the auto-assign
    // pool. Each discovery term below is already a bounded LIKE+LIMIT search, so the union stays small;
    // this cap is the final backstop (and keeps named/brand assets ranked ahead of generic stock).
    @TestVisible static Integer MAX_CATALOG = 25;

    // Structural image names worth searching when NO brand is named (or in addition to it). An org
    // whose images aren't named "Stock *" (e.g. BloombergDemo2026 -- 0 "Stock *" images but real
    // header/banner images) returned an EMPTY catalog under the old Stock-only discovery, which starved
    // the >=2-image swap floor and the auto-assign pool. These terms are the common header/hero slot
    // names and are each LIKE-bounded, so they find the real images without flooding (validated live:
    // Bloomberg header->5). Small k per term keeps the per-term contribution modest.
    private static final List<String> STRUCTURAL_TERMS = new List<String>{ 'header', 'banner', 'hero' };

    // Name/urlName fragments that mark an asset as NOT a per-audience swap candidate: brand marks,
    // placeholders, and chrome. The old "Stock " naming convention was the ONLY thing keeping these
    // out of hero auto-assign; now that discovery is broader, this is the explicit guard. Conservative
    // -- a false positive only drops an asset from the ROUND-ROBIN pool; it stays in the catalog and is
    // still resolvable BY EXACT NAME (buildAssetNameMap runs before round-robin), so a plan can still
    // place it deliberately. Lowercased substring match.
    private static final List<String> NON_SWAP_FRAGMENTS = new List<String>{
        'logo', 'placeholder', 'icon', 'favicon', '[system_default]', 'system_default',
        'sprite', 'wordmark'
    };

    @InvocableMethod(label='Get Asset Catalog' description='Returns the image-asset catalog for building/updating an email: the named brand\'s assets unioned with the org\'s stock image library, as one assetsJson. Deterministic input for image resolution -- the model references images by name, never a raw content key. Read-only; creates nothing.')
    public static List<Result> getAssetCatalog(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result res = new Result();
            res.assetsJson = '[]';
            res.errorMessage = '';
            try {
                Boolean wantStock = req.includeStock == null ? true : req.includeStock;
                res.assetsJson = JSON.serialize(discoverImages(req.brandName, wantStock));
            } catch (Exception e) {
                res.errorMessage = e.getMessage();
            }
            results.add(res);
        }
        return results;
    }

    // Build the image catalog: named-brand assets UNIONED with structural header/hero images and the
    // "Stock *" library, deduped on contentKey, each stamped swapEligible, hard-capped at MAX_CATALOG.
    // Ordering (= truncation priority): brand first, then structural, then stock -- so the most
    // specific, most-likely-named assets survive the cap and generic stock is what gets trimmed. Every
    // asset STAYS in the catalog (never filtered out here): named resolution must still find a logo by
    // exact name. swapEligible only governs the auto-assign round-robin + the >=2 image floor.
    @TestVisible
    private static List<Object> discoverImages(String brandName, Boolean includeStock) {
        Map<String, Object> byKey = new Map<String, Object>();  // dedup on contentKey, insertion-ordered
        // 1. Brand assets (only if a brand was named) -- highest priority, kept ahead of the cap.
        if (String.isNotBlank(brandName)) {
            for (Object o : FindBrandAssetsAction.searchAssets(brandName, MAX_CATALOG)) { addAsset(byKey, o); }
        }
        // 2. Structural header/hero names -- finds the real swap images in orgs that don't use "Stock *".
        for (String term : STRUCTURAL_TERMS) {
            for (Object o : FindBrandAssetsAction.searchAssets(term, 8)) { addAsset(byKey, o); }
        }
        // 3. Stock library -- the toolkit's "Stock *" upload convention (unchanged behavior for orgs
        //    that have them). Real sfdc_cms__image records, not install-time {{STOCK:id}} tokens.
        if (includeStock) {
            for (Object o : FindBrandAssetsAction.searchAssets('Stock ', MAX_CATALOG)) { addAsset(byKey, o); }
        }
        // Cap in insertion order (brand -> structural -> stock), stamping swapEligible on each survivor.
        List<Object> out = new List<Object>();
        for (Object o : byKey.values()) {
            if (out.size() >= MAX_CATALOG) { break; }
            Map<String, Object> a = (Map<String, Object>) o;
            a.put('swapEligible', isSwapEligible(a));
            out.add(a);
        }
        return out;
    }

    // Is this asset a candidate for a per-audience image SWAP (vs. a logo/placeholder/chrome asset that
    // should never be auto-assigned as a hero)? True unless its name or slug contains a non-swap
    // fragment. Does NOT remove the asset from the catalog -- only marks it so the auto-assign pool and
    // the sufficiency count exclude it, while exact-name resolution can still place it.
    @TestVisible
    private static Boolean isSwapEligible(Map<String, Object> a) {
        String name = a.get('name') == null ? '' : String.valueOf(a.get('name')).toLowerCase();
        String slug = a.get('urlName') == null ? '' : String.valueOf(a.get('urlName')).toLowerCase();
        for (String frag : NON_SWAP_FRAGMENTS) {
            if (name.contains(frag) || slug.contains(frag)) { return false; }
        }
        return true;
    }

    // Ordered, DISTINCT list of swap-ELIGIBLE image contentKeys from an assetsJson, in catalog order.
    // The ONE shared source of truth for: (a) BuildDynamicEmailAction's auto-assign round-robin pool,
    // and (b) the >=2-distinct-images swap floor counted by BOTH ReadDynamicEmailAction and
    // ValidateContentPlanAction. Routing all three through here is what keeps them from drifting (a
    // past bug: Assemble and Validate disagreeing on what counted). Assets lacking the swapEligible
    // flag (e.g. a catalog serialized by older code) default to eligible, so this never UNDERcounts a
    // legitimately-swappable image on a stale payload.
    public static List<String> swapEligibleKeys(String assetsJson) {
        List<String> out = new List<String>();
        Set<String> seen = new Set<String>();
        if (String.isBlank(assetsJson)) { return out; }
        Object parsed;
        try { parsed = JSON.deserializeUntyped(AuraPocJson.stripFence(assetsJson)); }
        catch (Exception e) { return out; }
        if (!(parsed instanceof List<Object>)) { return out; }
        for (Object o : (List<Object>) parsed) {
            if (!(o instanceof Map<String, Object>)) { continue; }
            Map<String, Object> a = (Map<String, Object>) o;
            String ck = a.get('contentKey') == null ? '' : String.valueOf(a.get('contentKey'));
            if (String.isBlank(ck) || seen.contains(ck)) { continue; }
            // Absent flag -> treat as eligible (back-compat with a catalog built before this field).
            Object se = a.get('swapEligible');
            if (se == false) { continue; }
            seen.add(ck); out.add(ck);
        }
        return out;
    }

    private static void addAsset(Map<String, Object> byKey, Object o) {
        if (!(o instanceof Map<String, Object>)) { return; }
        Map<String, Object> a = (Map<String, Object>) o;
        String ck = a.get('contentKey') == null ? '' : String.valueOf(a.get('contentKey'));
        if (String.isNotBlank(ck) && !byKey.containsKey(ck)) { byKey.put(ck, a); }
    }
}
