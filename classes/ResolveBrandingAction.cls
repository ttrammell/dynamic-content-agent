// Deterministically commits the branding decision from the already-looked-up context variables
// (brandContext = Find Brand Assets output, brandVoiceContext = Find Brand Record output) into the
// durable resolved* keys Build Dynamic Email reads. This exists because leaving the commit to an
// LLM-callable tool (resolve_branding_tool) meant the model sometimes looked branding up but never
// committed it -- leaving brandingResolved False and the automatic build permanently blocked (the
// exact failure this fixes). The LLM still decides WHICH brand to look up (context matching); this
// action makes the commit unskippable. Creates nothing. Makes at most one CMS lookup, and only
// as a fallback: when nothing was looked up (no workspace in context), it searches the org's own
// default-email-template assets so the build always has a real workspace + default logo/header
// rather than failing on a missing required workspace.
//
// Classification is by asset name/urlName substring ("logo" / "header"), which matches both the
// per-brand convention ("epicor-78096-logo") and the org-default convention
// ("default-email-template-logo"). Anything unclassifiable is ignored and its slot is suppressed
// rather than guessed. Never lets a brand-RECORD key equal a logo/header IMAGE key -- Build
// Dynamic Email hard-rejects that collision.
public with sharing class ResolveBrandingAction {

    public class Request {
        // Find Brand Assets output: JSON array of {name, urlName, contentKey, workspaceId, ...}.
        // The literal "None available" (or blank) means nothing was looked up -> suppress images.
        @InvocableVariable(label='Brand Context (assets JSON)')
        public String brandContext;

        // Find Brand Record output: JSON array of {name, contentKey, workspaceId, ...}.
        // "None available"/blank means no brand record -> no colorScheme/typography override.
        @InvocableVariable(label='Brand Voice Context (records JSON)')
        public String brandVoiceContext;

        // Optional user-supplied CMS workspace id to PIN (from note_workspace_override). When
        // present, it wins over all auto-resolution tiers -- the escape hatch for when auto-resolve
        // can't find/picks the wrong workspace but the user knows the right id. Blank = auto-resolve.
        @InvocableVariable(label='Workspace Override')
        public String workspaceOverride;
    }

    public class Result {
        @InvocableVariable(label='Resolved Logo Key')
        public String resolvedLogoKey;
        @InvocableVariable(label='Resolved Header Key')
        public String resolvedHeaderKey;
        @InvocableVariable(label='Resolved Brand Record Key')
        public String resolvedBrandRecordKey;
        @InvocableVariable(label='Resolved Content Space Id')
        public String resolvedContentSpaceId;
        @InvocableVariable(label='Include Branding')
        public Boolean includeBranding;
        @InvocableVariable(label='Suppress Logo')
        public Boolean suppressLogo;
        @InvocableVariable(label='Suppress Header')
        public Boolean suppressHeader;
        // Always true on return -- the whole point is that calling this action IS the commit,
        // so the build gate can never be left open by a skipped branding step.
        @InvocableVariable(label='Branding Resolved')
        public Boolean brandingResolved;
        // Human-readable summary of what was resolved, for the pre-approval summary.
        @InvocableVariable(label='Branding Note')
        public String brandingNote;
        // Non-empty ONLY when no CMS workspace could be resolved -- an actionable, build-blocking
        // reason (auth not finished / no Marketing CMS workspace). The agent turns this into a
        // fail-fast stall so a fresh install is told what to fix instead of hitting a cryptic
        // missing-workspace error at build time.
        @InvocableVariable(label='Workspace Error')
        public String workspaceError;
        // The brand ASSET context (name→key pairs) folded together with the brand VOICE prose
        // (description/identity/tone) as one string, so the Plan step can be voice-aware without a
        // second template input. Bound to plan_email_structure_action's BrandContext. When no brand
        // record was found the voice line is omitted, so this is just the asset context.
        @InvocableVariable(label='Plan Brand Context (assets + voice)')
        public String planBrandContext;
    }

    // Same test seam / token source the other callout actions use (DataGraphDetailsAction,
    // BuildDynamicEmailAction) -- Auth.JWTBearerTokenExchange inside AuraPocTokenProvider is a
    // "Web service callout" that Test.setMock(HttpCalloutMock) can't intercept.
    @TestVisible
    static AuraPocTokenSource tokenSource = new AuraPocTokenProvider();

    private static Boolean isBlankContext(String s) {
        return String.isBlank(s) || s == 'None available';
    }

    // Resolve an email-capable CMS workspace id via the Connect CMS /spaces API, mirroring the
    // marketing toolkit's _list_cms_workspaces (web/app.py): keep only Enhanced spaces whose
    // spaceType.apiName is 'marketing', prefer the Default_Content_Workspace, else the first by
    // name for determinism. Returns '' on any error -- the caller then leaves the workspace blank
    // and lets Build Dynamic Email report a plain missing-workspace rather than a Commerce-space
    // content-type 400. This is the only reliable way to tell a "Marketing" space from an
    // "Enhanced CMS"/Commerce one, since that distinction isn't exposed to Apex SOQL.
    // Set by resolveEmailCapableWorkspaceId() to explain WHY it returned '' (auth vs. no marketing
    // space vs. callout error) so the caller can surface an actionable reason instead of a cryptic
    // missing-workspace build failure. Empty string means "resolved fine / not the reason".
    @TestVisible static String workspaceDiag = '';

    private static String resolveEmailCapableWorkspaceId() {
        workspaceDiag = '';
        try {
            String accessToken = tokenSource.getAccessToken();
            HttpRequest httpReq = new HttpRequest();
            httpReq.setMethod('GET');
            httpReq.setEndpoint(AuraPocTokenProvider.instanceUrl()
                + '/services/data/v66.0/connect/cms/spaces');
            httpReq.setHeader('Authorization', 'Bearer ' + accessToken);
            httpReq.setTimeout(30000);
            HttpResponse httpRes = new Http().send(httpReq);
            if (httpRes.getStatusCode() != 200) {
                workspaceDiag = 'the CMS /spaces call returned HTTP ' + httpRes.getStatusCode()
                    + ' -- the JWT/External Client App auth is most likely not finished for this org';
                return '';
            }

            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(httpRes.getBody());
            List<Object> spaces = body.get('spaces') instanceof List<Object>
                ? (List<Object>) body.get('spaces') : new List<Object>();

            String defaultId = '';
            Map<String, Object> firstByName = null;
            for (Object o : spaces) {
                if (!(o instanceof Map<String, Object>)) { continue; }
                Map<String, Object> sp = (Map<String, Object>) o;
                Boolean enhanced = sp.get('isEnhancedSpace') == true;
                Map<String, Object> st = sp.get('spaceType') instanceof Map<String, Object>
                    ? (Map<String, Object>) sp.get('spaceType') : null;
                String typeApi = st == null ? '' : String.valueOf(st.get('apiName'));
                if (!enhanced || typeApi != 'marketing') { continue; }

                if (String.valueOf(sp.get('apiName')) == 'Default_Content_Workspace') {
                    defaultId = String.valueOf(sp.get('id'));
                }
                if (firstByName == null
                        || String.valueOf(sp.get('name')) < String.valueOf(firstByName.get('name'))) {
                    firstByName = sp;
                }
            }
            if (String.isNotBlank(defaultId)) { return defaultId; }
            if (firstByName != null) { return String.valueOf(firstByName.get('id')); }
            workspaceDiag = 'this org has no email-capable CMS workspace (no Enhanced space of type '
                + '"marketing") -- create/enable a Marketing CMS workspace before building emails';
            return '';
        } catch (Exception e) {
            workspaceDiag = 'the CMS /spaces call failed (' + e.getMessage()
                + ') -- likely the JWT/External Client App auth or a Remote Site Setting is missing';
            return '';
        }
    }

    private static List<Object> parseArray(String s) {
        if (isBlankContext(s)) { return new List<Object>(); }
        try {
            Object parsed = JSON.deserializeUntyped(s);
            return parsed instanceof List<Object> ? (List<Object>) parsed : new List<Object>();
        } catch (Exception ignore) {
            return new List<Object>();
        }
    }

    private static Boolean matches(Map<String, Object> asset, String needle) {
        String name = String.valueOf(asset.get('name'));
        String urlName = String.valueOf(asset.get('urlName'));
        String hay = ((name == null ? '' : name) + ' ' + (urlName == null ? '' : urlName)).toLowerCase();
        return hay.contains(needle);
    }

    @InvocableMethod(label='Resolve Branding' description='Deterministically commits the looked-up brand assets/record into the durable resolved branding keys Build Dynamic Email reads. May make read-only callouts to resolve a default CMS workspace when none was supplied. Creates nothing.')
    public static List<Result> resolveBranding(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result res = new Result();
            res.resolvedLogoKey = '';
            res.resolvedHeaderKey = '';
            res.resolvedBrandRecordKey = '';
            res.resolvedContentSpaceId = '';
            res.workspaceError = '';
            res.includeBranding = true;
            res.suppressLogo = true;
            res.suppressHeader = true;
            res.brandingResolved = true;
            res.brandingNote = '';
            // Default to the raw asset context so Plan always gets at least what it got before, even
            // on an early return path; the voice-folded value overwrites this once records are parsed.
            res.planBrandContext = (req.brandContext == null) ? '' : req.brandContext;

            List<String> noteParts = new List<String>();

            Map<String, Object> logo;
            Map<String, Object> header;
            // Tier 0: a user-pinned workspace id wins over every auto-resolution tier below.
            String workspaceId = (req.workspaceOverride == null) ? '' : req.workspaceOverride.trim();
            for (Object o : parseArray(req.brandContext)) {
                if (!(o instanceof Map<String, Object>)) { continue; }
                Map<String, Object> asset = (Map<String, Object>) o;
                if (logo == null && matches(asset, 'logo')) { logo = asset; }
                else if (header == null && matches(asset, 'header')) { header = asset; }
                if (String.isBlank(workspaceId) && asset.get('workspaceId') != null) {
                    workspaceId = String.valueOf(asset.get('workspaceId'));
                }
            }

            // Org-default fallback: if nothing usable was looked up (no workspace from
            // brandContext), deterministically search the org's own default-email-template
            // assets so the build ALWAYS has a real CMS workspace + sensible default
            // logo/header, instead of failing on a missing required workspace. This makes
            // branding bulletproof even when the LLM never looked anything up. Failures here
            // never break resolution -- they fall through to the last-resort workspace below.
            Boolean usedDefaultFallback = false;
            if (String.isBlank(workspaceId)) {
                try {
                    for (Object o : FindBrandAssetsAction.searchAssets('default-email-template', 25)) {
                        if (!(o instanceof Map<String, Object>)) { continue; }
                        Map<String, Object> asset = (Map<String, Object>) o;
                        if (logo == null && matches(asset, 'logo')) { logo = asset; usedDefaultFallback = true; }
                        else if (header == null && matches(asset, 'header')) { header = asset; usedDefaultFallback = true; }
                        if (String.isBlank(workspaceId) && asset.get('workspaceId') != null) {
                            workspaceId = String.valueOf(asset.get('workspaceId'));
                            usedDefaultFallback = true;
                        }
                    }
                } catch (Exception ignore) { /* default-template search failed -> last-resort below */ }
            }

            // Last-resort workspace: even the default-template search found no workspace. Pick a
            // CMS space that actually SUPPORTS the email content type. A blind
            // "SELECT Id FROM ManagedContentSpace ORDER BY Name ASC LIMIT 1" grabs the
            // alphabetically-first space, which is typically an "Enhanced CMS"/Commerce space that
            // rejects sfdc_cms__email at build time with HTTP 400 "content type not supported by
            // this space" (confirmed live: it landed on "All Commerce - Enhanced"). An email-capable
            // workspace is an Enhanced space whose spaceType is "marketing" -- but that type isn't
            // visible to Apex SOQL (ManagedContent.ContentTypeFullyQualifiedName is REST-query-only,
            // and ManagedContentSpace exposes no type column to Apex). So resolve it exactly the way
            // the marketing toolkit's _list_cms_workspaces does: read the Connect CMS /spaces API and
            // filter isEnhancedSpace + spaceType.apiName == 'marketing', preferring the default
            // workspace. Leave blank on failure so Build reports a plain missing-workspace instead
            // of silently 400ing on a Commerce space.
            if (String.isBlank(workspaceId)) {
                workspaceId = resolveEmailCapableWorkspaceId();
                if (String.isNotBlank(workspaceId)) { usedDefaultFallback = true; }
            }

            if (logo != null && logo.get('contentKey') != null) {
                res.resolvedLogoKey = String.valueOf(logo.get('contentKey'));
                res.suppressLogo = false;
            }
            if (header != null && header.get('contentKey') != null) {
                res.resolvedHeaderKey = String.valueOf(header.get('contentKey'));
                res.suppressHeader = false;
            }

            // Brand RECORD (colors/fonts/buttons) from Find Brand Record -- first record only.
            String brandRecName = '';
            String voiceLine = '';
            List<Object> records = parseArray(req.brandVoiceContext);
            if (!records.isEmpty() && records[0] instanceof Map<String, Object>) {
                Map<String, Object> rec = (Map<String, Object>) records[0];
                String recKey = rec.get('contentKey') != null ? String.valueOf(rec.get('contentKey')) : '';
                // Never let the record key collide with a logo/header image key -- Build Dynamic
                // Email hard-rejects that (a record key and an image key are never legitimately equal).
                if (String.isNotBlank(recKey) && recKey != res.resolvedLogoKey && recKey != res.resolvedHeaderKey) {
                    res.resolvedBrandRecordKey = recKey;
                    brandRecName = rec.get('name') != null ? String.valueOf(rec.get('name')) : '';
                }
                if (String.isBlank(workspaceId) && rec.get('workspaceId') != null) {
                    workspaceId = String.valueOf(rec.get('workspaceId'));
                }
                // Fold the record's voice prose (description/identity/tone) into a single line for the
                // Plan step. Only the non-blank parts, so a sparse brand record doesn't emit empties.
                List<String> vp = new List<String>();
                for (String f : new List<String>{ 'description', 'identity', 'tone' }) {
                    Object val = rec.get(f);
                    if (val != null && String.isNotBlank(String.valueOf(val))) {
                        vp.add(f + ': ' + String.valueOf(val));
                    }
                }
                if (!vp.isEmpty()) {
                    voiceLine = 'Brand voice for "' + (String.isNotBlank(brandRecName) ? brandRecName : 'this brand')
                        + '" -- ' + String.join(vp, '; ') + '.';
                }
            }

            // Plan brand context = the asset context the Plan step already gets, plus the voice line
            // (when a brand record with voice was found). One string, so Plan is voice-aware without a
            // second prompt-template input. Falls back to just the asset context when no voice exists.
            String assetCtx = req.brandContext == null ? '' : req.brandContext;
            res.planBrandContext = String.isBlank(voiceLine) ? assetCtx
                : (assetCtx + '\n' + voiceLine);

            res.resolvedContentSpaceId = workspaceId;

            // NAME the resolved assets in the note so the pre-build confirmation is self-verifying --
            // "logo \"Epicor logo\"" vs "logo \"default-email-template-logo\"" makes an
            // Epicor-vs-org-default mismatch obvious at the confirmation step (the exact WEX-default
            // failure that shipped unnoticed when the note only said a generic "logo set").
            String logoName = (logo != null && logo.get('name') != null) ? String.valueOf(logo.get('name')) : '';
            String headerName = (header != null && header.get('name') != null) ? String.valueOf(header.get('name')) : '';
            noteParts.add(res.suppressLogo ? 'no logo' : ('logo "' + logoName + '"'));
            noteParts.add(res.suppressHeader ? 'no header' : ('header "' + headerName + '"'));
            noteParts.add(String.isNotBlank(res.resolvedBrandRecordKey)
                ? ('brand record "' + brandRecName + '" (colors/fonts)')
                : 'no brand record (default colors/fonts)');
            res.brandingNote = 'Branding: ' + String.join(noteParts, ', ')
                + (usedDefaultFallback ? ' -- ORG DEFAULT assets/workspace used, no specific brand resolved' : '') + '.';

            // No workspace resolved by ANY tier -> the build will fail with a cryptic missing-workspace
            // error. Surface the real, actionable reason in the note (shown verbatim in the confirm
            // summary) so a fresh install says WHAT to fix instead of just failing at build time.
            if (String.isBlank(workspaceId)) {
                res.brandingNote += ' WARNING: no CMS workspace could be resolved, so the build will '
                    + 'fail until this is fixed'
                    + (String.isBlank(workspaceDiag) ? '' : (' -- ' + workspaceDiag)) + '.';
                // Actionable, build-blocking reason the agent surfaces as a fail-fast stall.
                res.workspaceError = 'No CMS workspace could be resolved for this org, so no email can '
                    + 'be built'
                    + (String.isBlank(workspaceDiag) ? '' : (' -- ' + workspaceDiag))
                    + '. Provision/enable a Marketing CMS workspace (and finish the JWT/External Client '
                    + 'App setup), then try again.';
            }

            results.add(res);
        }
        return results;
    }
}
