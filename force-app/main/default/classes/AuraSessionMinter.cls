/**
 * Mints a live Aura Controller session (cookie jar + framework CSRF token)
 * from a plain OAuth access token, entirely via Apex HTTP callouts.
 *
 * Ports the mechanism proven in this toolkit's scripts/aura_client.py
 * mint_session() to Apex. Two platform differences from that Python client
 * that must be handled by hand here (Apex's Http class has no cookie jar):
 *   1. A single response can set many cookies; HttpResponse.getHeader
 *      ('Set-Cookie') returns them concatenated into one ";"-joined string
 *      with no per-cookie delimiter, so name=value pairs must be told apart
 *      from attributes (path=, expires=, domain=, secure, httponly, samesite).
 *   2. Cookies are scoped per host (my.salesforce.com / file.force.com /
 *      lightning.force.com each set their OWN "sid", among others) -- they
 *      must be tracked per host and never merged into a single flat map, or
 *      one host's session id silently clobbers another's and the chain
 *      dead-ends on the login page instead of the authenticated app.
 *
 * The chain itself has two stages once past the initial frontdoor.jsp GET:
 *   - A same-page JS bridge (`location.replace("...")` in the response body,
 *     not an HTTP redirect) from my.salesforce.com to file.force.com and back.
 *   - A real HTTP 302 chain from my.salesforce.com through lightning.force.com
 *     and a visualforce/session + visualforce/recsession round trip, ending on
 *     the authenticated lightning.force.com host. Apex does NOT auto-follow
 *     3xx responses (verified: a raw 302 to an unrelated host comes back with
 *     the Location header intact and no exception) -- each hop is followed
 *     explicitly here.
 */
public class AuraSessionMinter {

    public class MintException extends Exception {}

    public class Session {
        public String instancePrefix;   // e.g. "yourdomain"
        public String lightningHost;    // e.g. "yourdomain.lightning.force.com"
        public String auraToken;        // the __Host-ERIC_PROD... JWT cookie value
        public String fwuid;
        public Map<String, String> loaded;   // e.g. {"APPLICATION@markup://one:one" => "..."}
        public String appName;               // e.g. "one:one"
        private Map<String, String> cookieJar = new Map<String, String>(); // key: host+SEP+name
    }

    private static final String SEP = '';
    private static final Integer MAX_HOPS = 10;
    private static final Set<String> COOKIE_ATTR_KEYS = new Set<String>{
        'path', 'expires', 'max-age', 'domain', 'secure', 'httponly', 'samesite'
    };

    private static String jarKey(String host, String name) {
        return host + SEP + name;
    }

    private static void mergeSetCookie(Map<String, String> jar, String host, String setCookieRaw) {
        if (setCookieRaw == null) {
            return;
        }
        for (String part : setCookieRaw.split(';')) {
            part = part.trim();
            Integer eq = part.indexOf('=');
            if (part == '' || eq < 1) {
                continue;
            }
            String key = part.substring(0, eq).trim();
            if (COOKIE_ATTR_KEYS.contains(key.toLowerCase())) {
                continue;
            }
            jar.put(jarKey(host, key), part.substring(eq + 1).trim());
        }
    }

    private static String cookieHeaderForHost(Map<String, String> jar, String host) {
        List<String> pairs = new List<String>();
        String prefix = host + SEP;
        for (String k : jar.keySet()) {
            if (k.startsWith(prefix)) {
                pairs.add(k.substring(prefix.length()) + '=' + jar.get(k));
            }
        }
        return String.join(pairs, '; ');
    }

    // Fingerprint of the framework CSRF token, matching mint_session()'s
    // _jwt_is_aura_token: a JWT whose header carries a "nonce" claim and
    // whose kid names the "caimansigner" issuer. Other long JWT-shaped
    // cookies on the session lack the nonce and are not the aura.token.
    private static Boolean isAuraTokenJwt(String value) {
        if (value == null || !value.startsWith('eyJ')) {
            return false;
        }
        try {
            String seg = value.split('\\.')[0].replace('-', '+').replace('_', '/');
            while (Math.mod(seg.length(), 4) != 0) {
                seg += '=';
            }
            String header = EncodingUtil.base64Decode(seg).toString();
            return header.contains('"nonce"') && header.contains('caimansigner');
        } catch (Exception e) {
            return false;
        }
    }

