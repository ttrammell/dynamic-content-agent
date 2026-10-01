// Consolidates CreateEmailTemplateAction + WireDynamicContentVariantAction into one
// atomic agent action. Rationale (from live evidence, not theory): running these as two
// separate agent-invoked actions let a real run create a base email successfully and then
// fail on personalization, leaving a half-built, unpersonalized email orphaned in the org.
// Targets are addressed by the caller-chosen element "key" from elementsJson, not raw CMS
// block ids -- the agent never needs to see or round-trip a block UUID between calls.
// If personalization is requested but fails after the email was created, this action
// deletes the just-created content so the net effect is "nothing persisted" rather than
// a silently broken partial result.
public with sharing class BuildDynamicEmailAction {

    public class Request {
        @InvocableVariable(label='Content Space or Folder Id' required=true)
        public String contentSpaceOrFolderId;

        @InvocableVariable(label='Title' required=true)
        public String title;

        @InvocableVariable(label='URL Name' required=true)
        public String urlName;

        @InvocableVariable(label='Subject Line' required=true)
        public String subjectLine;

        @InvocableVariable(label='Preheader' required=true)
        public String preheader;

        // JSON array of content elements, e.g.:
        // [
        //   {"key":"greeting_heading","type":"heading","text":"Welcome"},
        //   {"key":"greeting_paragraph","type":"paragraph","text":"Some body copy."},
        //   {"key":"hero_image","type":"image","contentKey":"MC...","altText":"...","widthPercent":60},
        //   {"key":"cta","type":"button","text":"Learn More","url":"https://example.com"}
        // ]
        @InvocableVariable(label='Elements JSON' required=true)
        public String elementsJson;

        // The org's brand-asset catalog (the SAME list surfaced to the plan as BrandContext):
        // a JSON array of {name, urlName, contentKey, ...}. Used to resolve an image element that
        // references an asset by NAME (assetName) or ROLE (assetRole) into a real contentKey,
        // deterministically in Apex -- so the LLM never has to transcribe an MC-key (which it can
        // corrupt by a character). Optional: elements that already carry a literal contentKey, or
        // that use logo/header roles (resolved from the override keys), don't need it.
        @InvocableVariable(label='Assets JSON')
        public String assetsJson;

        @InvocableVariable(label='Include Default Branding')
        public Boolean includeBranding;

        // Override the org-wide default logo/header (AuraPoc_Config__mdt.Default) with a
        // specific brand's assets for this call only -- e.g. a contentKey found via
        // FindBrandAssetsAction. Omit to use the org default for either or both.
        @InvocableVariable(label='Logo Content Key Override')
        public String logoContentKeyOverride;

        @InvocableVariable(label='Header Content Key Override')
        public String headerContentKeyOverride;

        // Explicitly omit the logo/header from the banner -- distinct from simply omitting the
        // override above, which falls back to the org's AuraPoc_Config__mdt default. Set true
        // when the caller searched for a brand/default asset and genuinely found none, so
        // nothing renders rather than silently substituting an unrelated org-default image.
        @InvocableVariable(label='Suppress Logo')
        public Boolean suppressLogo;

        @InvocableVariable(label='Suppress Header')
        public Boolean suppressHeader;

        // contentKey of a sfdc_cms__brand ManagedContent record (from FindBrandRecordAction)
        // -- attaches that brand's colorScheme/typography/button styling via
        // lightning:brandSource. Distinct from logo/header, which only swap pictures;
        // without this the email still renders with generic default styling. Omit to use
        // the org's default brand.
        @InvocableVariable(label='Brand Content Key Override')
        public String brandContentKeyOverride;

        // --- Optional personalization. Omit personalizationsJson to build a plain,
        // unpersonalized email in one call. Provide it to build AND wire in one shot. ---

        // JSON array of PersonalizationPoint specs, ONE PER INDEPENDENT AXIS -- Salesforce
        // evaluates decisions within one PersonalizationPoint as mutually-exclusive alternatives,
        // not independently-combinable facts, so unrelated axes (e.g. industry AND has-first-name)
        // must NOT share a PP. Each entry:
        // {"ppName":"Industry_Personalization","ppLabel":"Industry Personalization",
        //  "decisionsJson":"[{\"name\":\"Has_First_Name_v1\",\"label\":\"Has First Name\",
        //    \"criteriaFieldApiName\":\"ssot__FirstName__c\"}]",
        //  "targetsJson":"[{\"elementKey\":\"greeting_heading\",\"blockDefinition\":\"lightning/heading\",
        //    \"textByDecision\":{\"Has_First_Name_v1\":\"Hi there!\"}}]"}
        // decisionsJson supports optional criteriaType ("has_value" default | "equals" | "in") +
        // value/values, and criteriaObjectApiName/criteriaPath for related-object fields (one of
        // ACCOUNT_PATH, CONTACT_POINT_ADDRESS_PATH, INDIVIDUAL_PATH, EMAIL_ENGAGEMENT_PATH,
        // LEAD_PATH). State/Province values must be 2-letter codes. targetsJson entries reference
        // an elementsJson "key" (NOT a raw block id); if blockDefinition is "lightning/image", each
        // textByDecision value must be an object {"contentKey":"...","altText":"...","widthPercent":N},
        // not plain text. At most 3 entries (PersonalizationPoints) per email, at most 10 decisions
        // per entry -- matches the marketing toolkit's own silent install caps.
        @InvocableVariable(label='Personalizations JSON')
        public String personalizationsJson;

        @InvocableVariable(label='Data Space Name')
        public String dataSpaceName;

        @InvocableVariable(label='Data Graph Name')
        public String profileDataGraphName;

        // Display-only inputs -- surfaced on the require_user_confirmation dialog for the
        // user's final review; NOT used by the build logic (intentionally ignored).
        @InvocableVariable(label='Personalization')
        public String personalizationSummary;

        @InvocableVariable(label='Validation')
        public String validationSummary;

        @InvocableVariable(label='Branding')
        public String brandingSummary;
    }

    public class Result {
        @InvocableVariable(label='Success')
        public Boolean success;

        @InvocableVariable(label='Content Key')
        public String contentKey;

        @InvocableVariable(label='Managed Content Id')
        public String managedContentId;

        // Deep link to the CMS workspace where the email now lives (lands on the content list; the
        // per-item route 404s). Built in Apex from the instance URL (domain -> lightning.force.com)
        // + the workspace id, so the agent relays a real link instead of fabricating one.
        @InvocableVariable(label='Content URL')
        public String contentUrl;

        @InvocableVariable(label='Block Ids JSON')
        public String blockIdsJson;

        @InvocableVariable(label='Personalized')
        public Boolean personalized;

        // JSON array of the PersonalizationPoint names actually created (one per independent
        // axis), e.g. ["Industry_Personalization_a1b2c3","Has_First_Name_Personalization_d4e5f6"].
        @InvocableVariable(label='Personalization Point Name')
        public String ppName;

        @InvocableVariable(label='Variant Ids JSON')
        public String variantIdsJson;

        @InvocableVariable(label='Rolled Back')
        public Boolean rolledBack;

        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    public class ElementException extends Exception {}
    public class WireException extends Exception {}

    // Raised from 3 (the marketing toolkit's own silent install cap) after live scale-testing
    // showed the real per-PP cost is ~1 callout / ~15-30ms CPU -- nowhere near the platform's
    // actual ceilings (100 callouts, 10000ms CPU per transaction). 20 is a generous sanity rail
    // against a truly runaway request, not a technical necessity -- see scale test results.
    public static final Integer MAX_PPS_PER_EMAIL = 20;
    public static final Integer MAX_DECISIONS_PER_PP = 10;

    @TestVisible
    static AuraPocTokenSource tokenSource = new AuraPocTokenProvider();

    // Default branding assets live in AuraPoc_Config__mdt ("Default" record) instead of being
    // hardcoded here -- those contentKeys are only valid in the org they were authored in.
    private static AuraPoc_Config__mdt configRecord;

    private static AuraPoc_Config__mdt config() {
        if (configRecord == null) {
            configRecord = AuraPoc_Config__mdt.getInstance('Default');
            if (configRecord == null) {
                throw new ElementException('No AuraPoc_Config__mdt record named "Default" found. '
                    + 'Create one with LogoContentKey__c and HeaderContentKey__c populated for this org, '
                    + 'or pass includeBranding=false.');
            }
        }
        return configRecord;
    }

    private static String newBlockId() {
        Blob b = Crypto.generateAesKey(128);
        String hex = EncodingUtil.convertToHex(b);
        return hex.substring(0, 8) + '-' + hex.substring(8, 12) + '-' + hex.substring(12, 16)
            + '-' + hex.substring(16, 20) + '-' + hex.substring(20, 32);
    }

    // LLM-authored elementsJson can't be trusted to emit numbers as JSON numbers rather
    // than strings (confirmed live -- a real agent run sent widthPercent as "30" and hit
    // "Invalid conversion from runtime type String to Decimal"). Accept either.
    private static Decimal asDecimal(Object value, Decimal defaultValue) {
        if (value == null) {
            return defaultValue;
        }
        if (value instanceof Decimal) {
            return (Decimal) value;
        }
        try {
            return Decimal.valueOf(String.valueOf(value));
        } catch (Exception e) {
            return defaultValue;
        }
    }

    private static Integer asInteger(Object value, Integer defaultValue) {
        if (value == null) {
            return defaultValue;
        }
        if (value instanceof Decimal) {
            return ((Decimal) value).intValue();
        }
        if (value instanceof Integer) {
            return (Integer) value;
        }
        try {
            return Integer.valueOf(String.valueOf(value));
        } catch (Exception e) {
            return defaultValue;
        }
    }

    // Confirmed-correct data-graph traversal chains for common merge fields, ported from the
    // marketing toolkit's battle-tested {!$Expression.*} spec. The LLM never constructs these
    // -- it only ever writes a friendly {{FirstName}} placeholder in element text; this table
    // deterministically expands that into the exact expressionGroups chain Salesforce expects.
    private static Map<String, Object> exprRuleGroup(String name, String resource, String orderBy) {
        return new Map<String, Object>{
            'expressionRule' => new Map<String, Object>{
                'criteriaType' => 'AnyCriterionMatches', 'description' => '',
                'expressionCriteria' => new List<Object>(), 'name' => name + '_rule'
            },
            'expressionSort' => new Map<String, Object>{ 'orderBy' => orderBy, 'sortOrder' => 'DESC' },
            'name' => name,
            'resource' => resource
        };
    }

    private static Map<String, Object> exprHopGroup(String name, String resource) {
        return new Map<String, Object>{ 'name' => name, 'resource' => resource };
    }

    private static Map<String, Object> exprLeafGroup(String name, String resource) {
        return new Map<String, Object>{ 'name' => name, 'resource' => resource, 'selectionIndex' => 0.0 };
    }

    private static List<Object> expressionGroupsFor(String fieldName) {
        Map<String, Object> group0 = exprRuleGroup('group0', '{!$dataGraph.IndividualIdentityLink__dlm}', 'SourceRecordId__c');
        Map<String, Object> group1 = exprHopGroup('group1', '{!group0.ssot__Individual__dlm}');

        if (fieldName == 'FirstName') {
            return new List<Object>{ group0, group1, exprLeafGroup('group2', '{!group1.ssot__FirstName__c}') };
        }
        if (fieldName == 'LastName') {
            return new List<Object>{ group0, group1, exprLeafGroup('group2', '{!group1.ssot__LastName__c}') };
        }
        if (fieldName == 'AccountName') {
            Map<String, Object> group2 = exprRuleGroup('group2', '{!group1.ssot__Account__dlm}', 'ssot__Id__c');
            return new List<Object>{ group0, group1, group2, exprLeafGroup('group3', '{!group2.ssot__Name__c}') };
        }
        if (fieldName == 'Persona') {
            Map<String, Object> group2 = exprRuleGroup('group2', '{!group1.ssot__ContactPointEmail__dlm}', 'ssot__Id__c');
            Map<String, Object> group3 = exprRuleGroup('group3', '{!group2.ssot__EmailEngagementScore__dlm}', 'ssot__Id__c');
            return new List<Object>{ group0, group1, group2, group3, exprLeafGroup('group4', '{!group3.ssot__EmailEngagementPersona__c}') };
        }
        throw new ElementException('Unsupported merge field "' + fieldName
            + '" -- supported: FirstName, LastName, AccountName, Persona.');
    }

    private static Map<String, Object> multiLevelExpressionEntry(String fieldName, String defaultText) {
        Map<String, Object> entry = new Map<String, Object>{
            'definition' => 'sfdc_cms__multiLevelExpression',
            'label' => fieldName,
            'sfdcExpressionKey' => fieldName,
            'attributes' => new Map<String, Object>{ 'expressionGroups' => expressionGroupsFor(fieldName) }
        };
        if (String.isNotBlank(defaultText)) {
            entry.put('default', defaultText);
        }
        return entry;
    }

    // Confirmed-correct relationship-path hop chains and criteria shapes, ported from the
    // marketing toolkit's live-verified PersonalizationPoint builders (aura_client.py,
    // create_master_pp.py). A decision on the root UnifiedIndividual__dlm object uses a bare
    // TextComparison (no aggregation -- it's a single record per individual, confirmed live all
    // session). A decision on a RELATED object (reached via one of these paths) must be wrapped
    // in a NumberAggregation(count >= 1) around the real comparison, or the PP create Gacks.
    private static List<Object> pathHop(String fromObj, String toObj) {
        return new List<Object>{
            new Map<String, Object>{ 'objectApiName' => fromObj },
            new Map<String, Object>{ 'objectApiName' => toObj }
        };
    }

    private static List<Object> individualPath() {
        return new List<Object>{
            pathHop('UnifiedIndividual__dlm', 'IndividualIdentityLink__dlm'),
            pathHop('IndividualIdentityLink__dlm', 'ssot__Individual__dlm')
        };
    }

    private static List<Object> accountPath() {
        List<Object> p = individualPath();
        p.add(pathHop('ssot__Individual__dlm', 'ssot__Account__dlm'));
        return p;
    }

    private static List<Object> contactPointAddressPath() {
        List<Object> p = individualPath();
        p.add(pathHop('ssot__Individual__dlm', 'ssot__ContactPointAddress__dlm'));
        return p;
    }

    private static List<Object> emailEngagementPath() {
        List<Object> p = individualPath();
        p.add(pathHop('ssot__Individual__dlm', 'ssot__ContactPointEmail__dlm'));
        p.add(pathHop('ssot__ContactPointEmail__dlm', 'ssot__EmailEngagementScore__dlm'));
        return p;
    }

    private static List<Object> leadPath() {
        List<Object> p = accountPath();
        p.add(pathHop('ssot__Account__dlm', 'ssot__Lead__dlm'));
        return p;
    }

    private static final Set<String> KNOWN_PATH_ALIASES = new Set<String>{
        'ACCOUNT_PATH', 'CONTACT_POINT_ADDRESS_PATH', 'INDIVIDUAL_PATH', 'EMAIL_ENGAGEMENT_PATH', 'LEAD_PATH'
    };

    private static List<Object> resolvePathAlias(String alias) {
        if (alias == 'ACCOUNT_PATH') { return accountPath(); }
        if (alias == 'CONTACT_POINT_ADDRESS_PATH') { return contactPointAddressPath(); }
        if (alias == 'INDIVIDUAL_PATH') { return individualPath(); }
        if (alias == 'EMAIL_ENGAGEMENT_PATH') { return emailEngagementPath(); }
        if (alias == 'LEAD_PATH') { return leadPath(); }
        throw new WireException('Unsupported criteriaPath "' + alias + '" -- supported: '
            + String.join(new List<String>(KNOWN_PATH_ALIASES), ', '));
    }

    // The comparison node's `type` MUST match the field's real data type or the DC platform rejects
    // it ("Predicate type Text is not compatible with the data type of <field>"). Text is the default;
    // Number covers Number/Currency/Percent/Double/Int; DateTime/Date -> DateComparison.
    private static String comparisonTypeFor(String dataType) {
        if (String.isBlank(dataType)) { return 'TextComparison'; }
        String d = dataType.toLowerCase();
        if (d.contains('date') || d.contains('time')) { return 'DateComparison'; }
        if (d.contains('number') || d.contains('currency') || d.contains('percent')
            || d.contains('double') || d.contains('int') || d.contains('decimal')) { return 'NumberComparison'; }
        return 'TextComparison';
    }

    // Comparison keyed by the field's data type. `dataType` may be null (-> Text, the historical
    // behavior). Numeric "equal"/"in" values are emitted as numbers, not strings.
    private static Map<String, Object> fieldComparison(List<Object> path, String fieldApiName, String objectApiName,
            String operator, List<Object> values, String dataType) {
        String cmpType = comparisonTypeFor(dataType);
        Map<String, Object> tc = new Map<String, Object>{
            'type' => cmpType,
            'path' => path,
            'subject' => new Map<String, Object>{ 'fieldApiName' => fieldApiName, 'objectApiName' => objectApiName },
            'operator' => operator
        };
        if (values != null) {
            if (cmpType == 'NumberComparison') {
                List<Object> nums = new List<Object>();
                for (Object v : values) {
                    try { nums.add(Decimal.valueOf(String.valueOf(v).trim())); }
                    catch (Exception e) { nums.add(v); /* leave as-is; platform will surface a clear error */ }
                }
                tc.put('values', nums);
            } else {
                tc.put('values', values);
            }
        }
        return tc;
    }

    // Back-compat shim: existing callers that don't know the data type get Text behavior.
    private static Map<String, Object> textComparison(List<Object> path, String fieldApiName, String objectApiName, String operator, List<Object> values) {
        return fieldComparison(path, fieldApiName, objectApiName, operator, values, null);
    }

    // Confirmed: full state names ("California") silently break DC preview -- 2-letter codes
    // only. Deterministic guard so this can't slip through regardless of what the LLM writes.
    private static void validateStateProvinceValues(String fieldApiName, List<Object> values) {
        if (String.isBlank(fieldApiName) || !fieldApiName.contains('StateProvince')) {
            return;
        }
        for (Object v : values) {
            String s = String.valueOf(v);
            if (!Pattern.matches('[A-Z]{2}', s)) {
                throw new WireException('State/Province decision values must be 2-letter uppercase codes (e.g. "CA"), not "'
                    + s + '" -- full names break DC preview.');
            }
        }
    }

    // Builds a decision's `criteria` JSON. Supports criteriaType "has_value" (default) |
    // "equals" | "in", optionally against a related object reached via criteriaPath (one of
    // KNOWN_PATH_ALIASES) instead of the root UnifiedIndividual__dlm object.
    // Public so ValidateContentPlanAction can dry-run this same logic to catch bad
    // criteriaType/criteriaPath/values before the user is asked to approve a plan.
    // Human display label for a decision. Base = the plan's label (else its name). For an
    // equals/in decision, append the value(s) when the base doesn't already carry them -- so an
    // axis whose decisions the planner named identically (e.g. all "Recipient industry") becomes
    // "Recipient industry - Healthcare", "Recipient industry - Technology", etc. Presence checks
    // (has_value) and labels that already include the value are left unchanged. Deterministic:
    // never trusts the LLM to have distinguished the per-value names.
    public static String decisionDisplayLabel(Map<String, Object> spec) {
        String base = spec.get('label') != null && String.isNotBlank(String.valueOf(spec.get('label')))
            ? String.valueOf(spec.get('label')) : String.valueOf(spec.get('name'));
        if (String.isBlank(base) || base == 'null') { base = 'Decision'; }
        String ct = String.valueOf(spec.get('criteriaType'));
        // Collect the human value(s) for this decision.
        List<String> vals = new List<String>();
        if (ct == 'equals' && spec.get('value') != null) {
            vals.add(String.valueOf(spec.get('value')));
        } else if (ct == 'in' && spec.get('values') instanceof List<Object>) {
            for (Object v : (List<Object>) spec.get('values')) { vals.add(String.valueOf(v)); }
        }
        if (vals.isEmpty()) { return base; }                 // has_value / no value -> no suffix
        String valStr = String.join(vals, ', ');
        // Already carries the value? (case-insensitive contains) -> leave as-is.
        if (base.toLowerCase().contains(valStr.toLowerCase())) { return base; }
        return base + ' - ' + valStr;
    }

    public static Map<String, Object> buildDecisionCriteria(Map<String, Object> spec) {
        String fieldApiName = String.valueOf(spec.get('criteriaFieldApiName'));
        String objectApiName = String.isNotBlank(String.valueOf(spec.get('criteriaObjectApiName')))
            ? String.valueOf(spec.get('criteriaObjectApiName')) : 'UnifiedIndividual__dlm';
        Boolean isRoot = objectApiName == 'UnifiedIndividual__dlm';
        List<Object> path = isRoot ? new List<Object>() : resolvePathAlias(String.valueOf(spec.get('criteriaPath')));

        String criteriaType = String.isNotBlank(String.valueOf(spec.get('criteriaType')))
            ? String.valueOf(spec.get('criteriaType')) : 'has_value';
        // Field data type (from the graph catalog, threaded by Assemble) -> selects Text/Number/Date
        // comparison so the predicate matches the field. Absent -> Text (historical default).
        String dataType = spec.get('dataType') == null ? null : String.valueOf(spec.get('dataType'));

        List<Object> values = null;
        if (criteriaType == 'equals') {
            Object v = spec.get('value');
            if (v == null) {
                throw new WireException('Decision "' + spec.get('name') + '": criteriaType "equals" requires a "value".');
            }
            values = new List<Object>{ v };
        } else if (criteriaType == 'in') {
            Object vs = spec.get('values');
            if (!(vs instanceof List<Object>) || ((List<Object>) vs).isEmpty()) {
                throw new WireException('Decision "' + spec.get('name') + '": criteriaType "in" requires a non-empty "values" array.');
            }
            values = (List<Object>) vs;
        } else if (criteriaType != 'has_value') {
            throw new WireException('Decision "' + spec.get('name') + '": unsupported criteriaType "' + criteriaType
                + '" -- supported: has_value, equals, in.');
        }
        if (values != null) {
            validateStateProvinceValues(fieldApiName, values);
        }

        if (isRoot) {
            // Root object is a single record per individual -- no NumberAggregation wrapper
            // needed. But the outer LogicalComparison(and, single filter) wrapper is NOT
            // optional -- confirmed live that a bare TextComparison wires up (PP/operation/
            // variant all create successfully) but renders as a BLANK rule in Builder's rules
            // pane, since criteria is stored as an opaque JSON string with no shape validation
            // at create time. Every case must return this same outer shape for consistency.
            if (criteriaType == 'has_value') {
                return new Map<String, Object>{
                    'type' => 'LogicalComparison', 'operator' => 'and',
                    'filters' => new List<Object>{ fieldComparison(path, fieldApiName, objectApiName, 'has value', null, dataType) }
                };
            }
            if (criteriaType == 'equals') {
                return new Map<String, Object>{
                    'type' => 'LogicalComparison', 'operator' => 'and',
                    'filters' => new List<Object>{ fieldComparison(path, fieldApiName, objectApiName, 'equal', values, dataType) }
                };
            }
            List<Object> orFilters = new List<Object>();
            for (Object v : values) {
                orFilters.add(fieldComparison(path, fieldApiName, objectApiName, 'equal', new List<Object>{ v }, dataType));
            }
            return new Map<String, Object>{
                'type' => 'LogicalComparison', 'operator' => 'and',
                'filters' => new List<Object>{ new Map<String, Object>{ 'type' => 'LogicalComparison', 'operator' => 'or', 'filters' => orFilters } }
            };
        }

        Map<String, Object> innerFilter;
        if (criteriaType == 'in') {
            List<Object> orFilters = new List<Object>();
            for (Object v : values) {
                orFilters.add(fieldComparison(path, fieldApiName, objectApiName, 'equal', new List<Object>{ v }, dataType));
            }
            innerFilter = new Map<String, Object>{ 'type' => 'LogicalComparison', 'operator' => 'or', 'filters' => orFilters };
        } else {
            String op = criteriaType == 'equals' ? 'equal' : 'has value';
            innerFilter = new Map<String, Object>{
                'type' => 'LogicalComparison', 'operator' => 'and',
                'filters' => new List<Object>{ fieldComparison(path, fieldApiName, objectApiName, op, values, dataType) }
            };
        }

        return new Map<String, Object>{
            'type' => 'LogicalComparison', 'operator' => 'and',
            'filters' => new List<Object>{
                new Map<String, Object>{
                    'type' => 'NumberAggregation',
                    'aggregateFunction' => 'count',
                    'path' => path,
                    'comparison' => new Map<String, Object>{
                        'type' => 'NumberComparison', 'operator' => 'greater than or equal',
                        'subject' => new Map<String, Object>{ 'fieldApiName' => fieldApiName, 'objectApiName' => objectApiName },
                        'value' => 1
                    },
                    'filter' => innerFilter
                }
            }
        };
    }

    private static Map<String, Object> dataGraphDataProvider(String graphName, String dataSpace) {
        return new Map<String, Object>{
            'attributes' => new Map<String, Object>{ 'dataGraphApiName' => graphName, 'dataspace' => dataSpace },
            'definition' => 'sfdc_cms__dataGraphDataProvider',
            'sfdcExpressionKey' => '$dataGraph'
        };
    }

    // {{FirstName}} or {{FirstName|there}} in element text -- deterministic substitution into
    // Salesforce's {!$Expression.FirstName} syntax, so the LLM only ever writes plain creative
    // text with a friendly placeholder and never touches CMS-internal merge-field syntax.
    private static final Pattern MERGE_PLACEHOLDER = Pattern.compile('\\{\\{(\\w+)(?:\\|([^}]*))?\\}\\}');
    // The only merge fields expressionGroupsFor() can build a data-graph path for. A placeholder for
    // anything else (e.g. {{PrimaryIndustry}} the model sometimes adds inside a segment-specific
    // variant) is degraded to its default text rather than hard-failing the build.
    private static final Set<String> SUPPORTED_MERGE_FIELDS = new Set<String>{
        'FirstName', 'LastName', 'AccountName', 'Persona'
    };

    private static void substituteMergePlaceholders(Map<String, Object> el, Map<String, Object> expressionsByKey) {
        Object raw = el.get('text');
        if (!(raw instanceof String)) {
            return;
        }
        el.put('text', substituteMergePlaceholdersInText((String) raw, expressionsByKey));
    }

    // Also used on decision/variant textByDecision values -- confirmed live that a placeholder
    // in a DC variant's text passed through unsubstituted while the main body correctly
    // resolved it, because only the main elementsJson loop called this. Same substitution logic
    // has to apply everywhere user-facing text can appear.
    private static String substituteMergePlaceholdersInText(String text, Map<String, Object> expressionsByKey) {
        if (String.isBlank(text) || !text.contains('{{')) {
            return text;
        }
        Matcher m = MERGE_PLACEHOLDER.matcher(text);
        String result = '';
        Integer lastEnd = 0;
        while (m.find()) {
            String fieldName = m.group(1);
            String defaultText = m.group(2);
            if (SUPPORTED_MERGE_FIELDS.contains(fieldName)) {
                // A real, resolvable merge field -> wire it as an $Expression.
                if (!expressionsByKey.containsKey(fieldName)) {
                    expressionsByKey.put(fieldName, multiLevelExpressionEntry(fieldName, defaultText));
                }
                result += text.substring(lastEnd, m.start()) + '{!$Expression.' + fieldName + '}';
            } else {
                // UNSUPPORTED merge field (e.g. {{PrimaryIndustry}} the model added inside an
                // industry-specific variant, where it's redundant AND not a resolvable send-time
                // field). Degrade to the placeholder's default text (or drop it) instead of hard-
                // failing the whole build with "Unsupported merge field" -- the variant text is
                // already segment-specific; the inline token was never needed.
                result += text.substring(lastEnd, m.start()) + (defaultText == null ? '' : defaultText);
            }
            lastEnd = m.end();
        }
        result += text.substring(lastEnd);
        return result;
    }

    private static Map<String, Object> standardBackgroundImage() {
        return new Map<String, Object>{ 'repeat' => 'no-repeat', 'position' => 'center center', 'size' => 'cover' };
    }

    private static Map<String, Object> sectionAttrs() {
        return new Map<String, Object>{
            'stackOnMobile' => true,
            'lightning:colorScheme' => '{!$brand.colorScheme}',
            'lightning:margin' => '{!$brand.spacing.none}',
            'lightning:padding' => new Map<String, Object>{
                'top' => new Map<String, Object>{ 'unit' => 'rem', 'value' => 0.5 },
                'bottom' => new Map<String, Object>{ 'unit' => 'rem', 'value' => 0.5 },
                'left' => new Map<String, Object>{ 'unit' => 'rem', 'value' => 1.5 },
                'right' => new Map<String, Object>{ 'unit' => 'rem', 'value' => 1.5 }
            },
            'lightning:borderRadius' => '{!$brand.borderRadius.square}',
            'lightning:borderWidth' => '{!$brand.borderWeight.none}',
            'lightning:backgroundImage' => standardBackgroundImage()
        };
    }

    private static Map<String, Object> columnAttrs(Decimal columnWidth) {
        return new Map<String, Object>{
            'columnWidth' => columnWidth,
            'lightning:verticalAlignment' => 'top',
            'lightning:colorScheme' => '{!$brand.colorScheme}',
            'lightning:margin' => '{!$brand.spacing.none}',
            'lightning:padding' => '{!$brand.spacing.none}',
            'lightning:borderRadius' => '{!$brand.borderRadius.square}',
            'lightning:borderWidth' => '{!$brand.borderWeight.none}',
            'lightning:backgroundImage' => standardBackgroundImage()
        };
    }

    private static Map<String, Object> sectionWithColumn(List<Object> children) {
        Map<String, Object> column = new Map<String, Object>{
            'id' => newBlockId(), 'definition' => 'lightning/column', 'type' => 'block',
            'attributes' => columnAttrs(12.0), 'children' => children
        };
        return new Map<String, Object>{
            'id' => newBlockId(), 'definition' => 'lightning/section', 'type' => 'block',
            'attributes' => sectionAttrs(), 'children' => new List<Object>{ column }
        };
    }

    private static Map<String, Object> paddingMap(Decimal top, Decimal bottom, Decimal left, Decimal right) {
        return new Map<String, Object>{
            'top' => new Map<String, Object>{ 'unit' => 'px', 'value' => top },
            'bottom' => new Map<String, Object>{ 'unit' => 'px', 'value' => bottom },
            'left' => new Map<String, Object>{ 'unit' => 'px', 'value' => left },
            'right' => new Map<String, Object>{ 'unit' => 'px', 'value' => right }
        };
    }

    // Generic body image padding -- flush-to-frame images with no breathing room were a known
    // quality defect in the toolkit's own spec until it added explicit padding profiles.
    private static Map<String, Object> imageBlock(String id, String contentKey, String altText, Decimal widthPercent) {
        return imageBlock(id, contentKey, altText, widthPercent, paddingMap(8.0, 16.0, 24.0, 24.0));
    }

    private static Map<String, Object> imageBlock(String id, String contentKey, String altText, Decimal widthPercent, Map<String, Object> padding) {
        return new Map<String, Object>{
            'id' => id,
            'definition' => 'lightning/image',
            'type' => 'block',
            'attributes' => imageAttributes(contentKey, altText, widthPercent, padding)
        };
    }

    // Image altText lives in the same `attributes` object as a button's label text, whose org hard
    // limit is 255 (confirmed live: "attributes.text may only be 255 characters long"). altText is
    // plan-authored (LLM) and otherwise unclamped, so a verbose alt string would fail the PUT the same
    // way the button did. Clamp a few chars under, on a word boundary. No-op when short. One write
    // point (line below) covers both the base image and the image-swap variant callers.
    private static final Integer ALT_TEXT_MAX = 250;
    private static String clampAltText(String s) {
        if (String.isBlank(s)) { return s; }
        String t = s.trim();
        if (t.length() <= ALT_TEXT_MAX) { return t; }
        String cut = t.substring(0, ALT_TEXT_MAX);
        Integer sp = cut.lastIndexOf(' ');
        if (sp >= ALT_TEXT_MAX / 2) { cut = cut.substring(0, sp); }
        return cut.trim();
    }

    private static Map<String, Object> imageAttributes(String contentKey, String altText, Decimal widthPercent, Map<String, Object> padding) {
        return new Map<String, Object>{
            'imageFitConfig' => new Map<String, Object>{
                'width' => new Map<String, Object>{ 'unit' => '%', 'value' => widthPercent }
            },
            'imageInfo' => new Map<String, Object>{
                'source' => new Map<String, Object>{
                    // ref MUST be the object form {"contentKey": "MC..."}, matching the marketing
                    // toolkit's proven _img_block helper (web/app.py) and the native CMS email
                    // builder's own output (verified live: every image ref in a natively-authored
                    // email in this org is source.ref.contentKey, not a bare string). A bare
                    // string ref still RENDERS (the /cms/media url resolves) so the earlier
                    // "confirmed live 400" note was a misdiagnosis -- but the builder can't link a
                    // bare-string ref back to its ManagedContent record, so the image shows yet is
                    // NOT selectable/replaceable in the email builder (the exact symptom this
                    // fixes). lightning:brandSource elsewhere is a different attribute that also
                    // happens to take {"contentKey": ...}.
                    'ref' => new Map<String, Object>{ 'contentKey' => contentKey },
                    'type' => 'imageReference'
                },
                'url' => '/cms/media/' + contentKey,
                'altText' => clampAltText(altText)
            },
            'lightning:horizontalAlignment' => 'center',
            // Images space with lightning:margin, NOT lightning:padding -- matches the marketing
            // toolkit's proven _img_block helper (web/app.py) and the native builder. Padding on an
            // image block reads as the "extra styling" that made the agent's logo look off vs a
            // normally-authored one; margin is the correct property for image breathing room.
            'lightning:margin' => padding
        };
    }

    private static Map<String, Object> headingBlock(String id, String text) {
        return headingBlock(id, text, 2);
    }

    private static Map<String, Object> headingBlock(String id, String text, Integer level) {
        Integer safeLevel = (level == null || level < 1 || level > 6) ? 2 : level;
        return new Map<String, Object>{
            'id' => id,
            'definition' => 'lightning/heading',
            'type' => 'block',
            'attributes' => new Map<String, Object>{
                'text' => text,
                'level' => safeLevel,
                'align' => 'left',
                'lightning:typography' => '{!$brand.typography.heading.heading' + safeLevel + '}',
                'lightning:colorGroup' => new Map<String, Object>{ 'textColor' => '{!$brand.colorScheme.contrast}' },
                'lightning:padding' => paddingMap(24.0, 8.0, 24.0, 24.0)
            }
        };
    }

    private static Map<String, Object> paragraphBlock(String id, String text) {
        return new Map<String, Object>{
            'id' => id,
            'definition' => 'lightning/paragraph',
            'type' => 'block',
            'attributes' => new Map<String, Object>{
                'align' => 'left',
                'text' => text,
                // Confirmed live: headingBlock() and the footer paragraphs both set
                // lightning:typography to a named brand token, but this main-body paragraph
                // builder never did -- CMS Builder shows "Custom" style instead of inheriting
                // the brand's paragraph typography when this attribute is absent.
                'lightning:typography' => '{!$brand.typography.paragraph.paragraph1}',
                'lightning:padding' => paddingMap(16.0, 24.0, 24.0, 24.0)
            }
        };
    }

    // Deterministic guard, not a prompt instruction: confirmed live that Write Email Copy's
    // "never invent a plausible-looking fake URL" rule doesn't always hold -- it sometimes
    // fabricates a real-looking slug (e.g. "amd-event-details") despite the pre-approval
    // summary correctly showing the real fallback. A prompt rule can't be trusted for something
    // with a real consequence (CMS 400s on an invalid URL); force it here instead. A bare "#"
    // anchor also confirmed live to fail this org's URL-format validation on the button action,
    // so the safe fallback must be a real, trusted, absolute URL -- example.com is added to
    // this org's Trusted URLs (CspTrustedSite AuraPoc_Example_Placeholder) for exactly this.
    private static final String SAFE_FALLBACK_URL = 'https://www.example.com';

    private static String sanitizeUrl(String url) {
        if (String.isBlank(url) || url == 'null') {
            return SAFE_FALLBACK_URL;
        }
        String trimmed = url.trim();
        if (trimmed.toLowerCase().startsWith('http://') || trimmed.toLowerCase().startsWith('https://')) {
            return trimmed;
        }
        return SAFE_FALLBACK_URL;
    }

    private static Map<String, Object> buttonBlock(String id, String text, String url) {
        return new Map<String, Object>{
            'id' => id,
            'definition' => 'lightning/actionButton',
            'type' => 'block',
            'attributes' => new Map<String, Object>{
                'text' => text,
                'width' => 'auto',
                'lightning:click' => new Map<String, Object>{
                    'actions' => new List<Object>{
                        new Map<String, Object>{
                            'definition' => 'sfdc_cms__navigateToUrlAction',
                            'attributes' => new Map<String, Object>{ 'url' => url, 'openInNewTab' => false }
                        }
                    }
                },
                'sfdc_cms:styleGroup' => '{!$brand.buttonStyleGroup.primary}',
                'lightning:buttonColorGroup' => '{!$brand.buttonStyleGroup.primary.lightning:buttonColorGroup}',
                'lightning:typography' => '{!$brand.buttonStyleGroup.primary.lightning:typography}',
                'lightning:padding' => '{!$brand.buttonStyleGroup.primary.lightning:padding}',
                'lightning:borderRadius' => '{!$brand.buttonStyleGroup.primary.lightning:borderRadius}',
                'lightning:borderWidth' => '{!$brand.buttonStyleGroup.primary.lightning:borderWidth}',
                'lightning:margin' => new Map<String, Object>{
                    'top' => new Map<String, Object>{ 'unit' => 'px', 'value' => 16.0 },
                    'bottom' => new Map<String, Object>{ 'unit' => 'px', 'value' => 16.0 },
                    'left' => new Map<String, Object>{ 'unit' => 'px', 'value' => 16.0 },
                    'right' => new Map<String, Object>{ 'unit' => 'px', 'value' => 16.0 }
                },
                'lightning:horizontalAlignment' => 'center'
            }
        };
    }

    private static Map<String, Object> buildElementBlock(String id, Map<String, Object> el) {
        String type = String.valueOf(el.get('type'));
        if (type == 'heading') {
            return headingBlock(id, sanitizeText(String.valueOf(el.get('text'))), asInteger(el.get('level'), 2));
        } else if (type == 'paragraph') {
            return paragraphBlock(id, sanitizeText(String.valueOf(el.get('text'))));
        } else if (type == 'image') {
            // el.get('contentKey') is Apex null (not the string "null") when the key is
            // missing entirely -- confirmed live this NPEs Pattern.matches below instead of
            // reaching the clear "invalid contentKey" message. Normalize to '' first.
            String imgContentKey = String.isNotBlank(String.valueOf(el.get('contentKey')))
                ? String.valueOf(el.get('contentKey')) : '';
            // Deterministic guard, not a prompt instruction: confirmed live that the LLM can
            // fabricate an image contentKey from unrelated context text (e.g. it once used the
            // literal data-graph name "Real_Time_Data_Graph" as a "contentKey", producing a
            // confusing generic CMS error instead of failing loud with the real problem). Real
            // CMS contentKeys always look like "MC" + alphanumerics -- fail loud and clearly if
            // this doesn't, rather than letting CMS reject it with an unhelpful error later.
            if (!Pattern.matches('^MC[A-Za-z0-9]{2,60}$', imgContentKey)) {
                throw new ElementException('Image element "' + String.valueOf(el.get('key'))
                    + '" has an invalid contentKey ("' + imgContentKey + '") -- this must be a '
                    + 'real CMS contentKey (starts with "MC"), never a data graph name, brand '
                    + 'name, or other fabricated string. Omit the image slot instead if no real '
                    + 'asset was found for it.');
            }
            return imageBlock(id, imgContentKey, sanitizeText(String.valueOf(el.get('altText'))), asDecimal(el.get('widthPercent'), 100.0));
        } else if (type == 'button') {
            return buttonBlock(id, sanitizeText(String.valueOf(el.get('text'))), sanitizeUrl(String.valueOf(el.get('url'))));
        }
        throw new ElementException('Unsupported element type: ' + type
            + ' (expected heading, paragraph, image, or button)');
    }

    // ManagedContent.ContentTypeFullyQualifiedName is real and describe-visible but Apex's
    // native SOQL engine rejects it in both static and dynamic (Database.query) form --
    // confirmed live in FindBrandAssetsAction. The REST /query endpoint accepts it fine, so
    // this type lookup goes through a callout rather than a native SOQL WHERE/SELECT.
    // Result of a content-key lookup: whether the lookup callout itself succeeded (so callers can
    // fail-open on a transport error but fail-loud on a genuinely absent key), the set of keys that
    // actually EXIST in the org, and the content type of each.
    private class KeyLookup {
        Boolean ran = false;                                  // the /query callout returned 200
        Set<String> existing = new Set<String>();             // keys present in the org (any type)
        Map<String, String> typeByKey = new Map<String, String>();
    }

    private static KeyLookup queryContentKeys(String accessToken, Set<String> keys) {
        KeyLookup out = new KeyLookup();
        List<String> quoted = new List<String>();
        for (String k : keys) {
            quoted.add('\'' + String.escapeSingleQuotes(k) + '\'');
        }
        String soql = 'SELECT ManagedContentKey, ManagedContent.ContentTypeFullyQualifiedName '
            + 'FROM ManagedContentVariant WHERE ManagedContentKey IN (' + String.join(quoted, ',') + ')';
        HttpRequest queryReq = new HttpRequest();
        queryReq.setMethod('GET');
        queryReq.setEndpoint(AuraPocTokenProvider.instanceUrl() + '/services/data/v66.0/query?q=' + EncodingUtil.urlEncode(soql, 'UTF-8'));
        queryReq.setHeader('Authorization', 'Bearer ' + accessToken);
        queryReq.setTimeout(30000);
        HttpResponse queryRes = new Http().send(queryReq);
        if (queryRes.getStatusCode() != 200) {
            // Lookup/transport error -- leave ran=false so callers fail OPEN (an unrelated API
            // hiccup here shouldn't block a build the CMS callout would otherwise accept).
            return out;
        }
        out.ran = true;
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(queryRes.getBody());
        for (Object recObj : (List<Object>) parsed.get('records')) {
            Map<String, Object> rec = (Map<String, Object>) recObj;
            String key = String.valueOf(rec.get('ManagedContentKey'));
            if (String.isBlank(key)) { continue; }
            out.existing.add(key);
            Map<String, Object> mc = (Map<String, Object>) rec.get('ManagedContent');
            String contentType = mc != null ? String.valueOf(mc.get('ContentTypeFullyQualifiedName')) : null;
            if (String.isNotBlank(contentType)) {
                out.typeByKey.put(key, contentType);
            }
        }
        return out;
    }

    // Deterministic guard, not a prompt instruction: confirmed live that branding resolution
    // can hand back a brand RECORD's contentKey (sfdc_cms__brand) where a logo/header/body
    // image's contentKey (sfdc_cms__image) was expected -- the two are never legitimately
    // interchangeable, but nothing before this point verifies the TYPE of an image contentKey,
    // only its shape (see the "MC" prefix check in buildElementBlock). Fed to CMS as-is, this
    // produces an opaque HTTP 500 "UNKNOWN_EXCEPTION" deep in the CMS renderer instead of a
    // clear error here.
    // Rewrite each image element's contentKey from an asset ROLE (logo/header -> the request's
    // already-resolved override keys) or an exact asset NAME (matched against assetsJson, the same
    // catalog the plan saw as BrandContext). The LLM emits assetRole/assetName, never a raw key.
    // Back-compat: a literal contentKey that's already present is left as-is. Fails loud (clear,
    // build-blocking message) on a name that matches zero or many assets, so a bad reference never
    // slips through as an opaque CMS 404.
    private static void resolveImageRefs(List<Object> elements, Request req) {
        // Build name -> contentKey from the asset catalog (exact, case-insensitive on trimmed name).
        Map<String, String> keyByName = new Map<String, String>();
        Map<String, Integer> nameCount = new Map<String, Integer>();
        if (String.isNotBlank(req.assetsJson)) {
            Object parsed;
            try { parsed = JSON.deserializeUntyped(AuraPocJson.stripFence(req.assetsJson)); }
            catch (Exception e) { parsed = null; }
            if (parsed instanceof List<Object>) {
                for (Object o : (List<Object>) parsed) {
                    if (!(o instanceof Map<String, Object>)) { continue; }
                    Map<String, Object> a = (Map<String, Object>) o;
                    String nm = a.get('name') == null ? '' : String.valueOf(a.get('name')).trim().toLowerCase();
                    String ck = a.get('contentKey') == null ? '' : String.valueOf(a.get('contentKey'));
                    if (String.isBlank(nm) || String.isBlank(ck)) { continue; }
                    keyByName.put(nm, ck);
                    nameCount.put(nm, (nameCount.containsKey(nm) ? nameCount.get(nm) : 0) + 1);
                }
            }
        }
        for (Object elObj : elements) {
            if (!(elObj instanceof Map<String, Object>)) { continue; }
            Map<String, Object> el = (Map<String, Object>) elObj;
            if (String.valueOf(el.get('type')) != 'image') { continue; }

            // Already has a literal key (back-compat / other callers) -> leave it; the existence
            // guard downstream still verifies it.
            if (String.isNotBlank(String.valueOf(el.get('contentKey')))) { continue; }

            String role = el.get('assetRole') == null ? '' : String.valueOf(el.get('assetRole')).trim().toLowerCase();
            String assetName = el.get('assetName') == null ? '' : String.valueOf(el.get('assetName')).trim();

            if (role == 'logo' || role == 'header') {
                String resolved = role == 'logo' ? req.logoContentKeyOverride : req.headerContentKeyOverride;
                if (String.isBlank(resolved)) {
                    throw new ElementException('Image element "' + String.valueOf(el.get('key'))
                        + '" asks for the ' + role + ', but no ' + role + ' was resolved for this '
                        + 'build (Resolve Branding found none). Omit the ' + role + ' image slot, or '
                        + 'ensure the brand has a ' + role + ' asset.');
                }
                el.put('contentKey', resolved);
                continue;
            }

            if (String.isNotBlank(assetName)) {
                String nmKey = assetName.toLowerCase();
                Integer cnt = nameCount.containsKey(nmKey) ? nameCount.get(nmKey) : 0;
                if (cnt == 0) {
                    throw new ElementException('Image element "' + String.valueOf(el.get('key'))
                        + '" references asset "' + assetName + '", which does not exist in this org\'s '
                        + 'brand assets. Use only an exact asset name from the provided list, or omit '
                        + 'the image slot.');
                }
                if (cnt > 1) {
                    throw new ElementException('Image element "' + String.valueOf(el.get('key'))
                        + '" references asset "' + assetName + '", which is ambiguous (' + cnt
                        + ' assets share that name). Reference it a different way or rename the assets.');
                }
                el.put('contentKey', keyByName.get(nmKey));
                continue;
            }

            // Neither a literal key, a role, nor a resolvable name -> fail loud rather than build a
            // blank image (buildElementBlock would reject it, but with a less specific message).
            throw new ElementException('Image element "' + String.valueOf(el.get('key'))
                + '" has no resolvable asset -- provide assetRole (logo/header) or an exact assetName '
                + 'from the brand asset list. The system resolves the real contentKey; do not supply one.');
        }
    }

    // Build a name(lowercased)->contentKey map + a name->count (for ambiguity) from an assets JSON
    // catalog. Shared by base-element and variant-image resolution.
    private static void buildAssetNameMap(String assetsJson, Map<String, String> keyByName, Map<String, Integer> nameCount) {
        if (String.isBlank(assetsJson)) { return; }
        Object parsed;
        try { parsed = JSON.deserializeUntyped(AuraPocJson.stripFence(assetsJson)); }
        catch (Exception e) { return; }
        if (!(parsed instanceof List<Object>)) { return; }
        for (Object o : (List<Object>) parsed) {
            if (!(o instanceof Map<String, Object>)) { continue; }
            Map<String, Object> a = (Map<String, Object>) o;
            String nm = a.get('name') == null ? '' : String.valueOf(a.get('name')).trim().toLowerCase();
            String ck = a.get('contentKey') == null ? '' : String.valueOf(a.get('contentKey'));
            if (String.isBlank(nm) || String.isBlank(ck)) { continue; }
            keyByName.put(nm, ck);
            nameCount.put(nm, (nameCount.containsKey(nm) ? nameCount.get(nm) : 0) + 1);
        }
    }

    // Ordered, DISTINCT list of image contentKeys from the catalog, preserving catalog order. Used by
    // the deterministic image auto-assign fallback so each personalized decision gets a different real
    // image even when the plan named no asset. Order is stable within a run (catalog is fetched once).
    private static List<String> orderedCatalogKeys(String assetsJson) {
        List<String> out = new List<String>();
        Set<String> seen = new Set<String>();
        if (String.isBlank(assetsJson)) { return out; }
        Object parsed;
        try { parsed = JSON.deserializeUntyped(AuraPocJson.stripFence(assetsJson)); }
        catch (Exception e) { return out; }
        if (!(parsed instanceof List<Object>)) { return out; }
        for (Object o : (List<Object>) parsed) {
            if (!(o instanceof Map<String, Object>)) { continue; }
            String ck = ((Map<String, Object>) o).get('contentKey') == null ? ''
                : String.valueOf(((Map<String, Object>) o).get('contentKey'));
            if (String.isNotBlank(ck) && !seen.contains(ck)) { seen.add(ck); out.add(ck); }
        }
        return out;
    }

    // Resolve image-DC VARIANT keys the same way base image elements are resolved: each image
    // target's textByDecision value is an object; if it carries assetRole (logo/header) or assetName
    // (exact catalog match) we rewrite its contentKey to the real key -- so an image-swap variant
    // never depends on an LLM-typed MC-key (which it can corrupt by a character, exactly the base
    // bug, reproduced live inside variants). A literal contentKey is left for the existence guard.
    // Mutates ppSpecs in place; returns the set of resolved variant image keys to existence-check.
    // Shared by Build and Update (called via sharedResolveVariantImageRefs).
    private static Set<String> resolveVariantImageRefs(List<Object> ppSpecs, String assetsJson,
            String logoKey, String headerKey) {
        Set<String> keys = new Set<String>();
        Map<String, String> keyByName = new Map<String, String>();
        Map<String, Integer> nameCount = new Map<String, Integer>();
        buildAssetNameMap(assetsJson, keyByName, nameCount);
        // Ordered, DISTINCT list of catalog image contentKeys, for the deterministic auto-assign
        // fallback below: when the plan personalizes an image slot but the model picked NO asset for a
        // decision (common with generic stock that fits no business axis), we still want a visible,
        // different image per audience -- so we hand each such decision the next distinct catalog image
        // (round-robin), rather than failing the whole update. Order = catalog order (stable per run).
        List<String> catalogKeys = orderedCatalogKeys(assetsJson);

        for (Object ppObj : ppSpecs) {
            Map<String, Object> pp = (Map<String, Object>) ppObj;
            Object tjObj = pp.get('targetsJson');
            if (tjObj == null) { continue; }
            List<Object> targets = (List<Object>) JSON.deserializeUntyped(String.valueOf(tjObj));
            Boolean changed = false;
            for (Object tObj : targets) {
                Map<String, Object> t = (Map<String, Object>) tObj;
                if (String.valueOf(t.get('blockDefinition')) != 'lightning/image') { continue; }
                Object tbd = t.get('textByDecision');
                if (!(tbd instanceof Map<String, Object>)) { continue; }
                Map<String, Object> byDec = (Map<String, Object>) tbd;
                // Per-target counter for the round-robin auto-assign fallback, so distinct decisions
                // on THIS image target land on distinct catalog images (dec 1 -> catalogKeys[0], etc).
                Integer autoIdx = 0;
                for (String dec : byDec.keySet()) {
                    if (!(byDec.get(dec) instanceof Map<String, Object>)) { continue; }
                    Map<String, Object> img = (Map<String, Object>) byDec.get(dec);
                    String existing = img.get('contentKey') == null ? '' : String.valueOf(img.get('contentKey'));
                    String role = img.get('assetRole') == null ? '' : String.valueOf(img.get('assetRole')).trim().toLowerCase();
                    String assetName = img.get('assetName') == null ? '' : String.valueOf(img.get('assetName')).trim();
                    String resolved = '';
                    if (String.isNotBlank(existing)) {
                        resolved = existing;                        // literal -> existence-checked below
                    } else if (role == 'logo' || role == 'header') {
                        resolved = role == 'logo' ? logoKey : headerKey;
                        if (String.isBlank(resolved)) {
                            throw new ElementException('An image-swap variant asks for the ' + role
                                + ', but no ' + role + ' was resolved for this build.');
                        }
                        img.put('contentKey', resolved); changed = true;
                    } else if (String.isNotBlank(assetName)) {
                        String nmKey = assetName.toLowerCase();
                        Integer cnt = nameCount.containsKey(nmKey) ? nameCount.get(nmKey) : 0;
                        if (cnt == 0) {
                            throw new ElementException('Image-swap variant references asset "' + assetName
                                + '", which does not exist in this org\'s brand assets. Use an exact asset '
                                + 'name from the provided list.');
                        }
                        if (cnt > 1) {
                            throw new ElementException('Image-swap variant references asset "' + assetName
                                + '", which is ambiguous (' + cnt + ' assets share that name).');
                        }
                        resolved = keyByName.get(nmKey);
                        img.put('contentKey', resolved); changed = true;
                    } else if (!catalogKeys.isEmpty()) {
                        // DETERMINISTIC AUTO-ASSIGN: the plan personalized this image slot but named no
                        // asset for this decision. Hand this decision the next DISTINCT catalog image so
                        // the audience sees a different picture. INSUFFICIENT-IMAGES GUARD: if there are
                        // more auto-assigned decisions than distinct catalog images, the round-robin would
                        // WRAP and reuse an image -- two audiences would silently get the same picture, so
                        // the "swap" is invisible. Fail loud here (before any variant ships) with the counts
                        // instead. (ReadDynamicEmailAction's >= MIN_IMAGES_FOR_SWAP offer floor prevents the
                        // common case; this backstops when a request slips through with too many values.)
                        if (autoIdx >= catalogKeys.size()) {
                            throw new ElementException('Personalizing this image by ' + (autoIdx + 1)
                                + ' or more values needs that many distinct images, but this org has only '
                                + catalogKeys.size() + ' image(s) to swap between. Reduce the number of values, '
                                + 'name a specific image per value, or add more stock/brand images.');
                        }
                        resolved = catalogKeys[autoIdx];
                        autoIdx++;
                        img.put('contentKey', resolved); changed = true;
                    } else {
                        throw new ElementException('Personalizing an image means swapping the picture per '
                            + 'audience, but this org has no images to swap between. Add stock or brand '
                            + 'images (at least ' + 2 + '), or personalize a text slot (paragraph/heading/button) instead.');
                    }
                    if (String.isNotBlank(resolved)) { keys.add(resolved); }
                }
            }
            if (changed) { pp.put('targetsJson', JSON.serialize(targets)); }
        }
        return keys;
    }

    private static void validateImageContentKeys(String accessToken, Set<String> keys) {
        if (keys.isEmpty()) {
            return;
        }
        KeyLookup look = queryContentKeys(accessToken, keys);
        // If the lookup callout itself didn't run (transport error), fail OPEN -- don't block a
        // build the CMS callout would otherwise accept.
        if (!look.ran) {
            return;
        }
        for (String k : keys) {
            // Lookup ran and this key is genuinely absent from the org -- almost always an
            // LLM-fabricated contentKey (MC-shaped so it passes the format guard, but no such
            // record exists). Fail loud here with the key named, instead of letting the CMS
            // create callout reject it later with an opaque CONTENT_NOT_FOUND 404.
            if (!look.existing.contains(k)) {
                throw new ElementException('Image content key "' + k + '" does not exist in this '
                    + 'org -- it looks like a fabricated/placeholder key, not a real CMS asset. '
                    + 'Use only contentKeys returned by Find Brand Assets for this org, or omit '
                    + 'the image slot if no real asset was found.');
            }
            String actualType = look.typeByKey.get(k);
            if (actualType != null && actualType != 'sfdc_cms__image') {
                throw new ElementException('Content key "' + k + '" is a ' + actualType
                    + ' record, not an image -- it cannot be used as a logo, header, or body '
                    + 'image. This is almost always a brand-record contentKey (from Find Brand '
                    + 'Record) mistakenly used where a logo/header/body image contentKey (from '
                    + 'Find Brand Assets) was expected.');
            }
        }
    }

    @InvocableMethod(label='Build Dynamic Email' description='Creates an sfdc_cms__email CMS content item from a list of content elements, and optionally wires dynamic content personalization into it, in one atomic call. If personalization is requested but fails, the created email is deleted rather than left half-built.')
    public static List<Result> buildDynamicEmail(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result res = new Result();
            String dataSpace = String.isNotBlank(req.dataSpaceName) ? req.dataSpaceName : 'default';
            String graphName = req.profileDataGraphName;
            String accessToken;
            String managedContentId;
            String managedContentVariantId;
            try {
                accessToken = tokenSource.getAccessToken();

                // Auto-detect the org's data graph if not explicitly given, same as
                // DataGraphDetailsAction. Best-effort only: this is used purely for
                // personalization (see expressionsByKey/wantsPersonalization below), so a plain,
                // unpersonalized email must still build successfully even if an org has zero or
                // multiple data graphs and auto-detection can't resolve one -- any real problem
                // with the resolved/fallback name surfaces naturally later, only if and when
                // personalization is actually wired in.
                try {
                    graphName = DataGraphDetailsAction.resolveGraphApiName(accessToken, req.profileDataGraphName);
                } catch (Exception resolveEx) {
                    graphName = String.isNotBlank(req.profileDataGraphName) ? req.profileDataGraphName : 'Real_Time_Data_Graph';
                }

                // --- Step 1: build and create the base email ---
                if (req.subjectLine != null && req.subjectLine.contains('{{')) {
                    throw new ElementException('Merge field placeholders are not supported in the subject line -- it renders outside the data-graph context.');
                }
                if (req.preheader != null && req.preheader.contains('{{')) {
                    throw new ElementException('Merge field placeholders are not supported in the preheader -- it renders outside the data-graph context.');
                }
                // Confirmed live: passing a logo/header IMAGE asset's contentKey as
                // brandContentKeyOverride produces a CMS-side 400 ("Invalid ManagedContent
                // Reference content type [sfdc_cms__brand:sfdc_cms__image]") -- lightning:
                // brandSource requires an actual sfdc_cms__brand record's contentKey (from Find
                // Brand Record), never a logo/header image's (from Find Brand Assets). The two
                // never legitimately share a contentKey, so this catches the mistake
                // deterministically before the callout instead of surfacing a confusing HTTP 400.
                if (String.isNotBlank(req.brandContentKeyOverride)
                        && (req.brandContentKeyOverride == req.logoContentKeyOverride
                            || req.brandContentKeyOverride == req.headerContentKeyOverride)) {
                    throw new ElementException('brandContentKeyOverride "' + req.brandContentKeyOverride
                        + '" matches a logo/header image contentKey -- it must be a CMS brand RECORD\'s contentKey '
                        + '(from Find Brand Record), never a logo/header image\'s (from Find Brand Assets). '
                        + 'Omit brandContentKeyOverride entirely if no brand record was found for this brand.');
                }

                List<Object> elements = (List<Object>) JSON.deserializeUntyped(AuraPocJson.stripFence(req.elementsJson));

                // Deterministically resolve every image element's contentKey from an asset ROLE or
                // NAME, so the LLM never has to transcribe an MC-key (a more capable model corrupted
                // one by a single character -- MC3.. vs the real MC4.. -- which is far worse than an
                // obvious fake). role=logo/header -> the already-resolved override keys; a name ->
                // an exact match in the asset catalog. A literal contentKey is still honored for
                // back-compat. Rewrites el.contentKey in place; fails loud on an unresolvable ref.
                resolveImageRefs(elements, req);

                // The equality guard above only catches a brand/logo mixup when the SAME wrong
                // key is reused in two places -- confirmed live it doesn't help when the wrong
                // (non-image) key lands in logoContentKeyOverride alone: the CMS create callout
                // then 500s with an opaque "UNKNOWN_EXCEPTION" instead of a clean validation
                // error, because lightning:image's imageInfo.source.ref silently accepts any
                // contentKey shape and only fails deep inside CMS's own renderer. Independently
                // verify every contentKey that's about to be used as an image (override AND
                // body elements) is actually an sfdc_cms__image record before the callout.
                Set<String> imageKeysToValidate = new Set<String>();
                if (String.isNotBlank(req.logoContentKeyOverride)) {
                    imageKeysToValidate.add(req.logoContentKeyOverride);
                }
                if (String.isNotBlank(req.headerContentKeyOverride)) {
                    imageKeysToValidate.add(req.headerContentKeyOverride);
                }
                for (Object elObj : elements) {
                    Map<String, Object> el = (Map<String, Object>) elObj;
                    if (String.valueOf(el.get('type')) == 'image') {
                        String elContentKey = String.valueOf(el.get('contentKey'));
                        // A missing/blank contentKey here is a real problem, but it's
                        // buildElementBlock's job to fail loud on it with a clear message --
                        // String.valueOf(null) is Apex null, not "null", so Pattern.matches
                        // against it throws an unhelpful NPE instead. Only validate the type of
                        // keys that are actually present and shaped like a contentKey.
                        if (String.isNotBlank(elContentKey) && Pattern.matches('^MC[A-Za-z0-9]{2,60}$', elContentKey)) {
                            imageKeysToValidate.add(elContentKey);
                        }
                    }
                }
                validateImageContentKeys(accessToken, imageKeysToValidate);

                Map<String, Object> blockIds = new Map<String, Object>();
                Map<String, Object> expressionsByKey = new Map<String, Object>();
                Boolean bodyBranding = req.includeBranding == null ? true : req.includeBranding;

                // Auto-section: every image/button becomes its own section (hero image, CTA),
                // consecutive heading/paragraph elements stay grouped in a shared text section --
                // a single flat section/column for the whole body was a known quality gap versus
                // a real multi-section layout (header/hero/CTA/footer).
                List<Object> bodySections = new List<Object>();
                List<Object> currentGroupChildren = new List<Object>();

                for (Object elObj : elements) {
                    Map<String, Object> el = (Map<String, Object>) elObj;
                    substituteMergePlaceholders(el, expressionsByKey);

                    // The drafted plan can't know which contentKey the banner will end up
                    // using -- confirmed live: a found brand's header image got drafted as a
                    // body element AND rendered again in the banner via the override, showing
                    // the same image twice. Drop any body image that duplicates whichever
                    // contentKey the banner is about to render, rather than relying on the
                    // drafting prompt to avoid it.
                    String elType = String.valueOf(el.get('type'));
                    if (bodyBranding && elType == 'image') {
                        String elContentKey = String.valueOf(el.get('contentKey'));
                        if ((String.isNotBlank(req.logoContentKeyOverride) && elContentKey == req.logoContentKeyOverride)
                            || (String.isNotBlank(req.headerContentKeyOverride) && elContentKey == req.headerContentKeyOverride)) {
                            continue;
                        }
                    }

                    String key = String.valueOf(el.get('key'));
                    String blockId = newBlockId();
                    Map<String, Object> builtBlock = buildElementBlock(blockId, el);
                    blockIds.put(key, blockId);

                    if (elType == 'image' || elType == 'button') {
                        if (!currentGroupChildren.isEmpty()) {
                            bodySections.add(sectionWithColumn(currentGroupChildren));
                            currentGroupChildren = new List<Object>();
                        }
                        bodySections.add(sectionWithColumn(new List<Object>{ builtBlock }));
                    } else {
                        currentGroupChildren.add(builtBlock);
                    }
                }
                if (!currentGroupChildren.isEmpty()) {
                    bodySections.add(sectionWithColumn(currentGroupChildren));
                }

                List<Object> topLevelSections = new List<Object>();
                Boolean branding = req.includeBranding == null ? true : req.includeBranding;

                if (branding) {
                    Boolean skipLogo = req.suppressLogo == true;
                    Boolean skipHeader = req.suppressHeader == true;
                    String logoKey = String.isNotBlank(req.logoContentKeyOverride) ? req.logoContentKeyOverride : config().LogoContentKey__c;
                    String headerKey = String.isNotBlank(req.headerContentKeyOverride) ? req.headerContentKeyOverride : config().HeaderContentKey__c;

                    if (!skipLogo) {
                    Map<String, Object> logoColumn = new Map<String, Object>{
                        'id' => newBlockId(), 'definition' => 'lightning/column', 'type' => 'block',
                        'attributes' => columnAttrs(12.0),
                        'children' => new List<Object>{ imageBlock(newBlockId(), logoKey, 'Company logo', 45.0, paddingMap(32.0, 16.0, 16.0, 16.0)) }
                    };
                    topLevelSections.add(new Map<String, Object>{
                        'id' => newBlockId(), 'definition' => 'lightning/section', 'type' => 'block',
                        'attributes' => sectionAttrs(), 'children' => new List<Object>{ logoColumn }
                    });
                    }

                    if (!skipHeader) {
                    Map<String, Object> headerColumn = new Map<String, Object>{
                        'id' => newBlockId(), 'definition' => 'lightning/column', 'type' => 'block',
                        'attributes' => columnAttrs(12.0),
                        'children' => new List<Object>{ imageBlock(newBlockId(), headerKey, 'Header banner', 100.0, paddingMap(0.0, 0.0, 16.0, 16.0)) }
                    };
                    topLevelSections.add(new Map<String, Object>{
                        'id' => newBlockId(), 'definition' => 'lightning/section', 'type' => 'block',
                        'attributes' => sectionAttrs(), 'children' => new List<Object>{ headerColumn }
                    });
                    }
                }

                topLevelSections.addAll(bodySections);

                if (branding) {
                    Map<String, Object> footerLinks = paragraphBlock(newBlockId(),
                        '{!$organization.Address} | Preference Manager | Unsubscribe');
                    ((Map<String, Object>) footerLinks.get('attributes')).put('align', 'center');
                    ((Map<String, Object>) footerLinks.get('attributes')).put('lightning:typography', '{!$brand.typography.paragraph.paragraph2}');
                    ((Map<String, Object>) footerLinks.get('attributes')).put('lightning:padding', new Map<String, Object>{
                        'top' => new Map<String, Object>{ 'unit' => 'px', 'value' => 32.0 },
                        'bottom' => new Map<String, Object>{ 'unit' => 'px', 'value' => 4.0 },
                        'left' => new Map<String, Object>{ 'unit' => 'px', 'value' => 16.0 },
                        'right' => new Map<String, Object>{ 'unit' => 'px', 'value' => 16.0 }
                    });

                    Map<String, Object> footerCopyright = paragraphBlock(newBlockId(),
                        '© ' + String.valueOf(Date.today().year()) + ' All rights reserved.');
                    ((Map<String, Object>) footerCopyright.get('attributes')).put('align', 'center');
                    ((Map<String, Object>) footerCopyright.get('attributes')).put('lightning:typography', '{!$brand.typography.paragraph.paragraph2}');
                    ((Map<String, Object>) footerCopyright.get('attributes')).put('lightning:padding', new Map<String, Object>{
                        'top' => new Map<String, Object>{ 'unit' => 'px', 'value' => 4.0 },
                        'bottom' => new Map<String, Object>{ 'unit' => 'px', 'value' => 32.0 },
                        'left' => new Map<String, Object>{ 'unit' => 'px', 'value' => 16.0 },
                        'right' => new Map<String, Object>{ 'unit' => 'px', 'value' => 16.0 }
                    });

                    Map<String, Object> footerColumn = new Map<String, Object>{
                        'id' => newBlockId(), 'definition' => 'lightning/column', 'type' => 'block',
                        'attributes' => columnAttrs(12.0),
                        'children' => new List<Object>{ footerLinks, footerCopyright }
                    };
                    topLevelSections.add(new Map<String, Object>{
                        'id' => newBlockId(), 'definition' => 'lightning/section', 'type' => 'block',
                        'attributes' => sectionAttrs(), 'children' => new List<Object>{ footerColumn }
                    });
                }

                Map<String, Object> block = new Map<String, Object>{
                    'id' => newBlockId(), 'definition' => 'sfdc_cms/rootContentBlock', 'type' => 'block',
                    'children' => topLevelSections
                };
                String decodedTitle = sanitizeText(req.title);
                String decodedSubjectLine = sanitizeText(req.subjectLine);
                String decodedPreheader = sanitizeText(req.preheader);

                Map<String, Object> contentBody = new Map<String, Object>{
                    'sfdc_cms:title' => decodedTitle,
                    'subjectLine' => decodedSubjectLine,
                    'messagePurpose' => 'promotional',
                    'preheader' => decodedPreheader,
                    'lightning:backgroundImage' => standardBackgroundImage(),
                    'lightning:brandSource' => String.isNotBlank(req.brandContentKeyOverride)
                        ? new Map<String, Object>{ 'contentKey' => req.brandContentKeyOverride }
                        : new Map<String, Object>{ 'defaultBrandOption' => 'sfdcBrand' },
                    'lightning:dataProviders' => expressionsByKey.isEmpty()
                        ? new List<Object>()
                        : new List<Object>{ dataGraphDataProvider(graphName, dataSpace) },
                    'lightning:expressions' => new List<Object>(expressionsByKey.values()),
                    'sfdc_cms:block' => block,
                    'sfdc_cms:operations' => new List<Object>(),
                    'sfdc_cms:variants' => new List<Object>()
                };
                // Confirmed live: the CMS Connect API's contents-create endpoint 400s with
                // "Length of actual parameter component exceeds declared length of object
                // component (18 vs 15)" when given the modern 18-char case-insensitive
                // ManagedContentSpace Id -- REST /query always returns the 18-char form, but
                // this specific endpoint wants the legacy 15-char case-sensitive form. Safe to
                // truncate: the first 15 chars ARE the real id, the trailing 3 are only a
                // case-insensitivity checksum. See [[feedback_sf_id_15_vs_18]].
                String spaceOrFolderId = req.contentSpaceOrFolderId;
                if (spaceOrFolderId != null && spaceOrFolderId.length() == 18) {
                    spaceOrFolderId = spaceOrFolderId.substring(0, 15);
                }
                Map<String, Object> createPayload = new Map<String, Object>{
                    'contentSpaceOrFolderId' => spaceOrFolderId,
                    'title' => decodedTitle,
                    'urlName' => req.urlName,
                    'contentType' => 'sfdc_cms__email',
                    'contentBody' => contentBody
                };

                HttpRequest createReq = new HttpRequest();
                createReq.setMethod('POST');
                createReq.setEndpoint(AuraPocTokenProvider.instanceUrl() + '/services/data/v66.0/connect/cms/contents');
                createReq.setHeader('Content-Type', 'application/json');
                createReq.setHeader('Authorization', 'Bearer ' + accessToken);
                createReq.setBody(JSON.serialize(createPayload));
                createReq.setTimeout(30000);
                HttpResponse createRes = new Http().send(createReq);

                if (createRes.getStatusCode() != 200 && createRes.getStatusCode() != 201) {
                    res.success = false;
                    res.errorMessage = 'Email creation failed: HTTP ' + createRes.getStatusCode() + ': ' + createRes.getBody();
                    results.add(res);
                    continue;
                }

                Map<String, Object> created = (Map<String, Object>) JSON.deserializeUntyped(createRes.getBody());
                Object keyObj = created.get('contentKey') != null ? created.get('contentKey') : created.get('id');
                res.contentKey = keyObj != null ? String.valueOf(keyObj) : null;
                managedContentId = created.get('managedContentId') != null ? String.valueOf(created.get('managedContentId')) : null;
                res.managedContentId = managedContentId;
                res.contentUrl = cmsContentUrl(managedContentId);
                res.blockIdsJson = JSON.serialize(blockIds);
                res.success = true;
                res.personalized = false;

                // Fetch the variant id now (needed for a reliable rollback path regardless of
                // where a later failure happens -- CMS content has no REST delete; the only
                // delete mechanism is Aura's ManagedContentController.deleteManagedContentVariant,
                // which needs the ManagedContentVariant id, not the ManagedContent id).
                HttpRequest getReq = new HttpRequest();
                getReq.setMethod('GET');
                getReq.setEndpoint(AuraPocTokenProvider.instanceUrl() + '/services/data/v66.0/connect/cms/contents/' + managedContentId);
                getReq.setHeader('Authorization', 'Bearer ' + accessToken);
                getReq.setTimeout(30000);
                HttpResponse getRes = new Http().send(getReq);
                if (getRes.getStatusCode() != 200) {
                    res.success = false;
                    res.errorMessage = 'Email created but could not be read back: HTTP ' + getRes.getStatusCode() + ': ' + getRes.getBody();
                    results.add(res);
                    continue;
                }
                Map<String, Object> content = (Map<String, Object>) JSON.deserializeUntyped(getRes.getBody());
                Map<String, Object> fetchedContentBody = (Map<String, Object>) content.get('contentBody');
                managedContentVariantId = String.valueOf(content.get('managedContentVariantId'));

                Boolean wantsPersonalization = String.isNotBlank(req.personalizationsJson);
                if (!wantsPersonalization) {
                    results.add(res);
                    continue;
                }

                List<Object> ppSpecs = (List<Object>) JSON.deserializeUntyped(AuraPocJson.stripFence(req.personalizationsJson));
                if (ppSpecs.isEmpty()) {
                    results.add(res);
                    continue;
                }
                if (ppSpecs.size() > MAX_PPS_PER_EMAIL) {
                    throw new WireException('personalizationsJson has ' + ppSpecs.size() + ' entries, but at most '
                        + MAX_PPS_PER_EMAIL + ' PersonalizationPoints are supported per email.');
                }

                // Resolve image-SWAP variant keys by role/name (never trust an LLM-typed variant
                // key), then existence-check them -- same guarantee as base image elements.
                Set<String> variantImgKeys = resolveVariantImageRefs(ppSpecs, req.assetsJson,
                    req.logoContentKeyOverride, req.headerContentKeyOverride);
                validateImageContentKeys(accessToken, variantImgKeys);

                // --- Step 2: personalize, in the same call. Any failure here rolls back Step 1. ---
                try {
                    wirePersonalizations(ppSpecs, accessToken, managedContentId, fetchedContentBody, managedContentVariantId, blockIds, dataSpace, graphName, res);
                } catch (Exception wireEx) {
                    Boolean rolledBack = deleteContent(managedContentVariantId, accessToken);
                    res.success = false;
                    res.personalized = false;
                    res.rolledBack = rolledBack;
                    res.errorMessage = 'Personalization failed' + (rolledBack ? ', created email was rolled back: ' : ' AND rollback delete also failed -- email may still exist: ')
                        + wireEx.getMessage();
                }
            } catch (Exception e) {
                if (managedContentVariantId != null) {
                    res.rolledBack = deleteContent(managedContentVariantId, accessToken);
                }
                res.success = false;
                res.errorMessage = e.getMessage();
            }
            results.add(res);
        }
        return results;
    }

    // A variant used to always be a text swap regardless of the target block's real type --
    // confirmed as a gap: an image/banner swap by region or industry needs its own imageInfo/
    // imageFitConfig, not a "text" attribute, or the variant PUT succeeds but preview breaks.
    // For an image target, textByDecision's value must be an object {contentKey, altText,
    // widthPercent} instead of a plain string.
    private static Map<String, Object> variantAttributesFor(String blockDefinition, Object decisionValue, Map<String, Object> expressionsByKey) {
        if (blockDefinition == 'lightning/image') {
            if (!(decisionValue instanceof Map<String, Object>)) {
                throw new WireException('Target block is lightning/image, so its textByDecision value must be '
                    + 'an object {"contentKey":"...","altText":"...","widthPercent":N} for each decision, not plain text.');
            }
            Map<String, Object> imageSpec = (Map<String, Object>) decisionValue;
            String contentKey = String.valueOf(imageSpec.get('contentKey'));
            if (String.isBlank(contentKey) || contentKey == 'null') {
                throw new WireException('Target block is lightning/image -- textByDecision value is missing "contentKey".');
            }
            return imageAttributes(contentKey, sanitizeText(String.valueOf(imageSpec.get('altText'))),
                asDecimal(imageSpec.get('widthPercent'), 100.0), paddingMap(8.0, 16.0, 24.0, 24.0));
        }
        String text = substituteMergePlaceholdersInText(String.valueOf(decisionValue), expressionsByKey);
        return new Map<String, Object>{ 'text' => sanitizeText(text) };
    }

    // One PersonalizationPoint per ppSpecs entry (one per independent axis) -- all combined into
    // a SINGLE final PUT, matching the marketing toolkit's own confirmed multi-PP shape
    // (docs/dynamic-content.md SS5.3): each PP gets its own sfdc_cms:operations entry (own
    // targetId, own personalizationPoint.name), but every PP's variants share ONE
    // sfdc_cms:variants array. The Aura session is minted once and reused across all PP creations.
    private static void wirePersonalizations(List<Object> ppSpecs, String accessToken, String managedContentId, Map<String, Object> contentBody,
            String variantRecordId, Map<String, Object> blockIds, String dataSpace, String graphName, Result res) {

        // Seed from whatever the main body already found (keyed by sfdcExpressionKey) so a
        // placeholder used in BOTH main body and variant text resolves to the same expression
        // entry, and so newly-found variant-only fields get merged back in below.
        Map<String, Object> expressionsByKey = new Map<String, Object>();
        List<Object> existingExpressions = (List<Object>) contentBody.get('lightning:expressions');
        if (existingExpressions != null) {
            for (Object exprObj : existingExpressions) {
                Map<String, Object> expr = (Map<String, Object>) exprObj;
                expressionsByKey.put(String.valueOf(expr.get('sfdcExpressionKey')), expr);
            }
        }

        AuraSessionMinter.Session sess = AuraSessionMinter.mint(accessToken, AuraPocTokenProvider.instanceUrl());
        String auraContextJson = JSON.serialize(new Map<String, Object>{
            'mode' => 'PROD', 'fwuid' => sess.fwuid, 'app' => sess.appName, 'loaded' => sess.loaded,
            'dn' => new List<Object>(), 'globals' => new Map<String, Object>(), 'uad' => true
        });

        List<Object> allOperations = new List<Object>();
        List<Object> allVariants = new List<Object>();
        List<Object> allVariantIdEntries = new List<Object>();
        List<String> createdPpNames = new List<String>();

        // Confirmed live: a plan with two PersonalizationPoints that both target the same
        // block (e.g. persona + tier "combination" copy on one paragraph) creates both PPs
        // successfully, then fails the final variant PUT with "duplicate targetId in the
        // operations array" -- CMS allows only one operation per block. Without this
        // try/catch, that failure rolled back the email (via the caller's deleteContent) but
        // left the two already-created PersonalizationPoint/PersonalizationDecision records
        // permanently orphaned in the org (SourceRecordId null, never wired to anything).
        // Wrap the whole build+wire loop so any failure cleans up every PP created so far.
        try {
            wirePersonalizationsInner(ppSpecs, sess, auraContextJson, expressionsByKey, blockIds,
                dataSpace, graphName, managedContentId, allOperations, allVariants, allVariantIdEntries, createdPpNames);

            contentBody.put('lightning:dataProviders', new List<Object>{ dataGraphDataProvider(graphName, dataSpace) });
            contentBody.put('sfdc_cms:operations', allOperations);
            contentBody.put('sfdc_cms:variants', allVariants);
            contentBody.put('lightning:expressions', new List<Object>(expressionsByKey.values()));

            HttpRequest putReq = new HttpRequest();
            putReq.setMethod('PUT');
            putReq.setEndpoint(AuraPocTokenProvider.instanceUrl() + '/services/data/v66.0/connect/cms/contents/variants/' + variantRecordId);
            putReq.setHeader('Content-Type', 'application/json');
            putReq.setHeader('Authorization', 'Bearer ' + accessToken);
            putReq.setBody(JSON.serialize(new Map<String, Object>{ 'contentBody' => contentBody }));
            putReq.setTimeout(30000);
            HttpResponse putRes = new Http().send(putReq);

            if (putRes.getStatusCode() != 200 && putRes.getStatusCode() != 204) {
                throw new WireException('Variant PUT failed: HTTP ' + putRes.getStatusCode() + ': ' + putRes.getBody());
            }
        } catch (Exception e) {
            for (String ppNameToClean : createdPpNames) {
                deletePersonalizationPointBestEffort(sess, auraContextJson, ppNameToClean);
            }
            throw e;
        }

        res.personalized = true;
        res.ppName = JSON.serialize(createdPpNames);
        res.variantIdsJson = JSON.serialize(allVariantIdEntries);
    }

    // Best-effort PersonalizationPoint delete, reusing the caller's already-minted Aura
    // session -- confirmed live via PersonalizationServiceController.deletePersonalizationPoint
    // ({"idOrName": <name or id>}), same controller/session pattern as deleteContent() below
    // uses for ManagedContentController. Never throws -- called only from rollback paths that
    // must not mask the original failure with a secondary cleanup error.
    private static Boolean deletePersonalizationPointBestEffort(AuraSessionMinter.Session sess, String auraContextJson, String ppName) {
        try {
            AuraServiceClient.CallResult delResult = AuraServiceClient.callAction(
                sess,
                'aura://PersonalizationServiceController/ACTION$deletePersonalizationPoint',
                'aura.PersonalizationService.deletePersonalizationPoint',
                auraContextJson, '/cmsAuthor/contentEditor.app', 1,
                new Map<String, Object>{ 'idOrName' => ppName }
            );
            return delResult.state == AuraServiceClient.CallState.SUCCESS;
        } catch (Exception ignored) {
            return false;
        }
    }

    // Original per-ppSpec build+create loop, unchanged in behavior -- extracted verbatim into
    // its own method so wirePersonalizations can wrap it in the try/catch above without
    // duplicating the loop body.
    private static void wirePersonalizationsInner(List<Object> ppSpecs, AuraSessionMinter.Session sess, String auraContextJson,
            Map<String, Object> expressionsByKey, Map<String, Object> blockIds, String dataSpace, String graphName, String managedContentId,
            List<Object> allOperations, List<Object> allVariants, List<Object> allVariantIdEntries, List<String> createdPpNames) {
        for (Object ppSpecObj : ppSpecs) {
            Map<String, Object> ppSpec = (Map<String, Object>) ppSpecObj;
            String rawPpName = String.valueOf(ppSpec.get('ppName'));
            String ppLabel = String.valueOf(ppSpec.get('ppLabel'));
            List<Object> decisionSpecs = (List<Object>) JSON.deserializeUntyped(String.valueOf(ppSpec.get('decisionsJson')));
            List<Object> targetSpecs = (List<Object>) JSON.deserializeUntyped(String.valueOf(ppSpec.get('targetsJson')));

            if (decisionSpecs.isEmpty()) {
                throw new WireException('PersonalizationPoint "' + ppLabel + '": decisionsJson must contain at least one decision.');
            }
            if (targetSpecs.isEmpty()) {
                throw new WireException('PersonalizationPoint "' + ppLabel + '": targetsJson must contain at least one target.');
            }
            if (decisionSpecs.size() > MAX_DECISIONS_PER_PP) {
                throw new WireException('PersonalizationPoint "' + ppLabel + '" has ' + decisionSpecs.size()
                    + ' decisions, but at most ' + MAX_DECISIONS_PER_PP + ' are supported per personalization point.');
            }

            String safePpName = uniquePpName(rawPpName);

            List<Object> ppDecisions = new List<Object>();
            Map<String, String> safeDecisionNameByRaw = new Map<String, String>();
            for (Object specObj : decisionSpecs) {
                Map<String, Object> spec = (Map<String, Object>) specObj;
                String rawName = String.valueOf(spec.get('name'));
                String safeName = sanitizeDeveloperName(rawName);
                safeDecisionNameByRaw.put(rawName, safeName);

                Map<String, Object> criteria = buildDecisionCriteria(spec);
                // Display label: append the decision's actual VALUE when the plan named every
                // decision on an axis the same (e.g. all "Recipient industry") -- the small planner
                // model sometimes collapses per-value names. Deterministic, so the rule reads
                // "Recipient industry - Healthcare" / "- Technology" in Builder, not four identical
                // "Recipient industry" rows. Presence (has_value) checks get no suffix.
                String dispLabel = decisionDisplayLabel(spec);
                ppDecisions.add(new Map<String, Object>{
                    'label' => dispLabel,
                    'name' => safeName,
                    'description' => dispLabel,
                    'personalizerName' => null,
                    'attributeValues' => new List<Object>{
                        new Map<String, Object>{ 'attributeEnum' => 'Variation', 'value' => safeName, 'attributeName' => null }
                    },
                    'criteria' => JSON.serialize(criteria)
                });
            }

            Map<String, Object> ppInput = new Map<String, Object>{
                'label' => ppLabel,
                'name' => safePpName,
                'dataSpaceName' => dataSpace,
                'profileDataGraphName' => graphName,
                'schemaEnum' => 'ExperienceVariation',
                'source' => 'BlockBuilder',
                'sourceRecordId' => managedContentId,
                'isAuthenticationRequired' => false,
                'decisions' => ppDecisions
            };

            AuraServiceClient.CallResult ppResult = AuraServiceClient.callAction(
                sess,
                'aura://PersonalizationServiceController/ACTION$createPersonalizationPoint',
                'aura.PersonalizationService.createPersonalizationPoint',
                auraContextJson, '/cmsAuthor/contentEditor.app', 1,
                new Map<String, Object>{ 'input' => ppInput }
            );

            if (ppResult.state != AuraServiceClient.CallState.SUCCESS) {
                throw new WireException('PersonalizationPoint "' + ppLabel + '" creation failed: ' + ppResult.state
                    + (ppResult.rawError != null ? ' :: ' + String.valueOf(ppResult.rawError) : ''));
            }
            createdPpNames.add(safePpName);

            for (Object targetObj : targetSpecs) {
                Map<String, Object> target = (Map<String, Object>) targetObj;
                String elementKey = String.valueOf(target.get('elementKey'));
                String tgtDef = target.get('blockDefinition') != null ? String.valueOf(target.get('blockDefinition')) : '';
                // The subject/preheader component has no block, so it is NOT in blockIds -- that's
                // expected, not an error. Every real block target must resolve to a block id.
                Boolean spComponent = (tgtDef == 'sfdc_cms__subjectPreheader' || elementKey == 'subject_preheader');
                if (!spComponent && !blockIds.containsKey(elementKey)) {
                    throw new WireException('targetsJson references unknown element key "' + elementKey
                        + '" -- must match a "key" from elementsJson.');
                }
                String blockDefinition = target.get('blockDefinition') != null
                    ? String.valueOf(target.get('blockDefinition')) : 'lightning/paragraph';
                Map<String, Object> textByDecision = (Map<String, Object>) target.get('textByDecision');
                // SUBJECT/PREHEADER component: personalizes email metadata, not a block, so there is no
                // block id to resolve, the variant body is {subjectLine, preheader}, and the operation
                // carries NO targetId (captured from a real UI example). Everything else (PP name,
                // decisionToVariantList) is identical to a block PP.
                Boolean isSubjectPreheader = (blockDefinition == 'sfdc_cms__subjectPreheader' || elementKey == 'subject_preheader');
                String targetBlockId = isSubjectPreheader ? null : String.valueOf(blockIds.get(elementKey));

                List<Object> decisionToVariantList = new List<Object>();
                for (Object specObj : decisionSpecs) {
                    Map<String, Object> spec = (Map<String, Object>) specObj;
                    // textByDecision keys match targetsJson's own literal decision names, authored
                    // in the same LLM turn as decisionsJson -- look up by the RAW name. Everything
                    // sent to the PP/variant API must use the SAME sanitized name actually
                    // registered on the PersonalizationPoint above, not the raw one.
                    String rawDecisionName = String.valueOf(spec.get('name'));
                    String safeDecisionName = safeDecisionNameByRaw.get(rawDecisionName);
                    if (!textByDecision.containsKey(rawDecisionName)) {
                        throw new WireException('PersonalizationPoint "' + ppLabel + '" target "' + elementKey
                            + '" is missing textByDecision entry for decision ' + rawDecisionName);
                    }

                    String variantUuid = newUuid();
                    decisionToVariantList.add(new Map<String, Object>{ 'decisionName' => safeDecisionName, 'variantId' => variantUuid });
                    allVariantIdEntries.add(new Map<String, Object>{
                        'ppName' => safePpName, 'elementKey' => elementKey, 'decisionName' => safeDecisionName, 'variantId' => variantUuid
                    });
                    Map<String, Object> variantBody;
                    if (isSubjectPreheader) {
                        // The variant body IS the subject/preheader override object {subjectLine, preheader}
                        // for this decision. A decision that doesn't apply carries an empty object -> keep
                        // the email's base subject/preheader (don't emit blank overrides).
                        Object dv = textByDecision.get(rawDecisionName);
                        Map<String, Object> sp = (dv instanceof Map<String, Object>) ? (Map<String, Object>) dv : new Map<String, Object>();
                        variantBody = new Map<String, Object>();
                        if (sp.get('subjectLine') != null) { variantBody.put('subjectLine', sp.get('subjectLine')); }
                        if (sp.get('preheader') != null) { variantBody.put('preheader', sp.get('preheader')); }
                    } else {
                        variantBody = new Map<String, Object>{
                            'sfdc_cms:block' => new Map<String, Object>{
                                'children' => new List<Object>{
                                    new Map<String, Object>{
                                        'attributes' => variantAttributesFor(blockDefinition, textByDecision.get(rawDecisionName), expressionsByKey),
                                        'id' => targetBlockId,
                                        'definition' => blockDefinition,
                                        'type' => 'block'
                                    }
                                }
                            }
                        };
                    }
                    allVariants.add(new Map<String, Object>{
                        'id' => variantUuid,
                        'name' => spec.get('label'),
                        'type' => 'personalization',
                        'body' => variantBody
                    });
                }

                Map<String, Object> op = new Map<String, Object>{
                    'attributes' => new Map<String, Object>{
                        'decisionToVariantList' => decisionToVariantList,
                        'personalizationPoint' => new Map<String, Object>{ 'dataspace' => dataSpace, 'name' => safePpName }
                    },
                    'definition' => 'sfdc_cms__pspVariantOperation'
                };
                // Block ops carry the target block UUID; the subject/preheader component op has NO
                // targetId (that absence is what marks it as the subject/preheader component target).
                if (!isSubjectPreheader) { op.put('targetId', targetBlockId); }
                allOperations.add(op);
            }
        }
    }

    // CMS content has no REST delete -- confirmed live (405 Method Not Allowed). The only
    // delete mechanism is Aura's ManagedContentController.deleteManagedContentVariant, keyed
    // by the ManagedContentVariant id. Returns true only if the delete actually succeeded --
    // callers must not assume rollback worked just because this was called.
    private static Boolean deleteContent(String variantId, String accessToken) {
        if (variantId == null || accessToken == null) {
            return false;
        }
        try {
            AuraSessionMinter.Session sess = AuraSessionMinter.mint(accessToken, AuraPocTokenProvider.instanceUrl());
            String auraContextJson = JSON.serialize(new Map<String, Object>{
                'mode' => 'PROD', 'fwuid' => sess.fwuid, 'app' => sess.appName, 'loaded' => sess.loaded,
                'dn' => new List<Object>(), 'globals' => new Map<String, Object>(), 'uad' => true
            });
            AuraServiceClient.CallResult delResult = AuraServiceClient.callAction(
                sess,
                'aura://ManagedContentController/ACTION$deleteManagedContentVariant',
                'aura.ManagedContent.deleteManagedContentVariant',
                auraContextJson, '/cmsAuthor/contentEditor.app', 1,
                new Map<String, Object>{ 'variantId' => variantId }
            );
            return delResult.state == AuraServiceClient.CallState.SUCCESS;
        } catch (Exception ignored) {
            return false;
        }
    }

    // LLM-authored text can't be trusted to emit plain characters instead of HTML entities
    // (e.g. "Bob&#39;s Store" instead of "Bob's Store"), which then renders as the literal
    // entity text in the email. Decode the common ones deterministically rather than relying
    // on prompt wording. &amp; must decode LAST or "&amp;lt;" would wrongly become "<".
    private static String decodeHtmlEntities(String s) {
        if (String.isBlank(s)) {
            return s;
        }
        return s
            .replace('&#39;', '\'')
            .replace('&apos;', '\'')
            .replace('&quot;', '"')
            .replace('&lt;', '<')
            .replace('&gt;', '>')
            .replace('&nbsp;', ' ')
            .replace('&amp;', '&');
    }

    // Straight quotes in body text double-encode and break DC preview (error -1530776632) --
    // only curly quotes are safe. LLMs default to straight quotes, so convert deterministically.
    // Apostrophes are always the closing/right form (contractions, possessives -- an opening
    // single-quote is rare enough in marketing copy not to special-case). Double quotes alternate
    // open/close per occurrence, which handles well-formed quoted phrases correctly.
    private static String curlyQuotes(String s) {
        if (String.isBlank(s)) {
            return s;
        }
        String result = s.replace('\'', '’');
        String out = '';
        Boolean openDouble = true;
        for (Integer i = 0; i < result.length(); i++) {
            String c = result.substring(i, i + 1);
            if (c == '"') {
                out += openDouble ? '“' : '”';
                openDouble = !openDouble;
            } else {
                out += c;
            }
        }
        return out;
    }

    private static String sanitizeText(String s) {
        return curlyQuotes(decodeHtmlEntities(s));
    }

    // PersonalizationPoint/decision names are DeveloperName-style and reject consecutive
    // underscores -- confirmed live: "ssot__StateProvinceId__c" used verbatim as ppName was
    // rejected as invalid characters, while "ssot_FirstName_c" (single underscores) was
    // accepted. LLM-authored names derived from field API names can't be trusted to avoid
    // this, so collapse/strip deterministically here rather than relying on prompt wording.
    private static String sanitizeDeveloperName(String raw) {
        String cleaned = String.isBlank(raw) ? '' : raw.replaceAll('[^A-Za-z0-9_]', '_');
        cleaned = cleaned.replaceAll('_+', '_');
        while (cleaned.startsWith('_')) {
            cleaned = cleaned.substring(1);
        }
        while (cleaned.endsWith('_')) {
            cleaned = cleaned.substring(0, cleaned.length() - 1);
        }
        if (String.isBlank(cleaned)) {
            return 'PP_Unnamed';
        }
        if (!cleaned.substring(0, 1).isAlpha()) {
            cleaned = 'PP_' + cleaned;
        }
        return cleaned;
    }

    private static String newUuid() {
        Blob b = Crypto.generateAesKey(128);
        String hex = EncodingUtil.convertToHex(b);
        return hex.substring(0, 8) + '-' + hex.substring(8, 12) + '-' + hex.substring(12, 16)
            + '-' + hex.substring(16, 20) + '-' + hex.substring(20, 32);
    }

    // PersonalizationPoint names must be unique within a data space -- confirmed live that a
    // sanitized-but-plausible name (e.g. reused across separate builds) collided with one
    // already in the org ("Please check all PersonalizationPoint names are unique..."). Every
    // call creates a brand-new email content item regardless, so there's no reason two builds
    // should ever need the same PP name -- append a short unique suffix deterministically
    // rather than trusting the LLM to invent a name that happens to never collide.
    private static String uniquePpName(String rawPpName) {
        String base = sanitizeDeveloperName(rawPpName);
        if (base.length() > 32) {
            base = base.substring(0, 32);
        }
        Blob b = Crypto.generateAesKey(128);
        String suffix = EncodingUtil.convertToHex(b).substring(0, 6);
        return base + '_' + suffix;
    }

    // ===== Shared with UpdateDynamicEmailAction (separate class -- Apex allows only one =====
    // ===== @InvocableMethod per class, so the update action lives on its own and calls =====
    // ===== these). =====
    public static AuraPocTokenSource sharedTokenSource() { return tokenSource; }
    // Test/diagnostic hook for the merge-placeholder substitution: converts supported {{Field}} to
    // {!$Expression.Field} and degrades unsupported fields to their default text (no throw).
    public static String sharedSubstituteMergePlaceholders(String text) {
        return substituteMergePlaceholdersInText(text, new Map<String, Object>());
    }
    // Direct link to the built/updated email RECORD -- opens the specific ManagedContent, not the
    // workspace list. managedContentId is the 20Y... record id the create/GET returns. Uses the
    // lightning domain (instance URL is .my.salesforce.com; the record route needs .lightning.force.com).
    public static String cmsContentUrl(String managedContentId) {
        if (String.isBlank(managedContentId)) { return ''; }
        String host = AuraPocTokenProvider.instanceUrl().replace('.my.salesforce.com', '.lightning.force.com');
        return host + '/lightning/r/ManagedContent/' + managedContentId + '/view';
    }
    public static Map<String, Object> sharedDataGraphDataProvider(String graphName, String dataSpace) {
        return dataGraphDataProvider(graphName, dataSpace);
    }
    public static Boolean sharedDeletePp(AuraSessionMinter.Session sess, String auraContextJson, String ppName) {
        return deletePersonalizationPointBestEffort(sess, auraContextJson, ppName);
    }
    public static Set<String> sharedResolveVariantImageRefs(List<Object> ppSpecs, String assetsJson,
            String logoKey, String headerKey) {
        return resolveVariantImageRefs(ppSpecs, assetsJson, logoKey, headerKey);
    }
    public static void sharedValidateImageContentKeys(String accessToken, Set<String> keys) {
        validateImageContentKeys(accessToken, keys);
    }
    public static void sharedWirePersonalizationsInner(List<Object> ppSpecs, AuraSessionMinter.Session sess,
            String auraContextJson, Map<String, Object> expressionsByKey, Map<String, Object> blockIds,
            String dataSpace, String graphName, String managedContentId, List<Object> allOperations,
            List<Object> allVariants, List<Object> allVariantIdEntries, List<String> createdPpNames) {
        wirePersonalizationsInner(ppSpecs, sess, auraContextJson, expressionsByKey, blockIds, dataSpace,
            graphName, managedContentId, allOperations, allVariants, allVariantIdEntries, createdPpNames);
    }
}
