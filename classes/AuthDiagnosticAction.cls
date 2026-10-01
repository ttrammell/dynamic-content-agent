// Self-check for the agent's JWT self-auth + CMS workspace availability, so a fresh install can be
// troubleshooted from inside the conversation instead of failing cryptically at build time. It
// attempts to mint a token (via the same AuraPocTokenProvider the real actions use), and on success
// does one read-only /connect/cms/spaces call to confirm end-to-end and list the email-capable
// (Enhanced + Marketing) workspaces. NEVER returns the token itself -- only pass/fail + actionable
// guidance mapped from the failure. Creates nothing; the only callouts are read-only.
//
// It ALSO probes the headless Aura-session leg (AuraSessionMinter.mint) that dynamic-content
// personalization rides on. The REST /connect/cms/spaces call does NOT exercise that leg, so a
// green REST result used to say nothing about whether personalization would work -- and the Aura
// bootstrap is the most fragile part (undocumented; a platform release can change its shape). The
// probe only bootstraps a session (parses fwuid/app); it creates nothing. It is reported as a
// SEPARATE signal (auraSessionReady) and does NOT gate `success`, because a non-personalized email
// build needs only the REST leg -- a failed Aura leg should narrow the guidance, not fail the check.
public with sharing class AuthDiagnosticAction {

    public class Request {
        // No inputs needed -- the check is entirely about this org's own auth/config. Kept for the
        // invocable contract; ignored.
        @InvocableVariable(label='Unused')
        public String unused;
    }

    public class Result {
        @InvocableVariable(label='Success')
        public Boolean success;                 // token minted AND spaces call returned 200
        @InvocableVariable(label='Token Minted')
        public Boolean tokenMinted;             // the JWT bearer mint itself succeeded
        @InvocableVariable(label='Aura Session Ready')
        public Boolean auraSessionReady;        // headless Aura session bootstrapped (dynamic-content personalization leg)
        @InvocableVariable(label='Email Workspace Count')
        public Integer emailWorkspaceCount;     // # of Enhanced + Marketing CMS workspaces visible
        @InvocableVariable(label='Workspaces JSON')
        public String workspacesJson;           // [{id,name,apiName}] of the email-capable spaces
        @InvocableVariable(label='Recommended Workspace Id')
        public String recommendedWorkspaceId;   // Default_Content_Workspace else first-by-name; '' if none
        @InvocableVariable(label='Diagnostic')
        public String diagnostic;               // human-readable result + next step to fix
    }

    // Same seam the real actions use, so this checks exactly the auth path they depend on.
    @TestVisible
    static AuraPocTokenSource tokenSource = new AuraPocTokenProvider();

    @TestVisible
    static HttpResponse spacesCall(String accessToken) {
        HttpRequest req = new HttpRequest();
        req.setMethod('GET');
        req.setEndpoint(AuraPocTokenProvider.instanceUrl() + '/services/data/v66.0/connect/cms/spaces');
        req.setHeader('Authorization', 'Bearer ' + accessToken);
        req.setTimeout(30000);
        return new Http().send(req);
    }

    // Map a JWT-mint failure to the specific External Client App / cert / run-as setup step that is
    // almost certainly missing -- these are the manual, per-org steps from the install runbook, in
    // the order they most commonly bite a fresh org.
    @TestVisible
    static String mapMintError(String rawMsg) {
        String m = (rawMsg == null ? '' : rawMsg).toLowerCase();
        if (m.contains('refresh_token') || m.contains('offline_access')) {
            return 'JWT auth failed: the External Client App is missing the refresh_token '
                + '(offline_access) scope. JWT Bearer flow is rejected without it even though it '
                + 'never uses a refresh token. Fix: Setup > External Client App Manager > '
                + 'AuraPoc_JwtApp > OAuth Settings > add "Perform requests at any time '
                + '(refresh_token, offline_access)" to the scopes. This is the most common cause.';
        }
        if (m.contains('invalid_grant') || m.contains('not pre-authorized') || m.contains('user hasn')
                || m.contains('approv')) {
            return 'JWT auth failed: the run-as user is not pre-authorized for the External Client '
                + 'App. Fix: AuraPoc_JwtApp > Policies > OAuth Policies > set Permitted Users = '
                + '"Admin approved users are pre-authorized", then assign the app\'s permission set '
                + 'to the run-as user.';
        }
        if (m.contains('invalid_client') || m.contains('client identifier') || m.contains('cert')
                || m.contains('signature')) {
            return 'JWT auth failed: the External Client App or its JWT certificate is not set up. '
                + 'Fix: on AuraPoc_JwtApp enable OAuth + "JWT Bearer flow", and select the '
                + 'AuraPoc_JwtCert certificate (do not upload a new one).';
        }
        return 'JWT auth failed to mint a token'
            + (String.isBlank(rawMsg) ? '' : (': ' + rawMsg))
            + '. Verify AuraPoc_JwtApp: OAuth enabled, JWT Bearer flow enabled, AuraPoc_JwtCert '
            + 'selected, scopes = api + a Data Cloud scope + refresh_token, and the run-as user '
            + 'pre-authorized (see the install runbook, Steps 2-3).';
    }

    // Read-only probe of the headless Aura-session leg the personalization wiring depends on
    // (BuildDynamicEmailAction.wirePersonalizations -> AuraSessionMinter.mint -> AuraServiceClient).
    // mint() only loads the /cmsAuthor/contentEditor.app bootstrap to parse fwuid/app -- it creates
    // nothing. Returns true only if a usable session (non-blank fwuid + app) comes back, which is the
    // exact precondition the wiring needs; anything less means dynamic content will not wire even
    // though the REST leg is green. Throws on transport/CSP failures, which the caller maps.
    @TestVisible
    static Boolean probeAuraSession(String accessToken) {
        AuraSessionMinter.Session sess = AuraSessionMinter.mint(accessToken, AuraPocTokenProvider.instanceUrl());
        // A usable headless session = a parsed fwuid AND a real aura token (the two things the
        // AuraServiceClient calls actually need). NOTE: AuraSessionMinter.Session exposes
        // instancePrefix/lightningHost/auraToken/fwuid -- there is no appName field (confirmed
        // against the org), so we verify fwuid + auraToken, not fwuid + app.
        return sess != null && String.isNotBlank(sess.fwuid) && String.isNotBlank(sess.auraToken);
    }

    // Map an Aura-session probe failure to its likely cause. Distinct from mapMintError: by the time
    // this runs the JWT token already minted, so the failure is NOT about the External Client App --
    // it is about reaching/parsing the Aura app bootstrap (CSP/Remote Site, My Domain, or a platform
    // release that changed the bootstrap shape so AuraSessionMinter needs updating).
    @TestVisible
    static String mapAuraError(String rawMsg) {
        String m = (rawMsg == null ? '' : rawMsg).toLowerCase();
        if (m.contains('csp') || m.contains('content security') || m.contains('refused')
                || m.contains('unauthorized endpoint') || m.contains('remote site')) {
            return 'the Aura bootstrap host is blocked -- add this org\'s *.lightning.force.com host '
                + 'to Setup > Remote Site Settings (and CSP Trusted Sites if used).';
        }
        if (m.contains('fwuid') || m.contains('parse') || m.contains('bootstrap')
                || m.contains('unexpected') || m.contains('no match')) {
            return 'could not parse the Aura app bootstrap (fwuid/app). This usually means a platform '
                + 'release changed the /cmsAuthor/contentEditor.app bootstrap shape -- AuraSessionMinter '
                + 'needs updating to match the current release.';
        }
        if (String.isBlank(rawMsg)) {
            return 'the headless Aura session returned no usable fwuid/app. Check My Domain is reachable '
                + 'and *.lightning.force.com is in Remote Site Settings.';
        }
        return 'Aura session bootstrap error: ' + rawMsg + ' -- verify My Domain + Remote Site Settings '
            + 'for *.lightning.force.com, and that AuraSessionMinter still matches the current bootstrap.';
    }

    @InvocableMethod(label='Test Connection' description='Diagnoses the agent\'s JWT self-auth, CMS workspace availability, AND the headless Aura-session leg that dynamic-content personalization needs, for THIS org. Attempts to mint a token (never returns it), lists email-capable Marketing CMS workspaces, and bootstraps a read-only Aura session. Returns pass/fail plus the exact setup step to fix on failure. Read-only; creates nothing.')
    public static List<Result> run(List<Request> requests) {
        List<Result> results = new List<Result>();
        Integer n = requests == null || requests.isEmpty() ? 1 : requests.size();
        for (Integer i = 0; i < n; i++) {
            Result res = new Result();
            res.success = false;
            res.tokenMinted = false;
            res.auraSessionReady = false;
            res.emailWorkspaceCount = 0;
            res.workspacesJson = '[]';
            res.recommendedWorkspaceId = '';
            res.diagnostic = '';

            String token;
            try {
                token = tokenSource.getAccessToken();
            } catch (Exception e) {
                res.diagnostic = mapMintError(e.getMessage());
                results.add(res);
                continue;
            }
            if (String.isBlank(token)) {
                res.diagnostic = mapMintError('');
                results.add(res);
                continue;
            }
            res.tokenMinted = true;

            // Probe the Aura leg once, up front, so its verdict can be appended to whatever the REST
            // leg reports below. Independent of the REST result: the two legs can fail separately.
            String auraSuffix;
            try {
                res.auraSessionReady = probeAuraSession(token);
                auraSuffix = res.auraSessionReady
                    ? ' | Aura session (dynamic-content personalization): OK.'
                    : ' | Aura session (dynamic-content personalization): NOT ready -- static email '
                        + 'builds will work, but wiring dynamic content will not: ' + mapAuraError(null);
            } catch (Exception ae) {
                res.auraSessionReady = false;
                auraSuffix = ' | Aura session (dynamic-content personalization): FAILED -- static email '
                    + 'builds will work, but wiring dynamic content will not: ' + mapAuraError(ae.getMessage());
            }

            try {
                HttpResponse r = spacesCall(token);
                if (r.getStatusCode() != 200) {
                    res.diagnostic = 'JWT token minted OK, but the CMS /connect/cms/spaces call '
                        + 'returned HTTP ' + r.getStatusCode() + '. The External Client App likely '
                        + 'lacks a Data Cloud / API scope, or the run-as user lacks CMS access. '
                        + 'Add the "api" + a Data Cloud scope to AuraPoc_JwtApp and ensure the '
                        + 'run-as user can access CMS.' + auraSuffix;
                    results.add(res);
                    continue;
                }
                Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(r.getBody());
                List<Object> spaces = body.get('spaces') instanceof List<Object>
                    ? (List<Object>) body.get('spaces') : new List<Object>();
                List<Object> emailCapable = new List<Object>();
                List<String> names = new List<String>();
                // Recommendation mirrors ResolveBrandingAction.resolveEmailCapableWorkspaceId: prefer
                // Default_Content_Workspace, else the first space by name (deterministic) -- so the
                // agent's auto-recovery pins the SAME workspace normal resolution would have chosen.
                String defaultId = '';
                String firstId = '';
                String firstName = null;
                for (Object o : spaces) {
                    if (!(o instanceof Map<String, Object>)) { continue; }
                    Map<String, Object> sp = (Map<String, Object>) o;
                    Boolean enhanced = sp.get('isEnhancedSpace') == true;
                    Map<String, Object> st = sp.get('spaceType') instanceof Map<String, Object>
                        ? (Map<String, Object>) sp.get('spaceType') : null;
                    String typeApi = st == null ? '' : String.valueOf(st.get('apiName'));
                    if (!enhanced || typeApi != 'marketing') { continue; }
                    String nm = String.valueOf(sp.get('name'));
                    String id = String.valueOf(sp.get('id'));
                    emailCapable.add(new Map<String, Object>{
                        'id' => sp.get('id'), 'name' => nm, 'apiName' => sp.get('apiName')
                    });
                    names.add(nm);
                    if (String.valueOf(sp.get('apiName')) == 'Default_Content_Workspace') { defaultId = id; }
                    if (firstName == null || nm < firstName) { firstName = nm; firstId = id; }
                }
                res.emailWorkspaceCount = emailCapable.size();
                res.workspacesJson = JSON.serialize(emailCapable);
                res.recommendedWorkspaceId = String.isNotBlank(defaultId) ? defaultId : firstId;
                if (emailCapable.isEmpty()) {
                    res.diagnostic = 'Auth is working (token minted, CMS reachable), but this org has '
                        + 'NO email-capable CMS workspace (no Enhanced space of type "marketing"). '
                        + 'Create/enable a Marketing CMS workspace before building emails.' + auraSuffix;
                } else {
                    res.success = true;
                    res.diagnostic = 'Auth is working and this org has ' + emailCapable.size()
                        + ' email-capable Marketing CMS workspace(s): ' + String.join(names, ', ')
                        + '. The agent auto-selects one; to override, set the workspace id on the '
                        + 'AuraPoc_Config__mdt record in Setup.' + auraSuffix;
                }
            } catch (Exception e) {
                res.diagnostic = 'JWT token minted OK, but the CMS spaces callout failed: '
                    + e.getMessage() + ' -- check that this org\'s My Domain is reachable and, if '
                    + 'the endpoint is a *.file.force.com / *.lightning.force.com host, that it is in '
                    + 'Remote Site Settings.' + auraSuffix;
            }
            results.add(res);
        }
        return results;
    }
}