    private static String followJsRedirect(String body) {
        Matcher m = Pattern.compile('location\\.replace\\(["\']([^"\']+)["\']\\)').matcher(body);
        return m.find() ? m.group(1).replace('&amp;', '&') : null;
    }

    private static HttpResponse get(String url, Map<String, String> jar, String host) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(url);
        req.setMethod('GET');
        req.setHeader('User-Agent', 'Mozilla/5.0 (AuraSessionMinter)');
        String cookieHeader = cookieHeaderForHost(jar, host);
        if (cookieHeader != '') {
            req.setHeader('Cookie', cookieHeader);
        }
        req.setTimeout(30000);
        return new Http().send(req);
    }

    /**
     * Mints a session against instanceUrl using accessToken (the value
     * `sf org display --json` yields via .result.accessToken).
     * Throws MintException if frontdoor.jsp is disabled on the org (Shield /
     * strict-session orgs), or if no aura.token cookie is found on the final
     * lightning.force.com landing page.
     */
    public static Session mint(String accessToken, String instanceUrl) {
        String prefix = instanceUrl.removeEnd('/').replaceAll('^https?://', '').split('\\.')[0];
        String lightningHost = prefix + '.lightning.force.com';

        String url = instanceUrl.removeEnd('/') + '/secur/frontdoor.jsp?sid='
            + EncodingUtil.urlEncode(accessToken, 'UTF-8') + '&retURL=%2Flightning%2Fpage%2Fhome';
        Map<String, String> jar = new Map<String, String>();
        String lastBody = null;
        String lastHost = null;

        for (Integer hop = 0; hop < MAX_HOPS; hop++) {
            String host = new URL(url).getHost();
            HttpResponse resp = get(url, jar, host);
            mergeSetCookie(jar, host, resp.getHeader('Set-Cookie'));

            String body = resp.getBody();
            lastBody = body;
            lastHost = host;

            String nextUrl = followJsRedirect(body);
            if (nextUrl == null) {
                nextUrl = resp.getHeader('Location');
            }
            if (nextUrl == null) {
                break;
            }
            url = nextUrl.startsWith('http') ? nextUrl : ('https://' + host + nextUrl);
        }

        if (lastHost != lightningHost) {
            throw new MintException('frontdoor did not land an authenticated session on '
                + lightningHost + ' (landed on ' + lastHost + ' instead) -- '
                + 'frontdoor.jsp may be disabled on this org.');
        }

        Session sess = new Session();
        sess.instancePrefix = prefix;
        sess.lightningHost = lightningHost;
        sess.cookieJar = jar;

        for (String k : jar.keySet()) {
            if (k.startsWith(lightningHost + SEP) && isAuraTokenJwt(jar.get(k))) {
                sess.auraToken = jar.get(k);
            }
        }
        if (sess.auraToken == null) {
            throw new MintException('no aura.token cookie found on ' + lightningHost
                + ' after mint (framework token cookie absent).');
        }

        // Harvest fwuid + loaded markup id from the /l/<urlenc-context>/inline.js
        // reference on the authenticated home page -- fresher than any hardcoded
        // constant, so this self-heals across release-driven fwuid drift.
        Matcher m = Pattern.compile('/l/([^/]+)/inline\\.js').matcher(lastBody);
        if (m.find()) {
            try {
                Map<String, Object> ctx = (Map<String, Object>) JSON.deserializeUntyped(
                    EncodingUtil.urlDecode(m.group(1), 'UTF-8'));
                sess.fwuid = (String) ctx.get('fwuid');
                sess.appName = (String) ctx.get('app');
                Object loadedObj = ctx.get('loaded');
                if (loadedObj instanceof Map<String, Object>) {
                    sess.loaded = new Map<String, String>();
                    for (String lk : ((Map<String, Object>) loadedObj).keySet()) {
                        sess.loaded.put(lk, String.valueOf(((Map<String, Object>) loadedObj).get(lk)));
                    }
                }
            } catch (Exception e) {
                // fwuid/loaded are best-effort self-heal; AuraServiceClient callers
                // can still supply their own if this extraction fails.
            }
        }

        return sess;
    }

    // Exposed so AuraServiceClient can rotate the sfdc-aura cookie in place
    // after each controller call, and callers can inspect the live jar.
    public static String cookieHeaderFor(Session sess, String host) {
        return cookieHeaderForHost(sess.cookieJar, host);
    }

    public static void applySetCookie(Session sess, String host, String setCookieRaw) {
        mergeSetCookie(sess.cookieJar, host, setCookieRaw);
    }
}