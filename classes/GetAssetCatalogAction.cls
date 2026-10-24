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
        // Contentful heroes now come back brand-TAGGED (not brand-filtered), so split them: brand-matched
        // heroes are highest-intent and rank first; the rest are available as fill AFTER the brand's CMS
        // assets so a non-SF/NTO brand (e.g. Welo) still gets real Contentful swap images while its own
        // CMS logo/header are never crowded out of the cap. See [[feedback_dc_agent_html_block_pp_swap_supported]].
        List<Object> matchedHeroes = new List<Object>();
        List<Object> otherHeroes = new List<Object>();
        for (Object o : contentfulHeroes(brandName)) {
            Map<String, Object> h = (Map<String, Object>) o;
            if (h.get('brandMatch') == false) { otherHeroes.add(o); } else { matchedHeroes.add(o); }
            h.remove('brandMatch');   // internal ranking hint only -- never serialized to the catalog
        }
        // Insertion order (= cap-truncation priority):
        // 1. brand-MATCHED Contentful heroes -- the brand's own highest-intent hero(es).
        for (Object o : matchedHeroes) { addAsset(byKey, o); }
        // 2. Brand CMS assets (only if a brand was named) -- logo/header/brand images. MUST come before
        //    the non-matched hero fill so they survive the cap (ResolveBranding needs these contentKeys).
        if (String.isNotBlank(brandName)) {
            for (Object o : FindBrandAssetsAction.searchAssets(brandName, MAX_CATALOG)) { addAsset(byKey, o); }
        }
        // 3. Structural header/hero names -- finds the real swap images in orgs that don't use "Stock *".
        for (String term : STRUCTURAL_TERMS) {
            for (Object o : FindBrandAssetsAction.searchAssets(term, 8)) { addAsset(byKey, o); }
        }
        // 4. The REST of the Contentful heroes (not brand-matched) -- the "available regardless of brand"
        //    fill, so image swaps can use Contentful even when the brand has no heroes of its own.
        for (Object o : otherHeroes) { addAsset(byKey, o); }
        // 5. Stock library -- the toolkit's "Stock *" upload convention (unchanged behavior for orgs
        //    that have them). Real sfdc_cms__image records, not install-time {{STOCK:id}} tokens.
        if (includeStock) {
            for (Object o : FindBrandAssetsAction.searchAssets('Stock ', MAX_CATALOG)) { addAsset(byKey, o); }
        }
        // Cap in insertion order (matched heroes -> brand CMS -> structural -> other heroes -> stock),
        // stamping swapEligible.
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
        return swapEligibleKeys(assetsJson, null);
    }

    // Overload: additionally EXCLUDE a set of contentKeys from the swap pool -- used to drop the
    // resolved banner logo/header keys, which are otherwise swap-eligible catalog images (header/hero
    // discovery adds them) but must NOT be offered as a per-audience body-image swap: the banner
    // already renders them, and picking one for a body slot produces a "banner duplicate" that Build
    // drops -- which, if that slot was personalized, orphaned the PP target and rolled the build back.
    // Excluding by the SPECIFIC resolved keys (not by name) keeps legitimate header/hero images
    // swappable in orgs that rely on them. See [[feedback_dc_agent_exclude_banner_keys_from_swap_pool]].
    public static List<String> swapEligibleKeys(String assetsJson, Set<String> excludeKeys) {
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
            if (excludeKeys != null && excludeKeys.contains(ck)) { continue; }   // resolved banner key
            // Absent flag -> treat as eligible (back-compat with a catalog built before this field).
            Object se = a.get('swapEligible');
            if (se == false) { continue; }
            seen.add(ck); out.add(ck);
        }
        return out;
    }

    // Ordered, DISTINCT list of swap-ELIGIBLE off-CMS image URLs from an assetsJson (assets that have
    // an assetUrl and no contentKey), in catalog order. Parallel to swapEligibleKeys for the url-mode
    // (Contentful) assets, so the image auto-assign round-robin can hand a decision a direct URL when
    // the plan named no asset. Same swapEligible semantics (absent flag -> eligible).
    public static List<String> swapEligibleUrls(String assetsJson) {
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
            if (String.isNotBlank(ck)) { continue; }   // CMS asset -> handled by swapEligibleKeys
            String au = a.get('assetUrl') == null ? '' : String.valueOf(a.get('assetUrl'));
            if (String.isBlank(au) || seen.contains(au)) { continue; }
            if (a.get('swapEligible') == false) { continue; }
            seen.add(au); out.add(au);
        }
        return out;
    }

    private static void addAsset(Map<String, Object> byKey, Object o) {
        if (!(o instanceof Map<String, Object>)) { return; }
        Map<String, Object> a = (Map<String, Object>) o;
        String ck = a.get('contentKey') == null ? '' : String.valueOf(a.get('contentKey'));
        String au = a.get('assetUrl') == null ? '' : String.valueOf(a.get('assetUrl'));
        // CMS asset -> dedup on contentKey. Off-CMS (Contentful) asset -> no contentKey, dedup on a
        // synthetic "url:<assetUrl>" key so it still unions/dedupes alongside CMS assets.
        String dedupKey = String.isNotBlank(ck) ? ck : (String.isNotBlank(au) ? 'url:' + au : '');
        if (String.isNotBlank(dedupKey) && !byKey.containsKey(dedupKey)) { byKey.put(dedupKey, a); }
    }

    // ── Contentful heroes (optional, connection-gated) ──────────────────────────────────────────
    // Returns the named brand's Contentful hero assets as catalog items {name, urlName, assetUrl,
    // source:'contentful'} -- a direct CDN url, NO CMS contentKey (Build emits them as url-mode image
    // blocks, so nothing is published to CMS first). Empty list (fail-soft) when Contentful is not
    // configured in this org, or any read fails -- the agent then behaves exactly as before. The
    // custom setting is referenced DYNAMICALLY so this class compiles/deploys in orgs that don't have
    // the Contentful-MCNext package (the setting simply won't be in getGlobalDescribe there).
    @TestVisible
    private static List<Object> contentfulHeroes(String brandName) {
        List<Object> out = new List<Object>();
        try {
            if (!Schema.getGlobalDescribe().containsKey('Contentful_Settings__c')) { return out; }
            SObject cfg = contentfulConfig();
            if (cfg == null) { return out; }
            String space = strField(cfg, 'Space_Id__c');
            String deliveryToken = strField(cfg, 'Delivery_Token__c');
            if (String.isBlank(space) || String.isBlank(deliveryToken)) { return out; }   // not connected
            String env = String.isBlank(strField(cfg, 'Environment_Id__c')) ? 'master' : strField(cfg, 'Environment_Id__c');

            // Read heroAsset entries (same content type + include=1 asset resolution the companion app uses).
            String url = 'https://cdn.contentful.com/spaces/' + space + '/environments/' + env
                + '/entries?content_type=heroAsset&include=1&limit=100';
            HttpRequest req = new HttpRequest();
            req.setEndpoint(url);
            req.setMethod('GET');
            req.setHeader('Authorization', 'Bearer ' + deliveryToken);
            req.setTimeout(120000);
            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) { return out; }
            Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());

            Map<String, String> assetUrlById = contentfulAssetUrls(data);
            String wantBrand = String.isBlank(brandName) ? '' : brandName.trim().toLowerCase();
            Object itemsObj = data.get('items');
            if (!(itemsObj instanceof List<Object>)) { return out; }
            for (Object io : (List<Object>) itemsObj) {
                Map<String, Object> entry = (Map<String, Object>) io;
                Map<String, Object> f = (Map<String, Object>) entry.get('fields');
                if (f == null) { continue; }
                // Brand TAGGING (was a hard drop): keep EVERY hero, but mark whether it matches the
                // named brand so discoverImages can rank brand-matched heroes first and offer the rest
                // as fill. Dropping non-matching heroes used to gut the pool for any brand without
                // Contentful heroes of its own (the space may carry only brand-salesforce / brand-nto),
                // so a brand like "Welo" saw ~zero heroes and the swap fell back to CMS stock. A hero
                // matches when no brand is named, the hero has no brandId, or the names substring-match
                // either way. See [[feedback_dc_agent_html_block_pp_swap_supported]].
                String entryBrand = f.get('brandId') == null ? '' : String.valueOf(f.get('brandId')).trim().toLowerCase();
                String entryTitle = f.get('title') == null ? '' : String.valueOf(f.get('title'));
                Boolean brandMatch = String.isBlank(wantBrand) || String.isBlank(entryBrand)
                        || entryBrand.contains(wantBrand) || wantBrand.contains(entryBrand);
                String au = contentfulImageUrl(f, assetUrlById);
                if (String.isBlank(au)) { continue; }
                Map<String, Object> sysMap = (Map<String, Object>) entry.get('sys');
                String nm = String.isNotBlank(entryTitle) ? entryTitle
                    : (sysMap != null ? String.valueOf(sysMap.get('id')) : 'Contentful hero');
                // Selection metadata for the plan LLM (rides along in assetsJson -> base_brand_context
                // -> the plan prompt's BrandContext). Lets the model PREFER a hero by intent (theme/
                // searchText/caption) and MAP a hero to a decision by audience (audienceFit) -- authoring
                // -time hints only. Inert to Build (resolveImageRefs/auto-assign ignore unknown keys);
                // the chosen assetName still resolves deterministically. Generic key names (audienceFit,
                // not the Contentful-specific loyaltyTierFit) keep the agent source-agnostic. Omitted
                // when blank so absent = "no hint", never an empty-string red herring.
                Map<String, Object> hero = new Map<String, Object>{
                    'name' => nm,
                    'urlName' => sysMap != null ? String.valueOf(sysMap.get('id')) : nm,
                    'assetUrl' => au,
                    'source' => 'contentful',
                    // Internal ranking hint for discoverImages (stripped before the catalog is
                    // serialized out, see below) -- brand-matched heroes rank ahead of the rest.
                    'brandMatch' => brandMatch
                };
                String theme = f.get('theme') == null ? '' : String.valueOf(f.get('theme')).trim();
                String audienceFit = f.get('loyaltyTierFit') == null ? '' : String.valueOf(f.get('loyaltyTierFit')).trim();
                String caption = f.get('caption') == null ? '' : String.valueOf(f.get('caption')).trim();
                String searchText = f.get('searchText') == null ? '' : String.valueOf(f.get('searchText')).trim();
                if (String.isNotBlank(theme)) { hero.put('theme', theme); }
                if (String.isNotBlank(audienceFit)) { hero.put('audienceFit', audienceFit); }
                if (String.isNotBlank(caption)) { hero.put('caption', caption); }
                if (String.isNotBlank(searchText)) { hero.put('searchText', searchText.abbreviate(160)); }
                out.add(hero);
            }
        } catch (Exception e) {
            return new List<Object>();   // fail-soft: Contentful is a nice-to-have, never blocks the catalog
        }
        return out;
    }

    private static SObject contentfulConfig() {
        // Custom Setting (hierarchy or list). Query dynamically: prefer a 'Default' named row, else any
        // row with a Space_Id__c. Returns null if none.
        try {
            List<SObject> rows = Database.query(
                'SELECT Space_Id__c, Delivery_Token__c, Environment_Id__c FROM Contentful_Settings__c '
                + 'ORDER BY Name LIMIT 50'
            );
            for (SObject r : rows) { if (String.isNotBlank(strField(r, 'Space_Id__c'))) { return r; } }
        } catch (Exception e) { /* field/object not present -> treat as not configured */ }
        return null;
    }

    private static String strField(SObject r, String field) {
        try { Object v = r.get(field); return v == null ? '' : String.valueOf(v); }
        catch (Exception e) { return ''; }
    }

    private static Map<String, String> contentfulAssetUrls(Map<String, Object> data) {
        Map<String, String> byId = new Map<String, String>();
        Object includesObj = data.get('includes');
        if (!(includesObj instanceof Map<String, Object>)) { return byId; }
        Object assetsObj = ((Map<String, Object>) includesObj).get('Asset');
        if (!(assetsObj instanceof List<Object>)) { return byId; }
        for (Object ao : (List<Object>) assetsObj) {
            Map<String, Object> asset = (Map<String, Object>) ao;
            Map<String, Object> f = (Map<String, Object>) asset.get('fields');
            Map<String, Object> sysMap = (Map<String, Object>) asset.get('sys');
            if (f == null || sysMap == null) { continue; }
            Map<String, Object> file = (Map<String, Object>) f.get('file');
            if (file == null) { continue; }
            String u = file.get('url') == null ? '' : String.valueOf(file.get('url'));
            if (String.isBlank(u)) { continue; }
            if (u.startsWith('//')) { u = 'https:' + u; }   // Contentful returns protocol-relative urls
            byId.put(String.valueOf(sysMap.get('id')), u);
        }
        return byId;
    }

    private static String contentfulImageUrl(Map<String, Object> fields, Map<String, String> assetUrls) {
        Object link = fields.get('image');
        if (link == null) { link = fields.get('logo'); }
        if (!(link instanceof Map<String, Object>)) { return ''; }
        Map<String, Object> sysMap = (Map<String, Object>) ((Map<String, Object>) link).get('sys');
        if (sysMap == null) { return ''; }
        String u = assetUrls.get(String.valueOf(sysMap.get('id')));
        return u == null ? '' : u;
    }
}
