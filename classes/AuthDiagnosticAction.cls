// Self-check for the agent's JWT self-auth + CMS workspace availability, so a fresh install can be
// troubleshooted from inside the conversation instead of failing cryptically at build time. It
// attempts to mint a token (via the same AuraPocTokenProvider the real actions use), and on success
// does one read-only /connect/cms/spaces call to confirm end-to-end and list the email-capable
// (Enhanced + Marketing) workspaces. NEVER returns the token itself -- only pass/fail + actionable
// guidance mapped from the failure. Creates nothing; the only callouts are read-only.
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
        @InvocableVariable(label='Email Workspace Count')
        public Integer emailWorkspaceCount;     // # of Enhanced + Marketing CMS workspaces visible
        @InvocableVariable(label='Workspaces JSON')
        public String workspacesJson;           // [{id,name,apiName}] of the email-capable spaces
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

    @InvocableMethod(label='Test Connection' description='Diagnoses the agent\'s JWT self-auth and CMS workspace availability for THIS org. Attempts to mint a token (never returns it), then lists email-capable Marketing CMS workspaces. Returns pass/fail plus the exact setup step to fix on failure. Read-only; creates nothing.')
    public static List<Result> run(List<Request> requests) {
        List<Result> results = new List<Result>();
        Integer n = requests == null || requests.isEmpty() ? 1 : requests.size();
        for (Integer i = 0; i < n; i++) {
            Result res = new Result();
            res.success = false;
            res.tokenMinted = false;
            res.emailWorkspaceCount = 0;
            res.workspacesJson = '[]';
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

            try {
                HttpResponse r = spacesCall(token);
                if (r.getStatusCode() != 200) {
                    res.diagnostic = 'JWT token minted OK, but the CMS /connect/cms/spaces call '
                        + 'returned HTTP ' + r.getStatusCode() + '. The External Client App likely '
                        + 'lacks a Data Cloud / API scope, or the run-as user lacks CMS access. '
                        + 'Add the "api" + a Data Cloud scope to AuraPoc_JwtApp and ensure the '
                        + 'run-as user can access CMS.';
                    results.add(res);
                    continue;
                }
                Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(r.getBody());
                List<Object> spaces = body.get('spaces') instanceof List<Object>
                    ? (List<Object>) body.get('spaces') : new List<Object>();
                List<Object> emailCapable = new List<Object>();
                List<String> names = new List<String>();
                for (Object o : spaces) {
                    if (!(o instanceof Map<String, Object>)) { continue; }
                    Map<String, Object> sp = (Map<String, Object>) o;
                    Boolean enhanced = sp.get('isEnhancedSpace') == true;
                    Map<String, Object> st = sp.get('spaceType') instanceof Map<String, Object>
                        ? (Map<String, Object>) sp.get('spaceType') : null;
                    String typeApi = st == null ? '' : String.valueOf(st.get('apiName'));
                    if (!enhanced || typeApi != 'marketing') { continue; }
                    String nm = String.valueOf(sp.get('name'));
                    emailCapable.add(new Map<String, Object>{
                        'id' => sp.get('id'), 'name' => nm, 'apiName' => sp.get('apiName')
                    });
                    names.add(nm);
                }
                res.emailWorkspaceCount = emailCapable.size();
                res.workspacesJson = JSON.serialize(emailCapable);
                if (emailCapable.isEmpty()) {
                    res.diagnostic = 'Auth is working (token minted, CMS reachable), but this org has '
                        + 'NO email-capable CMS workspace (no Enhanced space of type "marketing"). '
                        + 'Create/enable a Marketing CMS workspace before building emails.';
                } else {
                    res.success = true;
                    res.diagnostic = 'Auth is working and this org has ' + emailCapable.size()
                        + ' email-capable Marketing CMS workspace(s): ' + String.join(names, ', ')
                        + '. The agent auto-selects one; to pin a specific one, provide its id and I '
                        + 'will use it as an override.';
                }
            } catch (Exception e) {
                res.diagnostic = 'JWT token minted OK, but the CMS spaces callout failed: '
                    + e.getMessage() + ' -- check that this org\'s My Domain is reachable and, if '
                    + 'the endpoint is a *.file.force.com / *.lightning.force.com host, that it is in '
                    + 'Remote Site Settings.';
            }
            results.add(res);
        }
        return results;
    }
}
