// READ-ONLY inspection of an EXISTING CMS email so the agent can answer "does this email have
// dynamic content?" / "what are its slots?" from the ACTUAL content -- instead of improvising a
// generic summary from the name (confirmed live: asked "is there DC on <name>", the agent with no
// plan behind that email filled in generic slot/personalization text). Also grounds the Update
// flow: the returned block list (type/text/contentKey) is what a caller uses to build matchText/
// matchContentKey targets. Fetches the content via the JWT-authed CMS REST GET; creates nothing.
public with sharing class ReadDynamicEmailAction {

    // Image DC needs at least this many DISTINCT catalog images to make a visible per-audience swap
    // (fewer means every decision would reuse the same picture, or 0 fails the build). Below this floor
    // we don't offer image slots as personalizable and tell the user to add images.
    private static final Integer MIN_IMAGES_FOR_SWAP = 2;

    public class Request {
        // Accepts the email's CMS content key (MC...) OR its ManagedContent record Id (20Y...) --
        // the latter is what a CMS email record page gives an agent as currentRecordId, so the agent
        // can read "this email" from page context without a typed key. Resolved to the MC key server-side.
        @InvocableVariable(label='Content Key or Record Id' required=true)
        public String contentKey;
    }

    public class Result {
        // Echo of the requested key, so the agent can capture it as the update target at read time.
        @InvocableVariable(label='Content Key')
        public String contentKey;
        @InvocableVariable(label='Found')
        public Boolean found;
        @InvocableVariable(label='Title')
        public String title;
        @InvocableVariable(label='Is Personalized')
        public Boolean isPersonalized;
        @InvocableVariable(label='Personalization Point Count')
        public Integer ppCount;
        // Human-readable, factual summary the agent can relay verbatim (no improvising).
        @InvocableVariable(label='Summary')
        public String summary;
        // JSON: [{def, text, contentKey, personalized}] for each heading/paragraph/image block --
        // the caller uses text/contentKey to target blocks for an Update.
        @InvocableVariable(label='Blocks JSON')
        public String blocksJson;
        // JSON: [{slot, type, textHint}] for ONLY the slots eligible to personalize on an update --
        // unpersonalized, non-image (heading/paragraph/button). This is the closed set the agent
        // offers ("you can personalize slots 2, 4, 5") so slot choice never has to be guessed.
        @InvocableVariable(label='Eligible Slots JSON')
        public String eligibleSlotsJson;
        // Distinct images in the org's catalog. Image slots are offered as personalizable only when this
        // is >= MIN_IMAGES_FOR_SWAP; surfaced so the agent/panel can explain when image DC isn't offered.
        @InvocableVariable(label='Image Catalog Count')
        public Integer imageCatalogCount;
        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    @InvocableMethod(label='Read Dynamic Email' description='Reads an EXISTING CMS email and reports its real content: whether it has dynamic content, how many PersonalizationPoints, and its heading/paragraph/image blocks (with which are personalized). Use this to answer questions about an existing email or before updating it -- never guess an email\'s contents from its name. Read-only; creates nothing.')
    public static List<Result> readDynamicEmail(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result res = new Result();
            res.found = false; res.isPersonalized = false; res.ppCount = 0;
            res.summary = ''; res.blocksJson = '[]'; res.eligibleSlotsJson = '[]'; res.errorMessage = '';
            res.imageCatalogCount = 0;
            // Echo the requested key so the agent can capture it as the update target
            // deterministically at read time (removes the dependency on the LLM separately
            // calling note_update_target -- reading an email to update it IS the target).
            res.contentKey = (req.contentKey == null ? '' : req.contentKey);
            try {
                // Accept EITHER a CMS content key (MC...) OR a Salesforce record Id from the page the
                // user is on: a ManagedContent Id (20Y..., the CMS email record page / editor retUrl)
                // or a content-version Id (9Ps..., the editor's variantId). This lets an agent wired to
                // currentRecordId read "this email" straight from page context -- no typed key. A raw
                // MC key passes through unchanged. Resolution is one SOQL on ManagedContent (no callout).
                String key = resolveToContentKey(res.contentKey);
                if (String.isBlank(key)) {
                    res.errorMessage = 'Could not resolve "' + res.contentKey + '" to a CMS email. '
                        + 'Provide the email\'s content key (MC...) or its ManagedContent record Id (20Y...).';
                    results.add(res); continue;
                }
                res.contentKey = key;  // echo the RESOLVED key so the update target is the real MC key
                String token = BuildDynamicEmailAction.sharedTokenSource().getAccessToken();
                HttpRequest r = new HttpRequest();
                r.setMethod('GET');
                r.setEndpoint(AuraPocTokenProvider.instanceUrl()
                    + '/services/data/v66.0/connect/cms/contents/' + EncodingUtil.urlEncode(key, 'UTF-8'));
                r.setHeader('Authorization', 'Bearer ' + token);
                r.setTimeout(30000);
                HttpResponse resp = new Http().send(r);
                if (resp.getStatusCode() != 200) {
                    res.errorMessage = 'Could not read email "' + key + '" (HTTP '
                        + resp.getStatusCode() + '). Check the content key.';
                    results.add(res); continue;
                }
                Map<String, Object> content = (Map<String, Object>) JSON.deserializeUntyped(resp.getBody());
                Map<String, Object> cb = content.get('contentBody') instanceof Map<String, Object>
                    ? (Map<String, Object>) content.get('contentBody') : new Map<String, Object>();
                res.found = true;
                res.title = String.valueOf(content.get('title'));

                List<Object> ops = cb.get('sfdc_cms:operations') instanceof List<Object>
                    ? (List<Object>) cb.get('sfdc_cms:operations') : new List<Object>();
                List<Object> variants = cb.get('sfdc_cms:variants') instanceof List<Object>
                    ? (List<Object>) cb.get('sfdc_cms:variants') : new List<Object>();
                res.ppCount = ops.size();
                res.isPersonalized = ops.size() > 0;

                // Which block ids are personalization targets, and the PP names.
                Set<String> targetedIds = new Set<String>();
                List<String> ppNames = new List<String>();
                // A targetId-less operation personalizes the SUBJECT LINE + PREHEADER component (not a
                // block). If one already exists, the subject/preheader is already personalized and can't
                // be re-personalized (one such PP max), same rule as an already-personalized block.
                Boolean subjectPreheaderPersonalized = false;
                for (Object o : ops) {
                    if (!(o instanceof Map<String, Object>)) { continue; }
                    Map<String, Object> op = (Map<String, Object>) o;
                    String tId = op.get('targetId') == null ? '' : String.valueOf(op.get('targetId'));
                    if (String.isBlank(tId) || tId == 'null') {
                        subjectPreheaderPersonalized = true;   // targetId-less => subject/preheader component
                    } else {
                        targetedIds.add(tId);
                    }
                    Object ppObj = op.get('attributes') instanceof Map<String, Object>
                        ? ((Map<String, Object>) op.get('attributes')).get('personalizationPoint') : null;
                    if (ppObj instanceof Map<String, Object>) {
                        ppNames.add(String.valueOf(((Map<String, Object>) ppObj).get('name')));
                    }
                }
                // Current base subject/preheader (shown in the summary as the defaults to vary from).
                String curSubject = cb.get('subjectLine') == null ? '' : String.valueOf(cb.get('subjectLine'));
                String curPreheader = cb.get('preheader') == null ? '' : String.valueOf(cb.get('preheader'));

                // Image-DC precondition: personalizing an image = SWAPPING a distinct picture per audience,
                // which the deterministic auto-assign fills from the org's image catalog. With fewer than
                // MIN_IMAGES_FOR_SWAP distinct images there aren't enough to make a visible swap (every
                // audience would get the same picture, or 0 images fails the build), so we only OFFER image
                // slots as eligible when the catalog clears that floor. Counted once here (best-effort;
                // a catalog error leaves the count 0 -> image slots simply aren't offered, never a hard fail).
                Integer imageCatalogCount = countCatalogImages();
                Boolean imageSwapViable = imageCatalogCount >= MIN_IMAGES_FOR_SWAP;
                res.imageCatalogCount = imageCatalogCount;

                // Flatten the CONTENT blocks (heading/paragraph/image/button) in document order and
                // number them with a 1-based `slot` -- a CONSTANT address the agent references for an
                // update (Update walks the same content-filtered tree, so slot N is the same block on
                // both sides). Structural wrappers (section/column) are skipped -- they are not slots.
                // Each block carries its real `id` (what an operation targets) and its `personalized`
                // flag so already-DC slots can be marked INELIGIBLE for update.
                List<Map<String, Object>> blocks = new List<Map<String, Object>>();
                collectBlocks(cb.get('sfdc_cms:block'), blocks);
                List<Object> out = new List<Object>();
                Integer nText = 0, nImg = 0, slot = 0;
                List<String> slotLines = new List<String>();
                List<Object> eligible = new List<Object>();      // closed set the agent offers
                List<String> eligibleLines = new List<String>();
                Boolean imageSlotsSuppressed = false;            // true if we hid image slots for too-few images
                Integer imgOrdinal = 0;   // 1-based position among image blocks (1st image = logo)
                for (Map<String, Object> b : blocks) {
                    String def = String.valueOf(b.get('definition'));
                    if (def != 'lightning/heading' && def != 'lightning/paragraph'
                        && def != 'lightning/image' && def != 'lightning/actionButton') { continue; }
                    slot++;
                    Boolean personalized = targetedIds.contains(String.valueOf(b.get('id')));
                    String rawText = b.get('text') == null ? '' : String.valueOf(b.get('text'));
                    if (def == 'lightning/image') { nImg++; imgOrdinal++; } else { nText++; }
                    // Classify the block's ROLE so we don't sweep the wrong slots into a blanket "all".
                    //  logo   = the FIRST image (brand mark at the top) -- never content-personalized.
                    //  footer = boilerplate paragraph (address / unsubscribe / preference / copyright /
                    //           merge-field-only) -- legal/nav text, not audience-varying content.
                    //  image  = a body/hero image (swap-eligible).  text = real body copy/heading/button.
                    String role;
                    if (def == 'lightning/image') { role = (imgOrdinal == 1) ? 'logo' : 'image'; }
                    else if (isFooterText(rawText)) { role = 'footer'; }
                    else { role = 'text'; }
                    out.add(new Map<String, Object>{
                        'slot' => slot, 'id' => b.get('id'), 'def' => def, 'role' => role,
                        'text' => b.get('text'), 'contentKey' => b.get('contentKey'),
                        'personalized' => personalized
                    });
                    // Human-readable slot line for the summary; mark role + already-personalized.
                    String kind = def.substringAfter('/');
                    String roleTag = (role == 'logo') ? ' logo' : (role == 'footer') ? ' footer' : '';
                    slotLines.add('slot ' + slot + ' ' + kind + roleTag + (personalized ? ' (already personalized)' : ''));
                    // Eligible = unpersonalized AND a role we should personalize by a content axis.
                    // Exclude logo images and footer/boilerplate paragraphs (they shouldn't vary by
                    // audience). Body images swap (>= MIN_IMAGES_FOR_SWAP); body text varies copy.
                    if (!personalized && role != 'logo' && role != 'footer') {
                        if (def == 'lightning/image') {
                            if (imageSwapViable) {
                                eligible.add(new Map<String, Object>{ 'slot' => slot, 'type' => 'image', 'swap' => true });
                                eligibleLines.add('slot ' + slot + ' (image -- swap the image per audience)');
                            } else {
                                imageSlotsSuppressed = true;
                            }
                        } else {
                            String th = rawText.replaceAll('<[^>]+>', ' ').replaceAll('\\s+', ' ').trim();
                            if (th.length() > 60) { th = th.substring(0, 60) + '...'; }
                            eligible.add(new Map<String, Object>{ 'slot' => slot, 'type' => kind, 'textHint' => th });
                            eligibleLines.add('slot ' + slot + ' (' + kind + (String.isBlank(th) ? '' : ': "' + th + '"') + ')');
                        }
                    }
                }
                // SUBJECT/PREHEADER component -- offer it as an eligible target (update path only; Read is
                // always an existing email). It is not a numbered slot: subject + preheader vary TOGETHER
                // per audience. Ineligible when a targetId-less op already personalizes them.
                if (!subjectPreheaderPersonalized) {
                    eligible.add(new Map<String, Object>{ 'type' => 'subject_preheader', 'component' => true });
                    eligibleLines.add('the subject line + preheader (varies both together per audience)');
                }
                // Carry the subject/preheader state INTO blocksJson as a sentinel row (no slot number) so
                // downstream Validate -- which only receives emailBlocksJson -- can tell WHY a vacuous
                // subject/preheader update produced nothing (already personalized) and say so specifically,
                // instead of the generic "slot ineligible" message. component:true + no 'slot' key marks it.
                out.add(new Map<String, Object>{
                    'type' => 'subject_preheader', 'component' => true,
                    'personalized' => subjectPreheaderPersonalized });
                res.blocksJson = JSON.serialize(out);
                res.eligibleSlotsJson = JSON.serialize(eligible);

                String slotList = String.join(slotLines, ', ');
                // The closed-set offer, appended to the summary the agent relays verbatim. Rendered as a
                // BULLET LIST (one "- " line per eligible target) so every option -- including the
                // subject line + preheader COMPONENT -- reads as a first-class, equal choice. (As a
                // trailing comma-clause the LLM demoted the subject/preheader to a footnote; a bullet
                // keeps it a peer of the numbered slots.)
                String offer;
                if (eligible.isEmpty()) {
                    offer = ' Nothing is eligible to personalize (all slots and the subject/preheader are already personalized).';
                } else {
                    List<String> bullets = new List<String>();
                    for (String ln : eligibleLines) { bullets.add('\n- ' + ln); }
                    offer = ' You can add personalization to any of these:' + String.join(bullets, '')
                        + '\nTell me which to personalize and by what (e.g. by industry, or by account tier)'
                        + ' -- text slots vary the copy, image slots swap the image, the subject line + preheader vary together -- or say all.';
                }
                // If this email has image blocks we did NOT offer because the org has too few images to
                // swap, say so -- the fix is a data task (add stock images), not something to retry.
                if (imageSlotsSuppressed) {
                    offer += ' (This email has image blocks, but personalizing an image needs at least '
                        + MIN_IMAGES_FOR_SWAP + ' distinct images in this org to swap between; only '
                        + imageCatalogCount + ' found, so image slots aren\'t offered. Add more stock/brand images to enable image personalization.)';
                }
                res.summary = (res.isPersonalized
                    ? ('"' + res.title + '" HAS dynamic content: ' + ops.size() + ' personalization point(s) across '
                        + variants.size() + ' variant(s). PPs: ' + String.join(ppNames, ', ') + '. Slots: '
                        + slotList + '. (Already-personalized slots cannot be re-personalized.)')
                    : ('"' + res.title + '" has NO dynamic content -- it is a static email. Slots: '
                        + slotList + '.')) + offer;
            } catch (Exception e) {
                res.errorMessage = e.getMessage();
            }
            results.add(res);
        }
        return results;
    }

    // Normalize whatever identity the caller has into a CMS content key (MC...). A raw content key
    // passes straight through. A ManagedContent Id (20Y...) -- what a CMS email record page hands an
    // agent as currentRecordId, and what the editor URL carries in its retUrl -- is looked up directly.
    // Anything else (a content-VERSION Id 9Ps..., or a lookup miss) returns '' so the caller fails loud
    // with a clear message; a 9Ps variantId isn't resolvable in Apex (ManagedContentVersion isn't an
    // Apex-queryable sObject on this org), but every page surface also exposes the 20Y... record Id, so
    // callers should pass that. One SOQL, no callout; "with sharing" limits it to records the user sees.
    private static String resolveToContentKey(String raw) {
        if (String.isBlank(raw)) { return ''; }
        String v = raw.trim();
        // Already a CMS content key.
        if (v.startsWith('MC')) { return v; }
        // ManagedContent record Id (15- or 18-char, prefix 20Y). Apex-SOQL-queryable (verified SIC2025).
        if (v.startsWith('20Y')) {
            List<ManagedContent> mc = [SELECT ContentKey FROM ManagedContent WHERE Id = :v LIMIT 1];
            return mc.isEmpty() ? '' : mc[0].ContentKey;
        }
        // Unknown shape -- let the caller report it. (Do NOT assume it's a key; a bad guess 404s opaquely.)
        return '';
    }

    // Count DISTINCT images in the org's catalog (brand-less stock library), for the image-DC offer
    // floor. Best-effort: any failure returns 0, which simply means image slots aren't offered -- never
    // a hard error on the read. Reuses GetAssetCatalogAction (same brand-less stock fetch the update
    // pipeline uses), so the count matches what the auto-assign would actually have to draw from.
    private static Integer countCatalogImages() {
        try {
            GetAssetCatalogAction.Request gc = new GetAssetCatalogAction.Request();
            gc.brandName = '';
            gc.includeStock = true;
            String aj = GetAssetCatalogAction.getAssetCatalog(new List<GetAssetCatalogAction.Request>{ gc })[0].assetsJson;
            if (String.isBlank(aj)) { return 0; }
            Set<String> keys = new Set<String>();
            for (Object o : (List<Object>) JSON.deserializeUntyped(aj)) {
                if (!(o instanceof Map<String, Object>)) { continue; }
                Object ck = ((Map<String, Object>) o).get('contentKey');
                if (ck != null && String.isNotBlank(String.valueOf(ck))) { keys.add(String.valueOf(ck)); }
            }
            return keys.size();
        } catch (Exception e) {
            return 0;   // offer floor not met -> image slots simply not offered; no hard fail
        }
    }

    // Heuristic: is this paragraph FOOTER/boilerplate (legal/nav), not audience-varying body content?
    // Footers are the last thing to personalize by industry/tier -- they carry the org address,
    // unsubscribe/preference links, and copyright. We classify on the raw text: known footer phrases,
    // the org-address merge field, or text that is essentially ONLY merge fields / entity-encoded links
    // (no real prose). Deliberately conservative -- when unsure, treat as body text (personalizable).
    private static Boolean isFooterText(String rawText) {
        if (String.isBlank(rawText)) { return false; }
        String lower = rawText.toLowerCase();
        // Known footer signals.
        if (lower.contains('unsubscribe') || lower.contains('preference manager')
            || lower.contains('manage preferences') || lower.contains('all rights reserved')
            || lower.contains('{!$organization.address}') || lower.contains('view in browser')
            || lower.contains('©') || lower.contains('&copy;') || lower.contains('&#169;')) {
            return true;
        }
        // Strip tags + entities + merge fields; if almost nothing readable remains, it's boilerplate.
        String stripped = rawText
            .replaceAll('\\{![^}]*\\}', ' ')        // merge fields {!$...}
            .replaceAll('&lt;[^&]*&gt;', ' ')       // entity-encoded tags
            .replaceAll('<[^>]+>', ' ')             // raw tags
            .replaceAll('&[a-z#0-9]+;', ' ')        // remaining entities (&#124;, &amp; ...)
            .replaceAll('[|\\-–—•]', ' ')           // separators
            .replaceAll('\\s+', ' ').trim();
        return stripped.length() < 8;               // essentially no prose left
    }

    private static void collectBlocks(Object node, List<Map<String, Object>> out) {
        if (node instanceof List<Object>) {
            for (Object o : (List<Object>) node) { collectBlocks(o, out); }
        } else if (node instanceof Map<String, Object>) {
            Map<String, Object> n = (Map<String, Object>) node;
            if (n.get('type') == 'block' && n.get('definition') != null) {
                Map<String, Object> attrs = n.get('attributes') instanceof Map<String, Object>
                    ? (Map<String, Object>) n.get('attributes') : new Map<String, Object>();
                String ck = null;
                if (attrs.get('imageInfo') instanceof Map<String, Object>) {
                    Map<String, Object> ii = (Map<String, Object>) attrs.get('imageInfo');
                    if (ii.get('source') instanceof Map<String, Object>) {
                        Map<String, Object> src = (Map<String, Object>) ii.get('source');
                        if (src.get('ref') instanceof Map<String, Object>) {
                            ck = String.valueOf(((Map<String, Object>) src.get('ref')).get('contentKey'));
                        }
                    }
                }
                out.add(new Map<String, Object>{
                    'id' => n.get('id'), 'definition' => n.get('definition'),
                    'text' => attrs.get('text'), 'contentKey' => ck
                });
            }
            for (Object v : n.values()) { collectBlocks(v, out); }
        }
    }
}
