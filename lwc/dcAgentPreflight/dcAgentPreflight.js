/**
 * Dynamic Content Agent — read-only CMS-editor companion (mirrors Email Preflight's shape).
 * Appears in the MC Next / CMS email builder via lightning__CmsEditorExtension. Reads the open
 * content IN-FRAME via experience/cmsEditorApi, and reads the dynamic content (PersonalizationPoints)
 * via the lightning/uiGraphQLApi wire — both callout-free and JWT-free (a server-side self-callout
 * with getSessionId() is blocked from the Lightning session, so GraphQL is the working path, exactly
 * as EP resolves ManagedContent). Config/health/models use cacheable Apex; the full auth test
 * delegates to the server-side JWT diagnostic. READ-ONLY throughout.
 */
import { LightningElement, track, wire } from 'lwc';
import { getContent, getContext } from 'experience/cmsEditorApi';
import { gql, graphql, refreshGraphQL } from 'lightning/uiGraphQLApi';
import getConfigStatus from '@salesforce/apex/DcPreflightController.getConfigStatus';
import getEnvHealth from '@salesforce/apex/DcPreflightController.getEnvHealth';
import getImageCatalogHealth from '@salesforce/apex/DcPreflightController.getImageCatalogHealth';
import getWorkspaces from '@salesforce/apex/DcPreflightController.getWorkspaces';
import runFullTest from '@salesforce/apex/DcPreflightController.runFullTest';
import getModels from '@salesforce/apex/DcPreflightController.getModels';
import previewPlan from '@salesforce/apex/DcPreflightController.previewPlan';
// NOTE: "open the agent" from the panel is NOT possible in the CmsEditorExtension frame.
// Probed live (2026-09-29): lightning/platformUtilityBarApi's openUtility is not a function and
// embeddedservice_bootstrap is not present in this sandboxed editor iframe — neither official
// launch API is reachable here. The copy-key/prompt bridge stays the way to hand off to the agent.

// Setup deep-link paths (appended to the org base URL from getConfigStatus).
const SETUP_PATHS = {
    eca:     '/lightning/setup/ExternalClientAppsManager/home',
    cert:    '/lightning/setup/CertificatesAndKeysManagement/home',
    cmdt:    '/lightning/setup/CustomMetadata/home',
    rss:     '/lightning/setup/SecurityRemoteProxy/home',
    agents:  '/lightning/setup/EinsteinCopilot/home'   // Agentforce Agents — publish/activate + Agent Access
};

export default class DcAgentPreflight extends LightningElement {
    @track contentKey;
    @track contentId;
    @track contentTypeFqn;
    @track pps = [];
    @track config;
    @track envHealth;
    @track imageHealth;   // image-catalog readiness row (own probe; appended to envHealthRows)
    @track slotRoles = [];   // per-slot role readout (logo/image/text/footer) from the in-frame body
    @track models;
    @track ciTotal = 0;
    @track ciScoring = false;
    @track ciLoaded = false;
    @track brandCount = 0;
    @track brands = [];
    @track brandsLoaded = false;
    @track workspaces = [];
    @track selectedBrand;
    @track selectedWorkspace;
    @track showSetupSteps = false;   // user override to reveal steps after they're green
    @track showTestDetails = false;  // full-test diagnostic collapsed by default after a run
    @track testRanAt;                // timestamp of the last full-test run
    @track testResult;
    @track loading = false;
    @track error;
    @track ppVars;            // reactive GraphQL variables; undefined suppresses the wire
    @track assetVars;         // reactive vars for the asset (image/brand) name+type lookup
    @track imageKeys = [];
    @track brandKey;
    @track assetsByKey = {};  // contentKey -> { name, type }
    @track dcStructure = { byPp: {}, variantById: {}, targetLabelById: {} };  // parsed in-frame ops/variants
    @track showPps = true;    // Personalization Points section collapsible (default expanded)
    @track showSlotRoles = true;   // Slot roles section collapsible (default expanded)
    // Plan preview (Feature 3): dry-run a candidate axis through Read->Assemble->Validate (no write).
    @track showPreview = false;
    @track previewSlots = '';
    @track previewField = '';
    @track previewValues = '';
    @track previewResult = null;
    @track previewRunning = false;
    gotContent = false;
    currentContent;
    currentContext;

    // In-frame: the editor hands us the open content. We only need its record id (SourceRecordId of
    // the PPs) to drive the GraphQL read below.
    @wire(getContent)
    wiredContent({ data, error }) {
        if (error) { this.error = 'Could not read the editor content.'; return; }
        if (!data) { return; }
        this.gotContent = true;
        this.currentContent = data;
        this.contentKey = data.contentKey || data.key || (data.body && data.body.contentKey) || this.contentKey;
        this.contentId = data.managedContentId || data.id || data.contentId || this.contentId;
        // Extract the asset keys wired into this email — image blocks + the brand source — so we can
        // resolve each to a name/type/thumbnail below. All in-frame, no callout.
        const body = data.body || data.contentBody || data;
        this.imageKeys = this._collectImageKeys(body);
        this.brandKey = this._brandKey(body);
        // Parse the DC decision structure (ops → decisions → variants) straight from the in-frame
        // body — same shape ReadDynamicEmailAction reads server-side, but no callout needed since the
        // editor already handed us the full body. Feeds the decision-table preview below.
        this.dcStructure = this._parseDcStructure(body);
        this.slotRoles = this._classifySlots(body);   // read-only "slot roles" readout (logo/image/text/footer)
        // NOTE: change-detection baseline is NOT taken from the body here. The body's op-vs-PP unit
        // (sfdc_cms:operations is one per slot, and the in-frame op may not even carry a reliable PP
        // name) never lines up with the GraphQL wire's PP count, so any body-derived baseline gave a
        // false compare and the "Reload editor" prompt never fired. Instead the baseline is captured
        // from the FIRST GraphQL wire result itself (see wiredPps / _ppBaseline) -- baseline and signal
        // then come from the identical query, so a later poll that returns MORE PPs is a real change.
        this._updateAssetVars();
        this._updatePpVars();
    }

