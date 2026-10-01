// ADD dynamic content to an ALREADY-BUILT email. Apex allows only one @InvocableMethod per class,
// so this lives apart from BuildDynamicEmailAction and reuses its wiring via the shared* wrappers.
// Flow: fetch the live body -> recover block ids by matching content (blocks carry only
// id/definition/attributes, no semantic key) -> MERGE new PersonalizationPoints into the existing
// operations/variants (never overwrite) -> PUT the merged body back. The block tree (copy/layout)
// is preserved untouched; only operations/variants/expressions change.
public with sharing class UpdateDynamicEmailAction {

    public class UpdateException extends Exception {}

    public class Request {
        @InvocableVariable(label='Content Key' required=true)
        public String contentKey;
        // Same shape as Build's personalizationsJson, EXCEPT each target identifies its existing
        // block by content: matchText (heading/paragraph) or matchContentKey (image), plus the
        // usual elementKey (internal label) / blockDefinition / textByDecision.
        @InvocableVariable(label='Personalizations JSON' required=true)
        public String personalizationsJson;
        @InvocableVariable(label='Assets JSON')
        public String assetsJson;
        @InvocableVariable(label='Data Space Name')
        public String dataSpaceName;
        @InvocableVariable(label='Data Graph Name')
        public String profileDataGraphName;
        // Display-only: shown on the confirm dialog for review (mirrors BuildDynamicEmailAction).
        // An LLM-filled input is required for the confirm button to render; the update logic ignores it.
        @InvocableVariable(label='Personalization')
        public String personalizationSummary;
        // The target SLOT numbers (from ReadDynamicEmailAction's numbered slots), as a JSON array in
        // the SAME order as the PP specs -- axis i targets slot targetSlots[i]. This is the primary,
        // deterministic block-identity path: a slot resolves to the Nth content block's real id
        // (Update walks the same content-filtered tree Read numbered). Empty falls back to each
        // target's matchText/matchContentKey. e.g. "[4]" personalizes the 4th content slot.
        @InvocableVariable(label='Target Slots JSON')
        public String targetSlotsJson;
    }

    public class Result {
        @InvocableVariable(label='Success')
        public Boolean success;
        @InvocableVariable(label='Content Key')
        public String contentKey;
        // Deep link to the CMS workspace holding the updated email (same helper Build uses).
        @InvocableVariable(label='Content URL')
        public String contentUrl;
        @InvocableVariable(label='Personalization Point Name')
        public String ppName;
        @InvocableVariable(label='Variant Ids JSON')
        public String variantIdsJson;
        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    @InvocableMethod(label='Update Dynamic Email' description='Adds dynamic content personalization to an EXISTING CMS email, merging the new PersonalizationPoints/decisions/variants into whatever is already there. Targets existing blocks by their content (heading/paragraph text or image contentKey). Preserves the email copy, layout, and any existing dynamic content. Read-only on the block tree; only operations/variants are extended.')
    public static List<Result> updateDynamicEmail(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result res = new Result();
            res.success = false;
            res.contentKey = req.contentKey;
            res.ppName = '';
            res.variantIdsJson = '[]';
            res.errorMessage = '';
            try {
                String accessToken = BuildDynamicEmailAction.sharedTokenSource().getAccessToken();
                String dataSpace = String.isNotBlank(req.dataSpaceName) ? req.dataSpaceName : 'default';

                // 1. Fetch the existing content: body + variant record id.
                HttpRequest getReq = new HttpRequest();
                getReq.setMethod('GET');
                getReq.setEndpoint(AuraPocTokenProvider.instanceUrl()
                    + '/services/data/v66.0/connect/cms/contents/' + EncodingUtil.urlEncode(req.contentKey, 'UTF-8'));
                getReq.setHeader('Authorization', 'Bearer ' + accessToken);
                getReq.setTimeout(30000);
                HttpResponse getRes = new Http().send(getReq);
                if (getRes.getStatusCode() != 200) {
                    res.errorMessage = 'Could not read the email to update (HTTP ' + getRes.getStatusCode()
                        + '): ' + getRes.getBody();
                    results.add(res); continue;
                }
                Map<String, Object> content = (Map<String, Object>) JSON.deserializeUntyped(getRes.getBody());
                Map<String, Object> contentBody = (Map<String, Object>) content.get('contentBody');
                String variantRecordId = String.valueOf(content.get('managedContentVariantId'));
                String managedContentId = String.valueOf(content.get('managedContentId'));
                // Direct record link for the final chat -- opens the specific email, not the workspace.
                res.contentUrl = BuildDynamicEmailAction.cmsContentUrl(managedContentId);

                // 2. Parse the PP specs and resolve each target to an EXISTING block id -- by SLOT
                // number (primary) or by matchText/matchContentKey (fallback). Refuses a slot that is
                // out of range, the wrong block type, or already personalized (edit-existing-DC is
                // off-limits for now).
                List<Object> ppSpecs = (List<Object>) JSON.deserializeUntyped(AuraPocJson.stripFence(req.personalizationsJson));
                Map<String, Object> blockIds = recoverBlockIds(contentBody, ppSpecs, req.targetSlotsJson);

                // Resolve image-SWAP variant keys by name (Update has no logo/header override inputs,
                // so role-based variant images aren't supported here -- name or literal only), then
                // existence-check them. Same LLM-key-free guarantee as Build.
                Set<String> variantImgKeys = BuildDynamicEmailAction.sharedResolveVariantImageRefs(
                    ppSpecs, req.assetsJson, '', '');
                BuildDynamicEmailAction.sharedValidateImageContentKeys(accessToken, variantImgKeys);

                // 3. Seed operations/variants/expressions from the EXISTING body so wiring MERGES.
                List<Object> allOperations = contentBody.get('sfdc_cms:operations') instanceof List<Object>
                    ? (List<Object>) contentBody.get('sfdc_cms:operations') : new List<Object>();
                List<Object> allVariants = contentBody.get('sfdc_cms:variants') instanceof List<Object>
                    ? (List<Object>) contentBody.get('sfdc_cms:variants') : new List<Object>();
                Set<String> alreadyTargeted = new Set<String>();
                for (Object opObj : allOperations) {
                    if (opObj instanceof Map<String, Object>) {
                        alreadyTargeted.add(String.valueOf(((Map<String, Object>) opObj).get('targetId')));
                    }
                }
                Boolean collision = false;
                for (String k : blockIds.keySet()) {
                    if (alreadyTargeted.contains(String.valueOf(blockIds.get(k)))) {
                        res.errorMessage = 'The target block for "' + k + '" already has dynamic content. '
                            + 'CMS allows only one personalization per block -- remove the existing '
                            + 'personalization first, or target a different block.';
                        collision = true;
                    }
                }
                if (collision) { results.add(res); continue; }

                Map<String, Object> expressionsByKey = new Map<String, Object>();
                if (contentBody.get('lightning:expressions') instanceof List<Object>) {
                    for (Object e : (List<Object>) contentBody.get('lightning:expressions')) {
                        Map<String, Object> expr = (Map<String, Object>) e;
                        expressionsByKey.put(String.valueOf(expr.get('sfdcExpressionKey')), expr);
                    }
                }

                String graphName = String.isNotBlank(req.profileDataGraphName)
                    ? req.profileDataGraphName : resolveDefaultGraphName(accessToken);

                // 4. Wire -- append the new PP(s) into the seeded lists (reuses the create path).
                AuraSessionMinter.Session sess = AuraSessionMinter.mint(accessToken, AuraPocTokenProvider.instanceUrl());
                String auraContextJson = JSON.serialize(new Map<String, Object>{
                    'mode' => 'PROD', 'fwuid' => sess.fwuid, 'app' => sess.appName, 'loaded' => sess.loaded,
                    'dn' => new List<Object>(), 'globals' => new Map<String, Object>(), 'uad' => true
                });
                List<Object> newVariantIdEntries = new List<Object>();
                List<String> createdPpNames = new List<String>();
                try {
                    BuildDynamicEmailAction.sharedWirePersonalizationsInner(ppSpecs, sess, auraContextJson,
                        expressionsByKey, blockIds, dataSpace, graphName, managedContentId,
                        allOperations, allVariants, newVariantIdEntries, createdPpNames);
                } catch (Exception e) {
                    for (String pp : createdPpNames) { BuildDynamicEmailAction.sharedDeletePp(sess, auraContextJson, pp); }
                    throw e;
                }

                // 5. Write the merged body back -- only DC arrays + data provider/expressions change.
                contentBody.put('lightning:dataProviders', new List<Object>{ BuildDynamicEmailAction.sharedDataGraphDataProvider(graphName, dataSpace) });
                contentBody.put('sfdc_cms:operations', allOperations);
                contentBody.put('sfdc_cms:variants', allVariants);
                contentBody.put('lightning:expressions', new List<Object>(expressionsByKey.values()));

                // DOUBLE-ESCAPE FIX: the CMS content GET returns block text HTML-entity-encoded
                // ("&lt;a href=...", "&#124;"), and the variants PUT re-escapes '&' on write -- so
                // re-PUTting the read-back body would DOUBLE-escape every existing block that contains
                // entities (footers with pipes/©/unsubscribe links, or built-in-agent HTML-in-paragraph),
                // compounding a layer per update. We only ADD dynamic content; we must not rewrite the
                // existing block copy. So decode ONE entity layer on each block's text before the PUT --
                // the CMS re-encode then nets back to the original single-escaped stored value. Proven on
                // a live round-trip: text stays single-escaped, not double, not stripped. Numeric entities
                // decode first, named next, &amp; LAST (else "&amp;lt;" would wrongly become "<").
                decodeBlockTextOneLayer(contentBody.get('sfdc_cms:block'));

                HttpRequest putReq = new HttpRequest();
                putReq.setMethod('PUT');
                putReq.setEndpoint(AuraPocTokenProvider.instanceUrl()
                    + '/services/data/v66.0/connect/cms/contents/variants/' + variantRecordId);
                putReq.setHeader('Content-Type', 'application/json');
                putReq.setHeader('Authorization', 'Bearer ' + accessToken);
                putReq.setBody(JSON.serialize(new Map<String, Object>{ 'contentBody' => contentBody }));
                putReq.setTimeout(30000);
                HttpResponse putRes = new Http().send(putReq);
                if (putRes.getStatusCode() != 200 && putRes.getStatusCode() != 204) {
                    for (String pp : createdPpNames) { BuildDynamicEmailAction.sharedDeletePp(sess, auraContextJson, pp); }
                    res.errorMessage = 'Update PUT failed: HTTP ' + putRes.getStatusCode() + ': ' + putRes.getBody();
                    results.add(res); continue;
                }

                res.success = true;
                res.ppName = JSON.serialize(createdPpNames);
                res.variantIdsJson = JSON.serialize(newVariantIdEntries);
            } catch (Exception e) {
                res.errorMessage = e.getMessage();
            }
            results.add(res);
        }
        return results;
    }

    // Recover elementKey -> existing block id. PRIMARY path = SLOT number: the tool passes
    // targetSlotsJson (axis order), each slot resolves to the Nth CONTENT block (same content-filtered
    // ordered walk Read numbered), guarded for range/type/eligibility. FALLBACK = matchText
    // (heading/paragraph) or matchContentKey (image). Fails loud on zero/ambiguous/ineligible so a
    // wrong or already-personalized block is never targeted.
    private static Map<String, Object> recoverBlockIds(Map<String, Object> contentBody, List<Object> ppSpecs, String targetSlotsJson) {
        List<Map<String, Object>> blocks = new List<Map<String, Object>>();
        collectBlocks(contentBody.get('sfdc_cms:block'), blocks);

        // The SAME content-filtered ordered list Read numbered as slots (1-based). Structural
        // wrappers are excluded so slot N here == slot N in the read summary.
        List<Map<String, Object>> contentBlocks = new List<Map<String, Object>>();
        for (Map<String, Object> b : blocks) {
            String d = String.valueOf(b.get('definition'));
            if (d == 'lightning/heading' || d == 'lightning/paragraph'
                || d == 'lightning/image' || d == 'lightning/actionButton') { contentBlocks.add(b); }
        }
        // Ids already carrying a personalization operation -- ineligible to (re-)personalize.
        Set<String> personalizedIds = new Set<String>();
        if (contentBody.get('sfdc_cms:operations') instanceof List<Object>) {
            for (Object o : (List<Object>) contentBody.get('sfdc_cms:operations')) {
                if (o instanceof Map<String, Object>) { personalizedIds.add(String.valueOf(((Map<String, Object>) o).get('targetId'))); }
            }
        }
        // Slot bindings from the tool: {elementKey, slot} pairs -> a by-NAME map, so a target finds
        // its slot by its own elementKey (order-independent; two same-type slots never confused).
        Map<String, Integer> slotByElementKey = new Map<String, Integer>();
        if (String.isNotBlank(targetSlotsJson)) {
            try {
                for (Object o : (List<Object>) JSON.deserializeUntyped(AuraPocJson.stripFence(targetSlotsJson))) {
                    if (!(o instanceof Map<String, Object>)) { continue; }
                    Map<String, Object> pair = (Map<String, Object>) o;
                    Object ek = pair.get('elementKey');
                    Object sl = pair.get('slot');
                    if (ek != null && sl != null) {
                        try { slotByElementKey.put(String.valueOf(ek), Integer.valueOf(String.valueOf(sl))); }
                        catch (Exception ignore) { /* skip malformed slot */ }
                    }
                }
            } catch (Exception ignore) { /* no usable bindings -> matchText fallback */ }
        }

        Map<String, Object> blockIds = new Map<String, Object>();
        for (Object ppObj : ppSpecs) {
            Map<String, Object> pp = (Map<String, Object>) ppObj;
            List<Object> targets = (List<Object>) JSON.deserializeUntyped(String.valueOf(pp.get('targetsJson')));
            for (Object tObj : targets) {
                Map<String, Object> t = (Map<String, Object>) tObj;
                String elementKey = String.valueOf(t.get('elementKey'));
                String tDef = t.get('blockDefinition') == null ? '' : String.valueOf(t.get('blockDefinition'));
                // Subject/preheader component: personalizes email metadata, not a block -- no block id to
                // recover (Build emits a targetId-less op + {subjectLine,preheader} variant body). Skip
                // block resolution entirely for it.
                if (tDef == 'sfdc_cms__subjectPreheader' || elementKey == 'subject_preheader') { continue; }
                // The slot bound to THIS target by name (not position).
                Integer slotNum = slotByElementKey.get(elementKey);

                // PRIMARY: resolve by slot number when supplied for this axis.
                if (slotNum != null) {
                    if (slotNum < 1 || slotNum > contentBlocks.size()) {
                        throw new UpdateException('Update target "' + elementKey + '" points at slot ' + slotNum
                            + ', but this email has only ' + contentBlocks.size() + ' content slot(s). '
                            + 'Read the email to see its slot numbers.');
                    }
                    Map<String, Object> blk = contentBlocks[slotNum - 1];
                    String blkDef = String.valueOf(blk.get('definition'));
                    String blkId = String.valueOf(blk.get('id'));
                    // Type guard: the plan's block type must match the real slot's type.
                    String wantDef = t.get('blockDefinition') == null ? '' : String.valueOf(t.get('blockDefinition'));
                    if (String.isNotBlank(wantDef) && wantDef != blkDef) {
                        throw new UpdateException('Update target "' + elementKey + '" expects a ' + wantDef
                            + ' but slot ' + slotNum + ' is a ' + blkDef + '. Pick the slot whose type matches.');
                    }
                    // Eligibility guard: editing an already-personalized block is off-limits for now.
                    if (personalizedIds.contains(blkId)) {
                        throw new UpdateException('Slot ' + slotNum + ' already has dynamic content. Editing an '
                            + 'existing personalized block is not supported yet -- choose a slot that is not '
                            + 'already personalized.');
                    }
                    blockIds.put(elementKey, blkId);
                    continue;
                }

                // FALLBACK: match by text / contentKey (when no slot was supplied).
                String matchText = normalizeForMatch(t.get('matchText') == null ? '' : String.valueOf(t.get('matchText')));
                String matchCk = t.get('matchContentKey') == null ? '' : String.valueOf(t.get('matchContentKey')).trim();
                List<String> hits = new List<String>();
                if (String.isNotBlank(matchCk)) {
                    // Image target -- match on the block's imageInfo contentKey (exact).
                    for (Map<String, Object> b : blocks) {
                        if (matchCk == String.valueOf(b.get('contentKey'))) { hits.add(String.valueOf(b.get('id'))); }
                    }
                } else if (String.isNotBlank(matchText)) {
                    // Text target. matchText is brittle to match char-for-char (the LLM planned copy
                    // may differ from the live block by punctuation, a merge token like
                    // {!$Expression.FirstName}, or the user quoted only a fragment). Match in tiers,
                    // most precise first, and only fall to the next tier if the current one found
                    // nothing -- so an exact hit is never diluted by loose substring hits:
                    //   1. exact (normalized)  2. block CONTAINS matchText (user quoted a fragment)
                    //   3. matchText CONTAINS block text (LLM added words around the real text).
                    List<String> exact = new List<String>();
                    List<String> blockHasQuery = new List<String>();
                    List<String> queryHasBlock = new List<String>();
                    for (Map<String, Object> b : blocks) {
                        String bt = normalizeForMatch(b.get('text') == null ? '' : String.valueOf(b.get('text')));
                        if (String.isBlank(bt)) { continue; }
                        if (bt == matchText) { exact.add(String.valueOf(b.get('id'))); }
                        else if (matchText.length() >= 8 && bt.contains(matchText)) { blockHasQuery.add(String.valueOf(b.get('id'))); }
                        else if (matchText.length() >= 8 && matchText.contains(bt)) { queryHasBlock.add(String.valueOf(b.get('id'))); }
                    }
                    hits = !exact.isEmpty() ? exact
                        : !blockHasQuery.isEmpty() ? blockHasQuery
                        : queryHasBlock;
                }
                if (hits.isEmpty()) {
                    throw new UpdateException('Update target "' + elementKey + '" matched no block in the email '
                        + '(matchText/matchContentKey did not find an existing heading, paragraph, or image). '
                        + 'Read the email first (Read Dynamic Email) and copy a block\'s EXACT text or image content key.');
                }
                if (hits.size() > 1) {
                    throw new UpdateException('Update target "' + elementKey + '" matched ' + hits.size()
                        + ' blocks -- ambiguous. Use text/contentKey unique to the block to personalize.');
                }
                if (personalizedIds.contains(hits[0])) {
                    throw new UpdateException('The block matched for "' + elementKey + '" already has dynamic '
                        + 'content. Editing an existing personalized block is not supported yet -- choose a '
                        + 'block that is not already personalized.');
                }
                blockIds.put(elementKey, hits[0]);
            }
        }
        return blockIds;
    }

    // Normalize block/match text so cosmetic differences don't defeat matching: drop merge tokens
    // ({!$Expression.FirstName} etc.), strip HTML tags, collapse whitespace, lowercase, and trim
    // surrounding punctuation. Both the block text and the LLM's matchText go through this before
    // comparison, so "Welcome {!$Expression.FirstName}!" and "welcome" compare on "welcome".
    private static String normalizeForMatch(String s) {
        if (String.isBlank(s)) { return ''; }
        String out = s.replaceAll('\\{![^}]*\\}', ' ');   // merge fields / expressions
        out = out.replaceAll('<[^>]*>', ' ');              // any HTML tags
        out = out.replaceAll('\\s+', ' ').trim().toLowerCase();
        out = out.replaceAll('^[\\p{Punct}\\s]+', '').replaceAll('[\\p{Punct}\\s]+$', '');  // edge punctuation
        return out;
    }

    // Walk the block tree and decode ONE layer of HTML entities on every block's `text` attribute, so
    // re-PUTting the read-back body doesn't double-escape existing copy (see the call site). Only the
    // `text` attribute is touched; contentKeys, structure, and everything else are left untouched.
    // Numeric entities decode first, then named, &amp; LAST (order matters: decoding &amp; first would
    // turn "&amp;lt;" into "<" -- a two-layer decode -- instead of the intended single layer "&lt;").
    private static void decodeBlockTextOneLayer(Object node) {
        if (node instanceof List<Object>) {
            for (Object o : (List<Object>) node) { decodeBlockTextOneLayer(o); }
        } else if (node instanceof Map<String, Object>) {
            Map<String, Object> n = (Map<String, Object>) node;
            if (n.get('attributes') instanceof Map<String, Object>) {
                Map<String, Object> attrs = (Map<String, Object>) n.get('attributes');
                if (attrs.get('text') instanceof String) {
                    attrs.put('text', decodeEntitiesOneLayer((String) attrs.get('text')));
                }
            }
            for (Object v : n.values()) { decodeBlockTextOneLayer(v); }
        }
    }

    // Decode exactly ONE layer of the HTML entities the CMS content GET emits. &amp; MUST be last.
    private static String decodeEntitiesOneLayer(String s) {
        if (String.isBlank(s)) { return s; }
        return s
            .replace('&#124;', '|')
            .replace('&#61;', '=')
            .replace('&#39;', '\'')
            .replace('&apos;', '\'')
            .replace('&quot;', '"')
            .replace('&lt;', '<')
            .replace('&gt;', '>')
            .replace('&nbsp;', ' ')
            .replace('&amp;', '&');
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

    // Resolve the org's default data graph name via Tooling, for an update that didn't pass one.
    private static String resolveDefaultGraphName(String accessToken) {
        try {
            HttpRequest r = new HttpRequest();
            r.setMethod('GET');
            r.setEndpoint(AuraPocTokenProvider.instanceUrl() + '/services/data/v66.0/tooling/query?q='
                + EncodingUtil.urlEncode('SELECT DeveloperName FROM DataGraphDefinition LIMIT 1', 'UTF-8'));
            r.setHeader('Authorization', 'Bearer ' + accessToken);
            r.setTimeout(30000);
            HttpResponse resp = new Http().send(r);
            if (resp.getStatusCode() != 200) { return ''; }
            List<Object> recs = (List<Object>) ((Map<String, Object>) JSON.deserializeUntyped(resp.getBody())).get('records');
            if (recs == null || recs.isEmpty()) { return ''; }
            return String.valueOf(((Map<String, Object>) recs[0]).get('DeveloperName'));
        } catch (Exception e) { return ''; }
    }
}
