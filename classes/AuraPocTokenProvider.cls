public with sharing class AuraPocTokenProvider implements AuraPocTokenSource {

    public class TokenException extends Exception {}

    // Org-specific auth values live in AuraPoc_Config__mdt ("Default" record) instead of
    // being hardcoded here, so this package can be installed into a new org by adding one
    // custom metadata record instead of editing Apex.
    private static AuraPoc_Config__mdt configRecord;

    private static AuraPoc_Config__mdt config() {
        if (configRecord == null) {
            configRecord = AuraPoc_Config__mdt.getInstance('Default');
            if (configRecord == null) {
                throw new TokenException('No AuraPoc_Config__mdt record named "Default" found. '
                    + 'Create one with ConsumerKey__c, CertDevName__c, RunAsUser__c, and InstanceUrl__c '
                    + 'populated for this org.');
            }
        }
        return configRecord;
    }

    // Instance method so actions can depend on the AuraPocTokenSource interface
    // and swap in a fake in tests -- Auth.JWTBearerTokenExchange is a "Web
    // service callout" and does NOT support Test.setMock(HttpCalloutMock.class, ...).
    public String getAccessToken() {
        return fetch();
    }

    public static String fetch() {
        AuraPoc_Config__mdt cfg = config();

        Auth.JWT jwt = new Auth.JWT();
        jwt.setSub(cfg.RunAsUser__c);
        jwt.setAud(cfg.InstanceUrl__c);
        jwt.setIss(cfg.ConsumerKey__c);

        Auth.JWS jws = new Auth.JWS(jwt, cfg.CertDevName__c);
        Auth.JWTBearerTokenExchange bearer = new Auth.JWTBearerTokenExchange(
            cfg.InstanceUrl__c + '/services/oauth2/token', jws);

        try {
            return bearer.getAccessToken();
        } catch (Exception e) {
            throw new TokenException('Unable to fetch access token: ' + e.getMessage(), e);
        }
    }

    public static String instanceUrl() {
        return config().InstanceUrl__c;
    }
}