    // Parse the personalization structure from the in-frame content body into a PP-keyed map of
    // ops, each op carrying its target block + decision→variant rows. Mirrors the toolkit's
    // dc_structure.html topology (Template → PP → Op → decision rows) and ReadDynamicEmailAction's
    // server-side walk. Returns { byPp: { <ppDevName>: [ops] }, variantById: {id: {name}}, targetLabelById }.
    _parseDcStructure(body) {
        const empty = { byPp: {}, variantById: {}, targetLabelById: {} };
        if (!body || typeof body !== 'object') { return empty; }
        const ops = Array.isArray(body['sfdc_cms:operations']) ? body['sfdc_cms:operations'] : [];
        const variants = Array.isArray(body['sfdc_cms:variants']) ? body['sfdc_cms:variants'] : [];

        // Variant id → a readable name (falls back to the id). Variants are the swap payloads.
        const variantById = {};
        variants.forEach((v) => {
            if (v && v.id) { variantById[v.id] = { id: v.id, name: v.name || v.label || v.id }; }
        });

        // Block id → a human label (definition + any leading text) so an op's target reads as
        // "swaps Heading: Welcome…" rather than a raw id. Also block id → SLOT number, numbered in
        // the SAME document order as the slot-roles readout (content blocks only), so an op can show
        // which slot it targets. Walk the block tree once, in children order.
        const targetLabelById = {};
        const slotByBlockId = {};
        const CONTENT = ['lightning/heading', 'lightning/paragraph', 'lightning/image', 'lightning/actionButton'];
        let slotCounter = 0;
        const labelBlocks = (n) => {
            if (Array.isArray(n)) { n.forEach(labelBlocks); return; }
            if (!n || typeof n !== 'object') { return; }
            if (n.type === 'block' && n.id && n.definition) {
                const def = String(n.definition).replace(/^lightning\//, '');
                const attrs = n.attributes || {};
                let txt = '';
                if (typeof attrs.text === 'string') {
                    txt = attrs.text.replace(/<[^>]*>/g, '').trim();
                    if (txt.length > 32) { txt = txt.slice(0, 32) + '…'; }
                }
                const cap = def.charAt(0).toUpperCase() + def.slice(1);
                targetLabelById[n.id] = txt ? cap + ': ' + txt : cap;
                if (CONTENT.includes(n.definition)) { slotCounter += 1; slotByBlockId[n.id] = slotCounter; }
            }
            // Descend into children in document order so slot numbers line up with the slot-roles readout.
            if (Array.isArray(n.children)) { n.children.forEach(labelBlocks); }
        };
        labelBlocks(body['sfdc_cms:block']);

        // Group ops by their PersonalizationPoint name. The op shape (verified live, SIC2025):
        //   attributes.personalizationPoint = { name, dataspace }
        //   attributes.decisionToVariantList = [ { variantId, decisionName } ]
        // The PP `name` matches the GraphQL DeveloperName, so ppTree can join the two. The decision
        // RULE (field=value) is NOT in the body — it lives org-side on the PP's decisions — so an
        // in-frame row shows decisionName → variantName only; ppTree fills the rule when GraphQL
        // (or a future org read) provides it.
        const byPp = {};
        ops.forEach((op, i) => {
            if (!op || typeof op !== 'object') { return; }
            const attrs = op.attributes || {};
            const pp = attrs.personalizationPoint || {};
            const ppName = pp.name || pp.developerName || pp.DeveloperName || '(unknown PP)';
            const targetId = op.targetId || op.target || '';
            const slotNum = slotByBlockId[targetId];
            const entry = {
                index: i + 1,
                targetId,
                slot: slotNum || null,
                slotLabel: slotNum ? 'slot ' + slotNum : (targetId ? '' : 'subject+preheader'),
                targetLabel: targetLabelById[targetId] || 'block',
                targetIdShort: targetId ? String(targetId).slice(0, 8) + '…' : '—',
                rows: this._decisionRows(attrs, variantById)
            };
            (byPp[ppName] = byPp[ppName] || []).push(entry);
        });

        return { byPp, variantById, targetLabelById };
    }

    // Decision→variant rows for one op, from its decisionToVariantList (the live shape). Each row:
    // { decisionName, variantName }. The rule (field=value) isn't carried in the body, so it's left
    // for ppTree to backfill from the PP header when available.
    _decisionRows(attrs, variantById) {
        const vName = (id) =>
            (variantById[id] && variantById[id].name) || (id ? String(id).slice(0, 8) + '…' : '(default)');
        const list = Array.isArray(attrs.decisionToVariantList) ? attrs.decisionToVariantList : [];
        const rows = list.map((d) => ({
            decisionName: (d && (d.decisionName || d.name)) || '(decision)',
            variantName: vName(d && d.variantId)
        }));
        if (rows.length) { return rows; }
        // Defensive fallback for any op that lists variantIds without a decision map.
        const vids = Array.isArray(attrs.variantIds) ? attrs.variantIds : [];
        return vids.map((v) => ({
            decisionName: '(variant)',
            variantName: vName((v && typeof v === 'object') ? (v.id || v.variantId) : v)
        }));
    }

    // Walk the block tree for lightning/image contentKeys (dedup, preserve order).
    _collectImageKeys(body) {
        const keys = [];
        const seen = new Set();
        const visit = (n) => {
            if (Array.isArray(n)) { n.forEach(visit); return; }
            if (!n || typeof n !== 'object') { return; }
            if (n.definition === 'lightning/image') {
                const ref = n.attributes && n.attributes.imageInfo && n.attributes.imageInfo.source
                    && n.attributes.imageInfo.source.ref;
                const ck = ref && ref.contentKey;
                if (ck && !seen.has(ck)) { seen.add(ck); keys.push(ck); }
            }
            Object.values(n).forEach(visit);
        };
        visit(body && body['sfdc_cms:block']);
        return keys;
    }

    // Classify each content block's ROLE for the read-only "slot roles" readout. Mirrors
    // ReadDynamicEmailAction's server-side heuristic (Apex is the source of truth that drives
    // eligibility; this is display-only): 1st image = logo, other images = image, footer/boilerplate
    // paragraphs = footer, else text. Walks children in document order so slot numbers line up with
    // what the agent uses. (Kept in sync with ReadDynamicEmailAction.isFooterText / role logic.)
    _classifySlots(body) {
        const CONTENT = ['lightning/heading', 'lightning/paragraph', 'lightning/image', 'lightning/actionButton'];
        // Block ids that ALREADY have dynamic content (an operation targets them). A block that is
        // already personalized is NOT eligible for a NEW axis (editing existing DC isn't supported),
        // so flag it distinctly from role-based ineligibility (logo/footer).
        const personalizedBlockIds = new Set();
        const ops = Array.isArray(body && body['sfdc_cms:operations']) ? body['sfdc_cms:operations'] : [];
        ops.forEach((op) => {
            const tid = op && (op.targetId || op.target);
            if (tid) { personalizedBlockIds.add(tid); }
        });
        const rows = [];
        let slot = 0;
        let imgOrdinal = 0;
        const walk = (n) => {
            if (Array.isArray(n)) { n.forEach(walk); return; }
            if (!n || typeof n !== 'object') { return; }
            if (n.type === 'block' && n.definition && CONTENT.includes(n.definition)) {
                slot += 1;
                const kind = n.definition.replace('lightning/', '');
                const text = (n.attributes && typeof n.attributes.text === 'string') ? n.attributes.text : '';
                let role;
                if (n.definition === 'lightning/image') { imgOrdinal += 1; role = imgOrdinal === 1 ? 'logo' : 'image'; }
                else if (this._isFooterText(text)) { role = 'footer'; }
                else { role = 'text'; }
                const alreadyDc = !!(n.id && personalizedBlockIds.has(n.id));
                // Eligible for a NEW axis only if role allows it AND it isn't already personalized.
                const personalizable = role !== 'logo' && role !== 'footer' && !alreadyDc;
                // Role-based "not personalized by audience" note only when the reason is the ROLE
                // (logo/footer) -- an already-DC slot shows its own "has DC" badge instead.
                const showRoleNote = (role === 'logo' || role === 'footer');
                rows.push({ key: 'sr' + slot, slot, kind, role, personalizable, alreadyDc, showRoleNote,
                    roleClass: 'sr-role sr-role_' + role });
            }
            // Descend into children in order (document order) for correct slot numbering.
            if (Array.isArray(n.children)) { n.children.forEach(walk); }
        };
        walk(body && body['sfdc_cms:block']);
        return rows;
    }

    // Mirror of ReadDynamicEmailAction.isFooterText (display-only classification).
    _isFooterText(raw) {
        if (!raw) { return false; }
        const lower = raw.toLowerCase();
        if (lower.includes('unsubscribe') || lower.includes('preference manager')
            || lower.includes('manage preferences') || lower.includes('all rights reserved')
            || lower.includes('{!$organization.address}') || lower.includes('view in browser')
            || lower.includes('©') || lower.includes('&copy;') || lower.includes('&#169;')) {
            return true;
        }
        const stripped = raw
            .replace(/\{![^}]*\}/g, ' ')
            .replace(/&lt;[^&]*&gt;/g, ' ')
            .replace(/<[^>]+>/g, ' ')
            .replace(/&[a-z#0-9]+;/gi, ' ')
            .replace(/[|\-–—•]/g, ' ')
            .replace(/\s+/g, ' ').trim();
        return stripped.length < 8;
    }

    // The brand source contentKey, when the email pins a specific brand record (vs the SF default).
    _brandKey(body) {
        const bs = body && body['lightning:brandSource'];
        return (bs && bs.contentKey) || null;
    }

    // Reactive GraphQL variables for the asset lookup; undefined suppresses the wire until we have keys.
    _updateAssetVars() {
        const all = [...(this.imageKeys || [])];
        if (this.brandKey) { all.push(this.brandKey); }
        this.assetVars = all.length ? { keys: all } : undefined;
    }

    @wire(getContext)
    wiredContext({ data }) {
        if (!data) { return; }
        this.currentContext = data;
        this.contentTypeFqn = data.contentTypeFQN || this.contentTypeFqn;
        if (!this.contentKey) { this.contentKey = data.contentKey || null; }
        if (!this.contentId) { this.contentId = data.contentId || data.managedContentId || data.recordId || null; }
        this._updatePpVars();
    }

    _updatePpVars() {
        const v = this.contentId ? { rid: this.contentId } : undefined;
        this.ppVars = v;
        this.lmVars = v;   // same record id drives the LastModifiedDate change-detection wire
    }

    // Resolve the email's asset ContentKeys (image blocks + brand source) to Name + type. GraphQL
    // ManagedContent supports a ContentKey in-list filter (verified SIC2025); callout-free.
    @wire(graphql, {
        query: gql`
            query getAssets($keys: [String]) {
                uiapi {
                    query {
                        ManagedContent(where: { ContentKey: { in: $keys } }, first: 50) {
                            edges { node { Id Name { value } ContentType { value } ContentKey { value } } }
                        }
                    }
                }
            }
        `,
        variables: '$assetVars'
    })
    wiredAssets({ data }) {
        if (!data) { return; }
        const edges =
            (data.uiapi && data.uiapi.query && data.uiapi.query.ManagedContent &&
                data.uiapi.query.ManagedContent.edges) || [];
        const map = {};
        edges.forEach((e) => {
            const n = (e && e.node) || {};
            const ck = n.ContentKey && n.ContentKey.value;
            if (ck) {
                map[ck] = {
                    name: (n.Name && n.Name.value) || ck,
                    type: (n.ContentType && n.ContentType.value) || ''
                };
            }
        });
        this.assetsByKey = map;
    }

    // Scoring CI — MktCalculatedInsight is UI-API/GraphQL-queryable (verified SIC2025) but NOT
    // Apex-SOQL-able, so it rides the wire, not getEnvHealth. A CI whose Name contains "Score"
    // powers decision logic in richer DC demos; presence-only heuristic.
    @wire(graphql, {
        query: gql`
            query getCis {
                uiapi { query { MktCalculatedInsight(first: 200) { edges { node { Id Name { value } } } } } }
            }
        `
    })
    wiredCis({ data }) {
        if (!data) { return; }
        const edges =
            (data.uiapi && data.uiapi.query && data.uiapi.query.MktCalculatedInsight &&
                data.uiapi.query.MktCalculatedInsight.edges) || [];
        this.ciTotal = edges.length;
        this.ciScoring = edges.some((e) => {
            const n = e && e.node && e.node.Name && e.node.Name.value;
            return n && n.toLowerCase().indexOf('score') !== -1;
        });
        this.ciLoaded = true;
    }

    // Brands across workspaces — sfdc_cms__brand ManagedContent records. GraphQL wire (the content-type
    // filter field is not Apex-SOQL-filterable here, but is GraphQL-queryable — verified SIC2025).
    @wire(graphql, {
        query: gql`
            query getBrands {
                uiapi {
                    query {
                        ManagedContent(where: { ContentTypeFullyQualifiedName: { eq: "sfdc_cms__brand" } }, first: 200) {
                            totalCount
                            edges { node { Id Name { value } } }
                        }
                    }
                }
            }
        `
    })
    wiredBrands({ data }) {
        if (!data) { return; }
        const mc = data.uiapi && data.uiapi.query && data.uiapi.query.ManagedContent;
        this.brandCount = (mc && mc.totalCount) || 0;
        const edges = (mc && mc.edges) || [];
        this.brands = edges.map((e) => {
            const n = (e && e.node) || {};
            return { id: n.Id, name: (n.Name && n.Name.value) || n.Id };
        });
        this.brandsLoaded = true;
    }

    // The dynamic content on this email — PersonalizationPoints whose SourceRecordId is this content.
    // GraphQL/UI-API, no Apex, no callout (confirmed queryable on SIC2025).
    @wire(graphql, {
        query: gql`
            query getPps($rid: ID) {
                uiapi {
                    query {
                        PersonalizationPoint(where: { SourceRecordId: { eq: $rid } }, first: 50) {
                            edges {
                                node {
                                    Id
                                    DeveloperName { value }
                                    Name { value }
                                    PersonalizationSchemaEnum { value }
                                    Status { value }
                                    ProfileDataGraphId { value }
                                }
                            }
                        }
                    }
                }
            }
        `,
        variables: '$ppVars'
    })
    wiredPps(result) {
        this._ppWire = result;                      // keep provisioned value for refreshGraphQL()
        const { data, errors } = result;
        if (errors) { this.error = 'Could not read personalization: ' + JSON.stringify(errors); return; }
        if (!data) { return; }
        const edges =
            (data.uiapi && data.uiapi.query && data.uiapi.query.PersonalizationPoint &&
                data.uiapi.query.PersonalizationPoint.edges) || [];
        const val = (n, f) => (n && n[f] && n[f].value) || '';
        this.pps = edges.map((e) => {
            const n = (e && e.node) || {};
            return {
                name: val(n, 'DeveloperName'),
                label: val(n, 'Name'),
                schema: val(n, 'PersonalizationSchemaEnum'),
                status: val(n, 'Status'),
                dataGraphId: val(n, 'ProfileDataGraphId')
            };
        });
        // (Change detection moved to the ManagedContent.LastModifiedDate poll below — it catches ANY
        // edit to this email, not just a grown PP count. This wire now only populates the PP display.)
    }

    // ── Change detection: poll the email's LastModifiedDate ──────────────────────────────────────────
    // Watches ManagedContent.LastModifiedDate (UI-API/GraphQL, in-context, no callout). Any server-side
    // change to this email -- an agent adding DC, editing decisions, anything -- bumps the timestamp, so
    // this catches more than the old PP-count signal. Baseline = the FIRST poll's timestamp; a later poll
    // with a newer value flags serverChangeAvailable (the Refresh button then highlights).
    @wire(graphql, {
        query: gql`
            query getLastMod($rid: ID) {
                uiapi {
                    query {
                        ManagedContent(where: { Id: { eq: $rid } }, first: 1) {
                            edges { node { Id LastModifiedDate { value } } }
                        }
                    }
                }
            }
        `,
        variables: '$lmVars'
    })
    wiredLastMod(result) {
        this._lmWire = result;                      // keep the provisioned value so we can refreshGraphQL() it
        const { data, errors } = result;
        if (errors || !data) { return; }
        const edges = (data.uiapi && data.uiapi.query && data.uiapi.query.ManagedContent
            && data.uiapi.query.ManagedContent.edges) || [];
        const node = edges.length ? edges[0].node : null;
        const lm = (node && node.LastModifiedDate && node.LastModifiedDate.value) || '';
        if (!lm) { return; }
        if (this._lmBaseline === null) {
            this._lmBaseline = lm;                  // first read -> baseline
        } else if (lm > this._lmBaseline) {
            this.serverChangeAvailable = true;      // email changed server-side since load
        }
    }

    // ── Editor refresh after an agent update ────────────────────────────────────────────────────────
    // The DC agent updates the email SERVER-SIDE; the open editor's in-memory model doesn't see it, and
    // the two browser contexts can't message each other (LMS is unavailable in the CmsEditorExtension
    // slot -- verified), and cmsEditorApi.updateContent rejects the rich email body ("cannot refresh
    // page"), so no in-place repaint. Detection uses the SAME server signal the panel already reads
    // reliably: the PersonalizationPoint GraphQL wire (this.pps -- uiGraphQLApi, in-context, no REST
    // self-callout, so no 401 -- unlike a getSessionId callout). On a timer we re-run that wire (by
    // re-provisioning ppVars) and compare the server PP count to how many personalizations the editor's
    // own getContent showed at load; if the server has more, an agent update landed -> surface a
    // non-intrusive "Reload editor" prompt (we never auto-reload out from under the user).
    @track serverChangeAvailable = false;
    _ppBaseline = null;                 // (legacy; no longer used for detection)
    _lmBaseline = null;                 // ManagedContent.LastModifiedDate from the FIRST poll (null until set)
    _lmWire;                            // provisioned LastModifiedDate wire result (for refreshGraphQL)
    _ppWire;                            // provisioned PP wire result (for refreshGraphQL)
    @track lmVars;                      // reactive vars for the LastModifiedDate wire
    _pollTimer;
    POLL_MS = 5000;                     // poll cadence (5s)

    connectedCallback() {
        getConfigStatus().then((c) => { this.config = c; }).catch((e) => { this.error = this._msg(e); });
        getEnvHealth().then((h) => { this.envHealth = h; }).catch((e) => { this.error = this._msg(e); });
        getImageCatalogHealth().then((r) => { this.imageHealth = r; }).catch(() => { /* optional; skip row */ });
        getWorkspaces().then((w) => { this.workspaces = w || []; }).catch((e) => { this.error = this._msg(e); });
        getModels().then((m) => { this.models = m; }).catch((e) => { this.error = this._msg(e); });
        // Re-run the PP GraphQL wire periodically so it re-reads server-side PPs after an agent update.
        this._pollTimer = setInterval(() => { this._repollPps(); }, this.POLL_MS);
    }

    disconnectedCallback() {
        if (this._pollTimer) { clearInterval(this._pollTimer); this._pollTimer = null; }
    }

    // Force the PP GraphQL wire to re-fetch by re-provisioning its variables (toggle off, then back on
    // next microtask). Callout-free, no 401. wiredPps then updates this.pps and flags a change if the
    // server PP count has grown past what the editor showed at load.
    _repollPps() {
        if (!this.contentId) { return; }
        const rid = this.contentId;
        if (this.lmVars === undefined) { this.lmVars = { rid }; }   // first-time provision
        if (this.ppVars === undefined) { this.ppVars = { rid }; }
        // The graphql wire is CACHE-FIRST: re-provisioning the SAME { rid } returns the LDS-cached
        // result and only revalidates from the server on LDS's own (~30s) cadence -- which is why the
        // Refresh light lagged ~30s despite a 5s poll. refreshGraphQL() forces a SERVER refetch of the
        // provisioned wire, so LastModifiedDate is re-read from the org every poll (~5s to light up).
        if (this._lmWire) { refreshGraphQL(this._lmWire); }
        if (this._ppWire) { refreshGraphQL(this._ppWire); }
    }

    // Button handler: reload the editor so it re-pulls the fresh server body (with the agent's new DC).
    // A reload always reflects the server truth -- unlike updateContent, it can't fail on body shape.
    refreshEditor() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        window.location.reload();
    }
    // Always-present Refresh; glows when the live-update poll detected an agent change (serverChangeAvailable).
    get refreshBtnClass() {
        return 'bridge-btn refresh-btn' + (this.serverChangeAvailable ? ' refresh-btn_alert' : '');
    }
    get refreshTitle() {
        return this.serverChangeAvailable
            ? 'Agent update detected — reload the editor to see it'
            : 'Reload the editor (pulls in any server-side change)';
    }

    runTest() {
        this.loading = true; this.error = undefined; this.testResult = undefined;
        this.showTestDetails = false;
        runFullTest()
            .then((r) => { this.testResult = r; this.testRanAt = new Date(); })
            .catch((e) => { this.error = this._msg(e); })
            .finally(() => { this.loading = false; });
    }

    toggleSetupSteps() { this.showSetupSteps = !this.showSetupSteps; }
    toggleTestDetails() { this.showTestDetails = !this.showTestDetails; }

    _msg(e) {
        return (e && e.body && e.body.message) ? e.body.message
            : (e && e.message) ? e.message : String(e);
    }

    // ── Tab 1 ──
    get waitingForEditor() { return !this.gotContent && !this.contentTypeFqn; }
    get hasPps() { return this.pps.length > 0; }
    get isPersonalized() { return this.pps.length > 0; }
    get ppCount() { return this.pps.length; }
    get activeCount() { return this.pps.filter((p) => p.status === 'Active').length; }
    get dataGraphCount() { return new Set(this.pps.map((p) => p.dataGraphId).filter(Boolean)).size; }
    // Areas (Ops) = every op across all PPs; Decisions (variants) = every decision row across all ops.
    // Sourced from the editor-content structure (dcStructure.byPp) -- what is actually wired into this
    // email's body -- so the tiles match the decision-table preview below, not just the PP headers.
    get opCount() {
        const byPp = (this.dcStructure && this.dcStructure.byPp) || {};
        return Object.keys(byPp).reduce((sum, name) => sum + (byPp[name] || []).length, 0);
    }
    get decisionCount() {
        const byPp = (this.dcStructure && this.dcStructure.byPp) || {};
        return Object.keys(byPp).reduce((sum, name) =>
            sum + (byPp[name] || []).reduce((s, op) => s + ((op.rows && op.rows.length) || 0), 0), 0);
    }
    // The email's brand name (from the resolved brand source), for the middle summary tile. Falls
    // back to a label when the email uses the SF default brand (no pinned brand record).
    get brandName() {
        if (!this.brandKey) { return 'SF default'; }
        const m = this.assetsByKey[this.brandKey];
        return (m && m.name) || 'Brand';
    }
    // Summary tiles: PP count · Brand (replaces the old "Active" count — per-PP status badges now
    // carry active/draft state, so the brand is the more useful thing up top) · Data Graphs. The
    // brand tile is text, not a number, so it renders through its own template branch.
    get dcSummaryTiles() {
        return [
            { key: 'pp', num: this.ppCount, label: 'Personalization Points', isText: false },
            { key: 'ops', num: this.opCount, label: 'Areas (Ops)', isText: false },
            { key: 'dec', num: this.decisionCount, label: 'Decisions (Variants)', isText: false },
            { key: 'dg', num: this.dataGraphCount, label: 'Data Graphs', isText: false }
        ];
    }

    // ── "Talk to the agent about THIS email" bridge ──────────────────────────────────────────
    // The DC Agent runs in its own Agentforce conversation and CANNOT see the CMS editor frame,
    // so it only knows which email you mean if you tell it the content key. This panel already
    // has that key in-frame (getContent/getContext above), so we surface it here with a one-click
    // copy of a ready-to-paste agent prompt seeded with the real key -- closing the loop without
    // asking the user to hunt for an MC-key. Read-only; nothing here writes.
    get currentEmailName() {
        const c = this.currentContent || {};
        return c.title || c.name || (c.body && c.body.title) || c.apiName || null;
    }
    get currentEmailKey() { return this.contentKey || null; }
    get hasCurrentEmail() { return !!this.contentKey; }

    // ── Plan preview (Feature 3) ── dry-run a candidate personalization through the SAME pipeline the
    // agent runs (Read->Assemble->Validate), no LLM, no write, so the user sees which slots WILL bind
    // before approving in chat.
    togglePps() { this.showPps = !this.showPps; }
    toggleSlotRoles() { this.showSlotRoles = !this.showSlotRoles; }
    togglePreview() { this.showPreview = !this.showPreview; }
    handlePreviewSlots(e) { this.previewSlots = e.target.value; }
    handlePreviewField(e) { this.previewField = e.target.value; }
    handlePreviewValues(e) { this.previewValues = e.target.value; }

    runPreview() {
        if (!this.currentEmailKey) { return; }
        this.previewRunning = true;
        this.previewResult = null;
        previewPlan({
            contentKey: this.currentEmailKey,
            slotNumbers: this.previewSlots,
            fieldTerm: this.previewField,
            valuesCsv: this.previewValues,
            graphApiName: ''
        })
            .then((r) => { this.previewResult = r; })
            .catch((e) => {
                this.previewResult = { error: (e && e.body && e.body.message) || (e && e.message) || 'Preview failed.' };
            })
            .finally(() => { this.previewRunning = false; });
    }

    get previewHasResult() { return !!this.previewResult; }
    get previewBindList() {
        const wb = (this.previewResult && this.previewResult.willBind) || [];
        return wb.map((b, i) => ({ key: 'wb' + i, slot: b.slot, elementKey: b.elementKey }));
    }
    get previewDecisionList() {
        const ds = (this.previewResult && this.previewResult.decisions) || [];
        return ds.map((d, i) => ({ key: 'pd' + i, label: d }));
    }
    get previewWarnList() {
        const ws = (this.previewResult && this.previewResult.warnings) || [];
        return ws.map((w, i) => ({ key: 'pw' + i, label: w }));
    }
    get previewHasWarnings() { return this.previewWarnList.length > 0; }
    get previewIsValid() { return !!(this.previewResult && this.previewResult.valid); }
    get previewValidClass() {
        return 'qa-row ' + (this.previewIsValid ? 'card_ok' : 'card_warn');
    }
    get previewValidLabel() {
        return this.previewIsValid ? 'Will apply cleanly' : 'Will not apply as-is — see notes';
    }
    get previewSummary() { return (this.previewResult && this.previewResult.planSummary) || ''; }
    get previewError() { return (this.previewResult && this.previewResult.error) || ''; }
    // "eligible: 4, 5, 6" hint from the in-frame slot-role readout (personalizable text slots).
    get eligibleSlotHint() {
        const el = (this.slotRoles || []).filter((s) => s.personalizable).map((s) => s.slot);
        return el.length ? 'Eligible slots: ' + el.join(', ') : '';
    }
    // A prompt the user can paste straight into the DC Agent. Naming the email AND its key lets
    // the agent read the exact content without guessing from the title. Kept generic ("add / update
    // dynamic content") so it fits both the build-personalization and image-swap flows.
    get agentPrompt() {
        const key = this.contentKey || '';
        const nm = this.currentEmailName ? ' ("' + this.currentEmailName + '")' : '';
        return 'Read the existing email ' + key + nm
            + ' and tell me which slots I can personalize, then help me add dynamic content to it.';
    }

    // Quick-action prompts: one-click, ready-to-paste prompts for the most common DC updates, so the
    // user doesn't have to phrase them. The agent runs in a SEPARATE context and can't see this
    // editor frame, so these COPY a prompt (they don't inject it live) -- same mechanism as
    // handleCopyPrompt. Each is gated on what the panel can already see in-frame.
    //
    // Translate: uses the RELIABLE full-translate wording ("translate ... keep English as the
    // default") -- the FillCopyAction.buildLanguagePersonalizations path, verified live -- NOT the
    // flaky "personalize all eligible by country" expander phrasing. Keys on Country generically, so
    // it needs no data-graph field lookup; only that the email has text slots to translate.
    get translatePrompt() {
        const key = this.contentKey || '';
        const nm = this.currentEmailName ? ' ("' + this.currentEmailName + '")' : '';
        return 'Read the existing email ' + key + nm
            + ' and translate it to Spanish, French and Japanese. Keep the English as the default '
            + 'content for each area.';
    }
    // Show the Translate quick action only when there's an open email AND at least one text (copy)
    // slot to translate -- an image-only or empty email has nothing to translate. slotRoles carries
    // the in-frame classification; 'text' is the copy-vary-eligible role.
    get showTranslateAction() {
        if (!this.hasCurrentEmail) { return false; }
        const roles = this.slotRoles || [];
        if (roles.length) { return roles.some((s) => s.role === 'text'); }
        // Before slot roles resolve, fall back to "is there any personalizable content at all".
        return this.isPersonalized || this.hasSlotRoles;
    }
    handleCopyTranslate() { this._copy(this.translatePrompt, 'translate'); }
    get translateCopied() { return this.copiedWhat === 'translate'; }

    // Industry / B2B / B2C quick actions — all personalize by INDUSTRY (the flagship data-graph axis),
    // audience-flavored. They need a data graph to personalize from, so they're gated on dataGraphCount
    // > 0 (the panel already knows this from the email's PPs); disabled + "needs a data graph" otherwise.
    // "Use Industry for B2B/B2C" = same industry DC mechanism, just audience-framed value sets. Each
    // COPIES a ready prompt (agent runs separately), same as the other quick actions.
    // Enabled only when an email is open AND it has a bound data graph (dataGraphCount > 0).
    get industryDcEnabled() {
        return this.hasCurrentEmail && this.dataGraphCount > 0;
    }
    get industryDcDisabled() { return !this.industryDcEnabled; }  // template can't negate; bind disabled to this
    _emailRef() {
        const key = this.contentKey || '';
        const nm = this.currentEmailName ? ' ("' + this.currentEmailName + '")' : '';
        return key + nm;
    }
    get industryPrompt() {
        return 'Read the existing email ' + this._emailRef()
            + ' and add dynamic content to a body paragraph, personalized by industry: '
            + 'Healthcare, Technology, and Finance. Keep the current copy as the default.';
    }
    get b2bPrompt() {
        return 'Read the existing email ' + this._emailRef()
            + ' and add dynamic content to a body paragraph, personalized by industry for a B2B '
            + 'audience: Technology, Financial Services, and Manufacturing. Keep the current copy as the default.';
    }
    get b2cPrompt() {
        return 'Read the existing email ' + this._emailRef()
            + ' and add dynamic content to a body paragraph, personalized by industry for a B2C '
            + 'audience: Retail, Healthcare, and Travel & Hospitality. Keep the current copy as the default.';
    }
    handleCopyIndustry() { this._copy(this.industryPrompt, 'industry'); }
    handleCopyB2b() { this._copy(this.b2bPrompt, 'b2b'); }
    handleCopyB2c() { this._copy(this.b2cPrompt, 'b2c'); }
    get industryCopied() { return this.copiedWhat === 'industry'; }
    get b2bCopied() { return this.copiedWhat === 'b2b'; }
    get b2cCopied() { return this.copiedWhat === 'b2c'; }
    get industryGateTitle() { return this.industryDcEnabled ? 'Copy a ready industry-DC prompt' : 'Needs a data graph on this email'; }

    // Copy helpers. navigator.clipboard is available in the CmsEditorExtension iframe (same-origin
    // Lightning context); fall back to a transient message if it's unavailable. copiedWhat drives a
    // brief "Copied ✓" affordance in the template.
    @track copiedWhat = '';
    handleCopyKey() { this._copy(this.currentEmailKey, 'key'); }
    handleCopyPrompt() { this._copy(this.agentPrompt, 'prompt'); }
    _copy(text, what) {
        if (!text) { return; }
        const done = () => { this.copiedWhat = what; setTimeout(() => { this.copiedWhat = ''; }, 1800); };
        try {
            if (navigator.clipboard && navigator.clipboard.writeText) {
                navigator.clipboard.writeText(text).then(done).catch(() => { this.copiedWhat = 'error'; });
            } else {
                this.copiedWhat = 'error';
            }
        } catch (e) { this.copiedWhat = 'error'; }
    }
    get keyCopied() { return this.copiedWhat === 'key'; }
    get promptCopied() { return this.copiedWhat === 'prompt'; }
    get copyFailed() { return this.copiedWhat === 'error'; }

    // Decision-table preview — one card per PersonalizationPoint, expanding to its ops and each op's
    // decision→variant rows. Mirrors the toolkit's Object Visualizer (Template → PP → Op → rows). The
    // PP headers (label/schema/status) come from the authoritative GraphQL wire; the ops/decisions/
    // variants come from the in-frame body parse (this.dcStructure). Union the two so a PP with ops in
    // the body but no GraphQL row (or vice-versa) still renders.
    get ppTree() {
        const byPp = (this.dcStructure && this.dcStructure.byPp) || {};
        const headerByName = {};
        (this.pps || []).forEach((p) => { if (p.name) { headerByName[p.name] = p; } });

        // Every PP name we know about, from either source.
        const names = new Set([...Object.keys(byPp), ...Object.keys(headerByName)]);
        const tree = [];
        names.forEach((name) => {
            const hdr = headerByName[name] || {};
            const ops = (byPp[name] || []).map((op) => ({
                key: name + ':op' + op.index,
                index: op.index,
                targetLabel: op.targetLabel,
                targetIdShort: op.targetIdShort,
                decisionCount: op.rows.length,
                decisionLabel: op.rows.length + (op.rows.length === 1 ? ' decision' : ' decisions'),
                rows: op.rows.map((r, ri) => ({
                    key: name + ':op' + op.index + ':r' + ri,
                    decisionName: r.decisionName,
                    variantName: r.variantName
                }))
            }));
            const opCount = ops.length;
            // Status badge — green when Active, amber/red when Draft/Inactive so a PP that won't
            // fire at send stands out. A PP present in the body but with no GraphQL header (status
            // unknown) gets a neutral "unknown" badge rather than a false "Active".
            const rawStatus = hdr.status || '';
            const isActive = rawStatus === 'Active';
            const statusKnown = !!rawStatus;
            let badgeClass = 'pp-badge pp-badge_unknown';
            let badgeText = statusKnown ? rawStatus : 'Status unknown';
            if (isActive) { badgeClass = 'pp-badge pp-badge_ok'; badgeText = 'Active'; }
            else if (statusKnown) { badgeClass = 'pp-badge pp-badge_warn'; badgeText = rawStatus; }
            tree.push({
                key: name,
                name,
                label: hdr.label || name,
                schema: hdr.schema || '',
                hasSchema: !!hdr.schema,
                badgeClass,
                badgeText,
                opCount,
                opSummary: opCount + (opCount === 1 ? ' op' : ' ops'),
                hasOps: opCount > 0,
                ops
            });
        });
        // Stable order: PPs with ops first (the interesting ones), then by name.
        tree.sort((a, b) => (b.hasOps - a.hasOps) || a.name.localeCompare(b.name));
        return tree;
    }
    get hasPpTree() { return this.ppTree.length > 0; }

    get hasSlotRoles() { return this.slotRoles && this.slotRoles.length > 0; }

    // Resolved assets wired into this email: brand source + image blocks, each with name/type and an
    // in-frame thumbnail (relative /cms/media/<key>, which renders under the user session). Logo vs
    // Header is a position heuristic (first image = logo, second = header) — the block tree does not
    // label them, so we only assert roles for brand + the conventional first/second image.
    get assetRows() {
        const rows = [];
        const meta = (k) => this.assetsByKey[k] || {};
        if (this.brandKey) {
            const m = meta(this.brandKey);
            // A brand RECORD (sfdc_cms__brand) is not an image -- /cms/media/<key> has nothing to
            // render, so show a non-image marker (initial) instead of a broken thumbnail.
            rows.push({ key: this.brandKey, role: 'Brand', name: m.name || this.brandKey,
                type: m.type || 'sfdc_cms__brand', hasThumb: false, thumb: null,
                initial: (m.name || 'B').substring(0, 1).toUpperCase() });
        }
        (this.imageKeys || []).forEach((k, i) => {
            const m = meta(k);
            const role = i === 0 ? 'Logo' : i === 1 ? 'Header' : 'Image ' + (i + 1);
            rows.push({ key: k, role, name: m.name || k, type: m.type || '',
                hasThumb: true, thumb: '/cms/media/' + k, initial: '' });
        });
        return rows;
    }
    get hasAssets() { return this.assetRows.length > 0; }
    // ── Tab 2 ── ordered install steps; each red row deep-links to its fix.
    get readinessRows() {
        const c = this.config || {};
        const t = this.testResult;
        const base = c.orgBaseUrl || '';
        const link = (p) => (base ? base + p : null);
        // Deep link straight to the AuraPoc_Config.Default custom-metadata RECORD when we know its Id
        // (present in BOTH the configured and not-yet-configured states -- the record exists as soon as
        // the package is deployed, placeholder values or not). Falls back to the CMT home otherwise.
        const configRecordLink = c.configRecordId
            ? link('/lightning/setup/CustomMetadata/page?address=%2F' + c.configRecordId)
            : link(SETUP_PATHS.cmdt);

        // Deep link straight to the installed External Client App (AuraPoc_JwtApp) detail page — where
        // the admin copies the Consumer Key & Secret and enables JWT. The ECA detail route lives on the
        // SETUP domain (.my.salesforce-setup.com, not .my.salesforce.com): /lightning/setup/
        // ManageExternalClientApplication/<ecaId>/detail. Falls back to the ECA Manager list when we
        // don't have the Id (fresh org before install). Label names the app either way.
        const setupHost = base.replace('.my.salesforce.com', '.my.salesforce-setup.com');
        const ecaLink = c.externalClientAppId
            ? setupHost + '/lightning/setup/ManageExternalClientApplication/'
                + String(c.externalClientAppId).substring(0, 15) + '/detail'
            : link(SETUP_PATHS.eca);
        const ecaLabel = c.externalClientAppId ? 'AuraPoc_JwtApp' : 'External Client Apps';

        // Order = the install sequence. Presence rows first (knowable with zero setup),
        // then the proven-auth rows that only exist after "Run full test".
        const rows = [
            { key: 'cfg',   label: 'Config record present',       ok: !!c.configRecordPresent,
              detail: c.configRecordPresent ? 'AuraPoc_Config.Default' : 'deploy the package (Step 1)',
              // Present-or-not, offer the link: to the record itself when it exists (both states),
              // else to Custom Metadata home so a fresh org can still navigate there. alwaysLink keeps
              // it visible even when this row is OK (configured) -- an admin still wants to open the
              // record to review/edit it.
              fixUrl: configRecordLink,
              fixLabel: c.configRecordId ? 'config record' : 'Custom Metadata',
              alwaysLink: true },
            { key: 'cert',  label: 'Certificate configured',      ok: !!c.certDevName,
              detail: c.certDevName || 'create self-signed AuraPoc_JwtCert',
              fixUrl: link(SETUP_PATHS.cert), fixLabel: 'Cert & Key Mgmt' },
            { key: 'ck',    label: 'Consumer key set',            ok: !!c.consumerKeySet,
              detail: c.consumerKeySet ? '' : 'open AuraPoc_JwtApp → Settings → Consumer Key & Secret, then paste into the config record',
              fixUrl: ecaLink, fixLabel: ecaLabel },
            { key: 'runas', label: 'Run-as user set',             ok: !!c.runAsUserSet,
              detail: c.runAsUser || 'set RunAsUser__c on the config record',
              fixUrl: link(SETUP_PATHS.cmdt), fixLabel: 'Custom Metadata' },
            { key: 'inst',  label: 'Instance URL set',            ok: !!c.instanceUrlSet,
              detail: c.instanceUrl || 'set InstanceUrl__c to this org My Domain',
              fixUrl: link(SETUP_PATHS.cmdt), fixLabel: 'Custom Metadata' }
        ];
        if (t) {
            rows.push({ key: 'tok',  label: 'JWT token mint', ok: !!t.tokenMinted,
              detail: t.tokenMinted ? 'proven' : 'in AuraPoc_JwtApp enable OAuth + JWT Bearer + refresh_token scope',
              fixUrl: ecaLink, fixLabel: ecaLabel });
            // Run-as pre-authorization (runbook Step C) -- a distinct MANUAL step, not independently
            // detectable (it surfaces only as an invalid_grant on the mint above). Show it whenever the
            // mint hasn't proven yet, so a red mint row points at BOTH its causes (OAuth consent AND
            // run-as pre-auth) rather than leaving the user guessing. Manual once mint is proven.
            // When the mint succeeded, pre-auth is implied -> show a real OK; otherwise a manual
            // guidance row naming the exact policy toggle.
            rows.push(t.tokenMinted
              ? { key: 'runauth', label: 'Run-as user pre-authorized', ok: true, detail: 'proven (mint succeeded)', fixUrl: null, fixLabel: '' }
              : { key: 'runauth', label: 'Run-as user pre-authorized', manual: true,
                  detail: 'AuraPoc_JwtApp > Policies > OAuth Policies: Permitted Users = "Admin approved users are pre-authorized" + assign the perm set to the run-as user',
                  fixUrl: ecaLink, fixLabel: ecaLabel });
            rows.push({ key: 'aura', label: 'Aura session (DC wiring)', ok: !!t.auraSessionReady,
              detail: t.auraSessionReady ? 'proven' : 'add file/lightning Remote Site Settings',
              fixUrl: link(SETUP_PATHS.rss), fixLabel: 'Remote Site Settings' });
            rows.push({ key: 'ws',   label: 'Marketing CMS workspace',
              ok: (t.emailWorkspaceCount || 0) > 0,
              detail: (t.emailWorkspaceCount || 0) + ' found',
              fixUrl: null, fixLabel: '' });
        }
        // Manual steps this panel cannot verify from its signals (no in-org read for BotVersion
        // status or an Agent Access grant), so they show as guidance rows -- always listed, neutral
        // status, with a deep link -- rather than a false OK/fail. They complete the "green health
        // check -> agent actually usable" gap: publish/activate compiles the draft into a live agent
        // (CLI/Agent API only -- the panel can't do it), and Agent Access makes the agent visible.
        rows.push({ key: 'pub', label: 'Publish + activate the agent', manual: true,
          detail: 'compile the draft to live: sf agent publish authoring-bundle -n Dynamic_Content_Agent_v3, then sf agent activate',
          fixUrl: link(SETUP_PATHS.agents), fixLabel: 'Agents' });
        rows.push({ key: 'access', label: 'Grant Agent Access', manual: true,
          detail: 'add the agent to a Profile/Permission Set (App > Agent Access) so it appears for users',
          fixUrl: link(SETUP_PATHS.agents), fixLabel: 'Agents' });
        // Number the two groups INDEPENDENTLY so manual guidance rows don't read as trailing
        // "unfinished" items (10, 11) in the auto-checked list. detectableRows own 1..N; manual rows
        // are a separate reference list (see detectableRows/manualRows getters + the two template blocks).
        let dOrder = 0, mOrder = 0;
        return rows.map((r) => ({
            ...r,
            order: r.manual ? (mOrder += 1) : (dOrder += 1),
            hasFix: !!r.fixUrl && (!r.ok || r.alwaysLink === true || r.manual === true),
            rowClass: r.manual ? 'qa-row qa-row_manual' : (r.ok ? 'qa-row qa-row_ok' : 'qa-row qa-row_fail'),
            statusClass: r.manual ? 'qa-status qa-status_manual' : (r.ok ? 'qa-status qa-status_ok' : 'qa-status qa-status_fail'),
            statusText: r.manual ? 'Manual' : (r.ok ? 'OK' : 'Do this')
        }));
    }
    // Auto-checked steps (the real checklist) vs manual reference steps (done outside the panel,
    // not verifiable here). Split so the UI shows them as two distinct sections.
    get detectableRows() { return this.readinessRows.filter((r) => !r.manual); }
    get manualRows()      { return this.readinessRows.filter((r) => r.manual); }
    get hasManualRows()   { return this.manualRows.length > 0; }

    // Presence half — everything knowable with zero setup (config record + its fields).
    get presenceComplete() {
        const c = this.config || {};
        return !!c.configRecordPresent && !!c.certDevName && !!c.consumerKeySet
            && !!c.runAsUserSet && !!c.instanceUrlSet;
    }

    // Proven half — only assertable after the user hit "Run full test".
    get provenComplete() {
        const t = this.testResult;
        return !!t && !!t.tokenMinted && !!t.auraSessionReady && (t.emailWorkspaceCount || 0) > 0;
    }

    // The one detection flag the banner keys off. Presence alone is "looks done";
    // presence + proven is "confirmed done". Either collapses the walkthrough.
    get setupComplete() {
        return this.provenComplete || (this.presenceComplete && !this.testResult);
    }

    // Show the step list when setup is NOT complete, or when the user chose to reveal it.
    get showWalkthrough() { return !this.setupComplete || this.showSetupSteps; }

    get setupBannerClass() {
        return this.setupComplete ? 'setup-banner setup-banner_ok' : 'setup-banner setup-banner_todo';
    }
    get setupBannerText() {
        if (this.setupComplete) { return 'All setup items configured.'; }
        return 'Finish setup — complete the steps below, then run the full test.';
    }
    // Count only DETECTABLE incomplete rows; manual guidance rows (publish/activate, Agent Access)
    // aren't verifiable from the panel, so they never block "setup complete".
    get remainingCount() { return this.readinessRows.filter((r) => !r.ok && !r.manual).length; }
    get toggleLabel()    { return this.showSetupSteps ? 'Hide steps' : 'Show steps'; }

    // ── Full-test result: one-line summary always visible; diagnostic behind a details toggle. ──
    get testSummaryText() {
        const t = this.testResult;
        if (!t) { return ''; }
        return t.success ? 'Passed — auth, workspace, and Aura all green.'
                         : 'Attention needed — see details.';
    }
    get testSummaryClass() {
        const t = this.testResult;
        return (t && t.success) ? 'test-summary test-summary_ok' : 'test-summary test-summary_fail';
    }
    get testRanAtLabel() {
        return this.testRanAt
            ? 'Last run ' + this.testRanAt.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
            : '';
    }
    get testDetailsLabel() { return this.showTestDetails ? 'Hide details' : 'Show details'; }

    // Email-capable workspaces from the full test, recommended one marked. Read-only; override is
    // set on the config record in Setup, not here.
    get workspaceRows() {
        const t = this.testResult;
        if (!t || !t.workspacesJson) { return []; }
        let list = [];
        try { list = JSON.parse(t.workspacesJson) || []; } catch (e) { return []; }
        return list.map((w) => {
            const recommended = w.id === t.recommendedWorkspaceId;
            return {
                id: w.id,
                name: w.name || w.apiName || w.id,
                recommended,
                badge: recommended ? 'Auto-selected' : '',
                rowClass: recommended ? 'ws-row ws-row_pick' : 'ws-row'
            };
        });
    }
    get hasWorkspaceRows() { return this.workspaceRows.length > 0; }
    // Environment health — tri-state (ok/warn/fail) rows. The Apex probes (Data Cloud, workspace,
    // brands) come from getEnvHealth (SOQL, no callout); scoring CI and profile data graph are added
    // here from the GraphQL wire and the PersonalizationPoint data tab 1 already loaded, since neither
    // is Apex-SOQL-able in this org.
    get envHealthRows() {
        const rows = [...(this.envHealth || [])];

        if (this.ciLoaded) {
            rows.push(this.ciScoring
                ? { key: 'ci', label: 'Scoring insight', status: 'ok', detail: 'scoring CI present' }
                : this.ciTotal > 0
                    ? { key: 'ci', label: 'Scoring insight', status: 'warn', detail: this.ciTotal + ' CI(s), none scoring' }
                    : { key: 'ci', label: 'Scoring insight', status: 'warn', detail: 'no calculated insights' });
        }

        const graphs = new Set(this.pps.map((p) => p.dataGraphId).filter(Boolean));
        if (graphs.size > 0) {
            rows.push({ key: 'dg', label: 'Profile data graph', status: 'ok', detail: graphs.size + ' in use' });
        } else if (this.pps.length > 0) {
            rows.push({ key: 'dg', label: 'Profile data graph', status: 'warn', detail: 'none bound to this content' });
        }

        // Image-catalog readiness — whether the org has enough distinct images for IMAGE dynamic content
        // (swap a picture per audience). ok when >= floor, warn when too few/none. Own probe (callout).
        if (this.imageHealth) { rows.push(this.imageHealth); }

        return rows.map((r) => {
            const s = r.status === 'ok' ? 'ok' : r.status === 'fail' ? 'fail' : 'warn';
            const text = s === 'ok' ? 'OK' : s === 'fail' ? 'Fail' : 'Warn';
            return {
                ...r,
                rowClass: 'qa-row qa-row_' + s,
                statusClass: 'qa-status qa-status_' + s,
                statusText: text
            };
        });
    }
    get hasEnvHealth() { return this.envHealthRows.length > 0; }

    // ── Read-only browse dropdowns (replace the brands/workspace count rows) ──
    get brandOptions() {
        return (this.brands || []).map((b) => ({ label: b.name, value: b.id }));
    }
    get workspaceOptions() {
        return (this.workspaces || []).map((w) => ({ label: w.name, value: w.id }));
    }
    get brandDropdownLabel() { return 'Brands available (' + (this.brands || []).length + ')'; }
    get workspaceDropdownLabel() { return 'CMS workspaces (' + (this.workspaces || []).length + ')'; }
    get hasBrands() { return (this.brands || []).length > 0; }
    get hasWorkspaces() { return (this.workspaces || []).length > 0; }
    handleBrandChange(e) { this.selectedBrand = e.detail.value; }
    handleWorkspaceChange(e) { this.selectedWorkspace = e.detail.value; }

    get selectedModels() {
        return ((this.models && this.models.selected) || []).map((m) => ({
            ...m, friendly: friendlyModel(m.model)
        }));
    }
    get catalogSetupUrl() { return (this.models && this.models.catalogSetupUrl) || null; }
}

// Map an SF-managed model API name to a friendly "Provider - Model" label.
function friendlyModel(apiName) {
    if (!apiName) { return apiName; }
    const map = {
        sfdc_ai__DefaultOpenAIGPT4Omni: 'OpenAI - GPT-4o',
        sfdc_ai__DefaultOpenAIGPT4OmniMini: 'OpenAI - GPT-4o mini',
        sfdc_ai__DefaultGPT4: 'OpenAI - GPT-4',
        sfdc_ai__DefaultGPT35Turbo: 'OpenAI - GPT-3.5 Turbo',
        sfdc_ai__DefaultBedrockAnthropicClaude45Sonnet: 'Anthropic (Bedrock) - Claude Sonnet 4.5',
        sfdc_ai__DefaultBedrockAnthropicClaude45Haiku: 'Anthropic (Bedrock) - Claude Haiku 4.5',
        sfdc_ai__DefaultBedrockAnthropicClaude35Sonnet: 'Anthropic (Bedrock) - Claude 3.5 Sonnet',
        sfdc_ai__DefaultBedrockAnthropicClaude3Haiku: 'Anthropic (Bedrock) - Claude 3 Haiku',
        sfdc_ai__DefaultVertexAIGemini25Flash: 'Google (Vertex) - Gemini 2.5 Flash'
    };
    return map[apiName] || apiName;
}
