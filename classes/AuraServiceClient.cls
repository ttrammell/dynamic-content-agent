/**
 * Calls a Lightning Aura Controller action using a session minted by
 * AuraSessionMinter. Ports the request-shaping and response-unwrapping from
 * this toolkit's scripts/aura_client.py AuraClient.call()/call_action().
 *
 * This is a private, unsupported RPC surface (see AuraSessionMinter's class
 * comment and the project's own "REST first, Aura only when there is no
 * supported endpoint" rule) -- treat any use of this class as a stopgap for
 * a specific controller action with no Tooling/Metadata/Connect API
 * equivalent, not a general integration pattern.
 */
public class AuraServiceClient {

    public class AuraCallException extends Exception {}

    public enum CallState { SUCCESS, ERROR, SESSION_DEAD, HTTP_ERROR }

    public class CallResult {
        public CallState state;
        public Object returnValue;
        public String rawError;
        public Integer httpStatus;
    }

    private static final Set<String> DEAD_SESSION_MARKERS = new Set<String>{
        'invalidsession', 'invalid session', 'csrf', 'invalid_csrf',
        'session has expired', 'session expired', 'invalid token',
        'invalid_token', 'invalid aura token', 'token is invalid', 'expired token'
    };

    private static Boolean looksLikeDeadSession(String text) {
        if (text == null) {
            return false;
        }
        String low = text.toLowerCase();
        for (String marker : DEAD_SESSION_MARKERS) {
            if (low.contains(marker)) {
                return true;
            }
        }
        return false;
    }

    private static String stripAuraWrapper(String raw) {
        String text = raw.trim();
        if (text.startsWith('*/')) {
            text = text.substring(2);
        }
        if (text.endsWith('/*ERROR*/')) {
            text = text.substring(0, text.length() - 9);
        } else if (text.endsWith('/*')) {
            text = text.substring(0, text.length() - 2);
        }
        return text;
    }

    /**
     * Invokes controller.action with params against the session's Lightning
     * host. auraContextJson must be a full aura.context blob (mode/fwuid/app/
     * loaded/dn/globals/uad) -- build it from the session's fwuid/app/loaded
     * plus whatever globals the target controller's app needs, mirroring
     * scripts/aura_client.py's APP_CONTEXTS/_aura_context.
     *
     * On SESSION_DEAD, callers should re-mint via AuraSessionMinter.mint()
     * and retry once -- this method does not auto-retry, so a caller can
     * decide whether re-minting mid-transaction is worth the callout budget.
     */
    public static CallResult callAction(
        AuraSessionMinter.Session sess,
        String descriptor,
        String urlActionHint,
        String auraContextJson,
        String pageUri,
        Integer requestCounter,
        Map<String, Object> params
    ) {
        CallResult result = new CallResult();

        Map<String, Object> action = new Map<String, Object>{
            'id' => requestCounter + ';a',
            'descriptor' => descriptor,
            'callingDescriptor' => 'UNKNOWN',
            'params' => params
        };
        String message = JSON.serialize(new Map<String, Object>{
            'actions' => new List<Object>{ action }
        });

        Map<String, String> form = new Map<String, String>{
            'message' => message,
            'aura.context' => auraContextJson,
            'aura.pageURI' => pageUri,
            'aura.token' => sess.auraToken
        };

        List<String> encodedPairs = new List<String>();
        for (String k : form.keySet()) {
            encodedPairs.add(EncodingUtil.urlEncode(k, 'UTF-8') + '=' + EncodingUtil.urlEncode(form.get(k), 'UTF-8'));
        }
        String body = String.join(encodedPairs, '&');

        String endpoint = 'https://' + sess.lightningHost + '/aura?r=' + requestCounter + '&' + urlActionHint + '=1';

        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/x-www-form-urlencoded;charset=UTF-8');
        req.setHeader('Cookie', AuraSessionMinter.cookieHeaderFor(sess, sess.lightningHost));
        req.setBody(body);
        req.setTimeout(30000);

        HttpResponse resp;
        try {
            resp = new Http().send(req);
        } catch (Exception e) {
            result.state = CallState.HTTP_ERROR;
            result.rawError = e.getMessage();
            return result;
        }

        AuraSessionMinter.applySetCookie(sess, sess.lightningHost, resp.getHeader('Set-Cookie'));
        result.httpStatus = resp.getStatusCode();

        if (resp.getStatusCode() == 401 || resp.getStatusCode() == 403) {
            result.state = CallState.SESSION_DEAD;
            result.rawError = resp.getBody();
            return result;
        }

        Map<String, Object> parsed;
        try {
            parsed = (Map<String, Object>) JSON.deserializeUntyped(stripAuraWrapper(resp.getBody()));
        } catch (Exception e) {
            result.state = CallState.HTTP_ERROR;
            result.rawError = 'Could not parse Aura response: ' + e.getMessage();
            return result;
        }

        if (parsed.containsKey('exceptionEvent')) {
            String msg = String.valueOf(parsed.get('exceptionMessage'));
            result.rawError = msg;
            result.state = looksLikeDeadSession(msg) ? CallState.SESSION_DEAD : CallState.ERROR;
            return result;
        }

        List<Object> actions = (List<Object>) parsed.get('actions');
        if (actions == null || actions.isEmpty()) {
            result.state = CallState.ERROR;
            result.rawError = 'No actions in Aura response: ' + resp.getBody().abbreviate(500);
            return result;
        }

        Map<String, Object> firstAction = (Map<String, Object>) actions[0];
        String actionState = String.valueOf(firstAction.get('state'));
        if (actionState == 'SUCCESS') {
            result.state = CallState.SUCCESS;
            result.returnValue = firstAction.get('returnValue');
        } else {
            String errText = JSON.serialize(firstAction.get('error'));
            result.rawError = errText;
            result.state = looksLikeDeadSession(errText) ? CallState.SESSION_DEAD : CallState.ERROR;
        }
        return result;
    }
}