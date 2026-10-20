// Derives PersonalizationPoint relationship topology (expression-group chains for merge-field
// DISPLAY, and criteria relationship PATHS for decisions) from a Data Cloud data graph's ACTUAL
// shape, instead of the hardcoded SIC2025 assumptions that used to live in BuildDynamicEmailAction.
//
// WHY: the old builders assumed a fixed graph (root IndividualIdentityLink__dlm -> ssot__Individual__dlm
// with name fields on ssot__Individual__dlm). A different org's graph (e.g. BloombergDemo2026, whose
// graph roots at UnifiedIndividual__dlm and carries FirstName ON the root, with ssot__Individual__dlm
// holding only identity keys) made every personalization build fail with
//   INVALID_API_INPUT: field '{!group1.ssot__FirstName__c}' isn't supported in '{!group0.ssot__Individual__dlm}'
// because the hardcoded chain pointed at a DMO that doesn't carry the field in that graph.
//
// This class reads the raw Connect-API payload (GET /ssot/data-graphs/<name>) and derives the chains
// from each node's `projectedName` (real DMO), `jsonPath` (dotted hop chain from the graph root), and
// `fields[].isKeyColumn` (the orderBy key). Pure + callout-free so it unit-tests from anon Apex.
//
// SELECTION POLICY (load-bearing -- see the SIC2025 regression gate): a field api name can live on
// MULTIPLE DMOs in one graph (on SIC2025 ssot__FirstName__c is on BOTH the root UnifiedIndividual__dlm
// AND the deep ssot__Individual__dlm). The existing hardcoded chain used the DEEP identity-branch
// occurrence. selectNodeForField() reproduces that: prefer the occurrence whose jsonPath passes through
// IndividualIdentityLink__dlm -> ssot__Individual__dlm; else fall back to the shallowest occurrence
// (the root on Bloomberg). This both reproduces SIC2025 byte-for-byte AND fixes Bloomberg.
public with sharing class DataGraphTopology {

    public class TopologyException extends Exception {}

    // One graph node, keyed by its real DMO api name (projectedName).
    public class Node {
        public String dmo;            // projectedName (real DMO api name)
        public String jsonPath;       // e.g. "$.IndividualIdentityLink__dlm.ssot__Individual__dlm"
        public List<String> pathDmos; // jsonPath split into the ordered DMO chain from the graph root (excl. "$")
        public String keyField;       // first isKeyColumn field, else ssot__Id__c, else SourceRecordId__c, else null
        public Set<String> fieldApiNames = new Set<String>();
    }

    public String rootDmo;                                  // = primaryObjectName
    public List<Node> nodes = new List<Node>();             // every node, flattened (preserves duplicates)
    public Map<String, List<Node>> nodesByField = new Map<String, List<Node>>(); // fieldApiName -> nodes carrying it

    // ---- parse ---------------------------------------------------------------------------------

    // Build a Topology from the deserialized Connect-API body. Returns null if the body is unusable
    // (caller degrades to a plain email).
    public static DataGraphTopology parse(Map<String, Object> rawBody) {
        if (rawBody == null) { return null; }
        Object so = rawBody.get('sourceObject');
        if (!(so instanceof Map<String, Object>)) { return null; }
        DataGraphTopology t = new DataGraphTopology();
        t.rootDmo = String.valueOf(rawBody.get('primaryObjectName'));
        t.walk((Map<String, Object>) so);
        return t;
    }

    private void walk(Map<String, Object> nodeMap) {
        if (nodeMap == null) { return; }
        Node n = new Node();
        n.dmo = String.valueOf(nodeMap.get('projectedName'));
        n.jsonPath = String.valueOf(nodeMap.get('jsonPath'));
        n.pathDmos = pathDmosOf(n.jsonPath);
        List<Object> fields = (List<Object>) nodeMap.get('fields');
        String firstKey = null;
        String ssotId = null;
        String sourceRecId = null;
        if (fields != null) {
            for (Object fo : fields) {
                Map<String, Object> f = (Map<String, Object>) fo;
                String api = String.valueOf(f.get('sourceFieldName'));
                n.fieldApiNames.add(api);
                if (!nodesByField.containsKey(api)) { nodesByField.put(api, new List<Node>()); }
                nodesByField.get(api).add(n);
                Object isKey = f.get('isKeyColumn');
                if (firstKey == null && isKey == true) { firstKey = api; }
                if (api == 'ssot__Id__c') { ssotId = api; }
                if (api == 'SourceRecordId__c') { sourceRecId = api; }
            }
        }
        n.keyField = firstKey != null ? firstKey : (ssotId != null ? ssotId : sourceRecId);
        nodes.add(n);

        List<Object> related = (List<Object>) nodeMap.get('relatedObjects');
        if (related != null) {
            for (Object ro : related) {
                walk((Map<String, Object>) ro);
            }
        }
    }

    // "$.A__dlm.B__dlm" -> [A__dlm, B__dlm]; "$" -> []  (the root node's own DMO is NOT in jsonPath;
    // for a non-root node the LAST element of pathDmos equals that node's own DMO).
    private static List<String> pathDmosOf(String jsonPath) {
        List<String> out = new List<String>();
        if (String.isBlank(jsonPath) || jsonPath == '$') { return out; }
        for (String seg : jsonPath.split('\\.')) {
            if (seg != '$' && String.isNotBlank(seg)) { out.add(seg); }
        }
        return out;
    }

    // ---- selection policy ----------------------------------------------------------------------

    public Node selectNodeForField(String fieldApiName) {
        return selectNodeForField(fieldApiName, null);
    }

    // Choose which occurrence of a field to personalize against. A field api name can be ambiguous
    // (e.g. ssot__Name__c lives on BOTH ssot__Account__dlm and ssot__Campaign__dlm; ssot__FirstName__c
    // on both the root and the deep identity branch), so an optional preferredDmo disambiguates --
    // the friendly-name table in Build supplies it (AccountName -> ssot__Account__dlm). Priority:
    //   1. preferredDmo, when the field actually exists on that DMO (deterministic, caller-driven);
    //   2. the occurrence descending through IndividualIdentityLink__dlm -> ssot__Individual__dlm
    //      (the legacy hardcoded deep-branch choice -- reproduces SIC2025 byte-for-byte);
    //   3. the shallowest occurrence (the root wins on Bloomberg, where that is the only one).
    // Throws (fail-loud) when the field is absent from the whole graph.
    public Node selectNodeForField(String fieldApiName, String preferredDmo) {
        List<Node> candidates = nodesByField.get(fieldApiName);
        if (candidates == null || candidates.isEmpty()) {
            throw new TopologyException('Field "' + fieldApiName + '" is not present in data graph '
                + '(root ' + rootDmo + ') -- personalization on this field is unsupported on this org\'s graph.');
        }
        // 1. explicit DMO hint — DISAMBIGUATION ONLY. The hint (e.g. the Recipient
        // scope's hard-coded 'UnifiedIndividual__dlm') is a preference among valid
        // candidates, NOT a hard requirement. When the hint names a node that does
        // not carry this field in THIS org's graph (e.g. graphs rooted at
        // 'UnifiedssotIndividualColl__dlm', where ssot__FirstName__c lives on the
        // root, not UnifiedIndividual__dlm), fall through to the identity/shallowest
        // selection below instead of failing loud — the field demonstrably exists in
        // the graph, just on a different node.
        if (String.isNotBlank(preferredDmo)) {
            for (Node n : candidates) {
                if (n.dmo == preferredDmo) { return n; }
            }
            System.debug('DataGraphTopology: hint DMO "' + preferredDmo + '" does not carry "'
                + fieldApiName + '" in graph (root ' + rootDmo + '); it is on ' + dmosOf(candidates)
                + ' — falling back to identity/shallowest selection.');
        }
        // 2. identity-branch pick (longest chain through the identity link)
        Node identityPick = null;
        for (Node n : candidates) {
            if (n.pathDmos.contains('IndividualIdentityLink__dlm') && n.pathDmos.contains('ssot__Individual__dlm')) {
                if (identityPick == null || n.pathDmos.size() > identityPick.pathDmos.size()) {
                    identityPick = n;
                }
            }
        }
        if (identityPick != null) { return identityPick; }
        // 3. shallowest occurrence
        Node shallow = candidates[0];
        for (Node n : candidates) {
            if (n.pathDmos.size() < shallow.pathDmos.size()) { shallow = n; }
        }
        return shallow;
    }

    private static String dmosOf(List<Node> ns) {
        List<String> out = new List<String>();
        for (Node n : ns) { out.add(n.dmo); }
        return String.join(out, ', ');
    }

    public Node nodeForDmo(String dmo) {
        for (Node n : nodes) {
            if (n.dmo == dmo) { return n; }
        }
        return null;
    }

    // ---- SYSTEM B: decision-criteria relationship path -----------------------------------------

    // The ordered list of pathHop(parent,child) for the chosen field's DMO chain, as consumed by
    // buildDecisionCriteria's NumberAggregation path. Empty list when the field lives on the graph
    // root (bare comparison, no aggregation). The chain is root -> ... -> targetDmo, where root is the
    // graph's primaryObjectName and the hops follow the chosen node's jsonPath.
    public List<Object> criteriaPathForField(String fieldApiName) {
        return criteriaPathForField(fieldApiName, null);
    }
    public List<Object> criteriaPathForField(String fieldApiName, String preferredDmo) {
        Node target = selectNodeForField(fieldApiName, preferredDmo);
        List<String> chain = fullChain(target);          // [rootDmo, ...hops..., targetDmo]
        List<Object> path = new List<Object>();
        for (Integer i = 1; i < chain.size(); i++) {
            path.add(pathHop(chain[i - 1], chain[i]));
        }
        return path;
    }

    // True when the field personalizes against the graph root (no aggregation needed).
    public Boolean fieldIsOnRoot(String fieldApiName) {
        return fieldIsOnRoot(fieldApiName, null);
    }
    public Boolean fieldIsOnRoot(String fieldApiName, String preferredDmo) {
        return fullChain(selectNodeForField(fieldApiName, preferredDmo)).size() == 1;
    }

    public String dmoForField(String fieldApiName) {
        return selectNodeForField(fieldApiName, null).dmo;
    }
    public String dmoForField(String fieldApiName, String preferredDmo) {
        return selectNodeForField(fieldApiName, preferredDmo).dmo;
    }

    // Full DMO chain from the graph root to (and including) the target node, using its jsonPath.
    // Root node (jsonPath "$") -> [rootDmo]. Non-root -> [rootDmo] + pathDmos.
    private List<String> fullChain(Node target) {
        List<String> chain = new List<String>{ rootDmo };
        for (String d : target.pathDmos) {
            chain.add(d);
        }
        return chain;
    }

    // ---- SYSTEM A: merge-field display expression-group chain ----------------------------------

    // Reproduces the legacy expressionGroupsFor output but derived from the graph. The legacy chain
    // was anchored at IndividualIdentityLink__dlm (the identity-link node), NOT the graph root -- so
    // we anchor group0 at the FIRST DMO of the chosen field's identity sub-chain and descend from
    // there. For a root-only field (Bloomberg FirstName) the anchor IS the root.
    //
    // Group shapes (matching the legacy quirk): group0 = rule group (orderBy = anchor's key field);
    // the FIRST hop after the anchor = hop group (no sort); every deeper hop = rule group (orderBy =
    // that DMO's key field); terminal leaf = leaf group pointing at the field.
    public List<Object> expressionGroupsForField(String fieldApiName) {
        return expressionGroupsForField(fieldApiName, null);
    }
    public List<Object> expressionGroupsForField(String fieldApiName, String preferredDmo) {
        Node target = selectNodeForField(fieldApiName, preferredDmo);
        List<String> anchorChain = expressionAnchorChain(target); // [anchorDmo, ...hops..., targetDmo]

        // ROOT-FIELD CASE (field lives ON the graph's primary DMO, e.g. Bloomberg ssot__FirstName__c on
        // UnifiedIndividual__dlm, with no IndividualIdentityLink hop in its chain -> anchorChain == [root]).
        // The CMS REJECTS anchoring a group at the primary DMO ({!$dataGraph.<primaryDMO>} -> HTTP 400
        // "field isn't supported in '$dataGraph'"). A root field is addressed DIRECTLY off $dataGraph as a
        // single leaf group with no DMO hop. PROVEN on a throwaway BloombergDemo2026 build 2026-10-02:
        // {!$dataGraph.ssot__FirstName__c} wires + builds + rolls back clean; the group-anchored form 400s.
        // (SIC2025's FirstName descends the identity branch -> anchorChain.size() > 1 -> this never fires
        // there, so the SIC2025 byte-diff regression is unaffected.)
        if (anchorChain.size() == 1) {
            return new List<Object>{ exprLeafGroup('group0', '{!$dataGraph.' + fieldApiName + '}') };
        }

        List<Object> groups = new List<Object>();

        // group0 -- rule group anchored at the data graph resource for anchorChain[0].
        String anchorDmo = anchorChain[0];
        groups.add(exprRuleGroup('group0', '{!$dataGraph.' + anchorDmo + '}', orderByFor(anchorDmo)));

        // intermediate hops: anchorChain[1 .. n-1]
        for (Integer i = 1; i < anchorChain.size(); i++) {
            String dmo = anchorChain[i];
            String resource = '{!group' + (i - 1) + '.' + dmo + '}';
            if (i == 1) {
                // first non-anchor hop: hop group (no sort), matching legacy group1
                groups.add(exprHopGroup('group' + i, resource));
            } else {
                groups.add(exprRuleGroup('group' + i, resource, orderByFor(dmo)));
            }
        }

        // leaf group: field under the last group.
        Integer leafIdx = anchorChain.size();
        String leafResource = '{!group' + (leafIdx - 1) + '.' + fieldApiName + '}';
        groups.add(exprLeafGroup('group' + leafIdx, leafResource));
        return groups;
    }

    // The chain used for EXPRESSION groups. The legacy chain started at IndividualIdentityLink__dlm
    // (not the graph root UnifiedIndividual__dlm). So if the chosen target descends through
    // IndividualIdentityLink__dlm, anchor there and keep only the sub-chain from it to the target.
    // Otherwise (root-only field, e.g. Bloomberg) anchor at the graph root.
    private List<String> expressionAnchorChain(Node target) {
        List<String> full = fullChain(target);  // [rootDmo, ..., targetDmo]
        Integer anchorAt = full.indexOf('IndividualIdentityLink__dlm');
        if (anchorAt < 0) {
            // No identity link in the chain -> anchor at the graph root (Bloomberg root field => [root]).
            return full;
        }
        List<String> sub = new List<String>();
        for (Integer i = anchorAt; i < full.size(); i++) {
            sub.add(full[i]);
        }
        return sub;
    }

    public String orderByFor(String dmo) {
        Node n = nodeForDmo(dmo);
        if (n != null && String.isNotBlank(n.keyField)) {
            return n.keyField;
        }
        // Should not happen on a well-formed graph; fail loud rather than emit a bad orderBy.
        throw new TopologyException('No key/order-by field discoverable for DMO "' + dmo
            + '" in the data graph -- cannot build a sortable expression group.');
    }

    // ---- shared group/path builders (moved here so legacy + derived share one definition) -------

    public static Map<String, Object> exprRuleGroup(String name, String resource, String orderBy) {
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

    public static Map<String, Object> exprHopGroup(String name, String resource) {
        return new Map<String, Object>{ 'name' => name, 'resource' => resource };
    }

    public static Map<String, Object> exprLeafGroup(String name, String resource) {
        return new Map<String, Object>{ 'name' => name, 'resource' => resource, 'selectionIndex' => 0.0 };
    }

    public static List<Object> pathHop(String fromObj, String toObj) {
        return new List<Object>{
            new Map<String, Object>{ 'objectApiName' => fromObj },
            new Map<String, Object>{ 'objectApiName' => toObj }
        };
    }
}
