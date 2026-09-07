// Deterministic per-cell copy generator -- replaces the monolithic Write Email Copy step.
//
// Instead of one LLM call that must emit the ENTIRE copy matrix (every slot's default plus a
// byPersonalization entry for every decision) in one JSON blob -- which GPT-4o-mini repeatedly
// under-fills, stalling the build -- this action DRIVES the loop in Apex and makes one narrow
// LLM call per cell via the AuraPoc_FillSlot prompt template. Coverage is guaranteed by the loop,
// not by the model, so the copy-coverage-gap failure class disappears. The LLM never sees rules,
// slot keys, JSON shape, or reassembly -- it only writes one element's text at a time.
//
// Output is the same copyJson shape Assemble Content Plan already consumes, so nothing downstream
// changes. Follows the "LLM only for creative text, everything else deterministic" rule: which
// cells exist, what audience each targets (RuleCase), and how they're assembled are all Apex.
public with sharing class FillCopyAction {

    // Caps total LLM calls per email. Measured live: ~0.35-0.4s CPU per ConnectApi fill (20 fills =
    // 7.0s CPU; 12 fills + full build = 4.9s CPU), against the synchronous transaction's hard 10s
    // Apex CPU governor -- so the measured SAFE synchronous ceiling is ~24-28 cells. Raised to 35 at
    // the user's request to allow larger multi-lingual emails (e.g. 6-7 text slots x 4 languages).
    // TRADE-OFF: a genuinely large (30+ cell) email can exceed the 10s CPU limit and crash mid-build,
    // which is worse than failing loud here. The durable fix for reliably supporting 35+ is to move
    // this fill loop async (Queueable, 60s CPU) with deferred completion in the agent pipeline -- do
    // that if 30+ cell emails start crashing. Over THIS cap we still fail loud with an actionable
    // message rather than attempt an obviously-too-large build.
    @TestVisible static Integer MAX_CELLS = 35;

    public class Request {
        @InvocableVariable(label='Structure Plan JSON' required=true)
        public String structurePlanJson;

        @InvocableVariable(label='Brand Voice')
        public String brandVoice;

        // The user's actual request, bound from the agent's captured intent variable -- NOT the
        // LLM's echo inside the plan JSON. Confirmed live: on a cold first turn the plan LLM can
        // set fullTranslate:false AND omit the userIntent echo, so a "multi-lingual email" request
        // built static. Passing the real intent here makes the full-translate keyword backstop fire
        // deterministically regardless of what the plan LLM emitted. Overrides the echoed userIntent.
        @InvocableVariable(label='User Intent')
        public String userIntent;
    }

    public class Result {
        @InvocableVariable(label='Success')
        public Boolean success;

        @InvocableVariable(label='Copy JSON')
        public String copyJson;

        // The (possibly full-translate-normalized) structure plan this fill actually ran against.
        // When a full-translate request injects the Country PersonalizationPoint across every text
        // slot, that injection happens HERE (the first consumer of the plan) so the per-language
        // copy cells get filled -- and the SAME normalized plan must then flow to Assemble Content
        // Plan, or assemble would emit the un-injected (static) plan and the email would ship
        // English-only while the summary promised translations. The agent binds
        // base_content_structurePlanJson to this so both stages see one plan. ALWAYS non-empty
        // (defaults to the input plan verbatim when nothing was injected) so the caller can bind
        // it unconditionally without risk of wiping the plan.
        @InvocableVariable(label='Normalized Plan JSON')
        public String normalizedPlanJson;

        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    // Test seam -- ConnectApi.EinsteinLLM can't be intercepted by HttpCalloutMock, same constraint
    // the token-exchange actions document. Tests swap in a stub SlotFiller.
    public interface SlotFiller {
        String fill(String theme, String voice, String spec, String goal, String ruleCase, String language);
    }

    public class LlmSlotFiller implements SlotFiller {
        public String fill(String theme, String voice, String spec, String goal, String ruleCase, String language) {
            // A GenAiPromptTemplate allows at most 5 custom inputs and FillSlot already uses all 5,
            // so the target language can't be its own input -- fold it into the front of SlotSpec
            // (which the template reads as a top-priority directive) when it's a non-English variant.
            String specWithLang = spec;
            if (String.isNotBlank(language) && language.trim().toLowerCase() != 'english') {
                specWithLang = 'WRITE THIS ELEMENT ENTIRELY IN ' + language.toUpperCase()
                    + ' -- every word in ' + language + ', ZERO English (keep any {{merge tokens}} verbatim). '
                    + spec;
            }
            Map<String, ConnectApi.WrappedValue> valueMap = new Map<String, ConnectApi.WrappedValue>();
            Map<String, String> ins = new Map<String, String>{
                'Input:Theme'      => blankTo(theme, 'a marketing email'),
                'Input:BrandVoice' => blankTo(voice, 'None available'),
                'Input:SlotSpec'   => specWithLang,
                'Input:SlotGoal'   => blankTo(goal, 'write appropriate copy for this element'),
                'Input:RuleCase'   => blankTo(ruleCase, 'a general audience')
            };
            for (String k : ins.keySet()) {
                ConnectApi.WrappedValue w = new ConnectApi.WrappedValue();
                w.value = ins.get(k);
                valueMap.put(k, w);
            }
            ConnectApi.EinsteinPromptTemplateGenerationsInput inp = new ConnectApi.EinsteinPromptTemplateGenerationsInput();
            inp.isPreview = false;
            inp.inputParams = valueMap;
            inp.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
            // Required -- without it the service returns a generic failure that masks real errors.
            inp.additionalConfig.applicationName = 'PromptTemplateGenerationsInvocable';
            ConnectApi.EinsteinPromptTemplateGenerationsRepresentation o =
                ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate('AuraPoc_FillSlot', inp);
            String text = (o != null && o.generations != null && !o.generations.isEmpty())
                ? o.generations[0].text : '';
            return text == null ? '' : text.trim();
        }
    }

    @TestVisible static SlotFiller filler = new LlmSlotFiller();

    // GPT-4o-mini (the FillSlot model) occasionally REFUSES a cell -- returns "I don't know",
    // an apology, or empty -- especially on a non-English (translation) cell. Detect that and
    // retry once; a single narrow retry almost always yields real copy, and it's cheap relative
    // to the per-email cell cap. Never ship a refusal as the shipped copy.
    private static Boolean looksLikeRefusal(String t) {
        if (String.isBlank(t)) { return true; }
        String s = t.trim().toLowerCase();
        return s.startsWith('i don\'t know') || s.startsWith('i dont know')
            || s.startsWith('i\'m sorry') || s.startsWith('i am sorry') || s.startsWith('sorry,')
            || s.startsWith('i cannot') || s.startsWith('i can\'t') || s.startsWith('i can not')
            || s.startsWith('as an ai') || s.startsWith('unable to') || s == 'n/a';
    }

    // Single fill entry point everywhere below -- adds the language directive and a one-shot
    // refusal retry so callers don't repeat either. language is the language THIS cell must be
    // written in ("English" for the base/default and meta copy, or the recipient country's
    // language for a translation variant).
    private static String fillCell(String theme, String voice, String spec, String goal, String ruleCase, String language) {
        String text = filler.fill(theme, voice, spec, goal, ruleCase, language);
        if (looksLikeRefusal(text)) {
            text = filler.fill(theme, voice, spec, goal, ruleCase, language);
        }
        return text == null ? '' : text.trim();
    }

    // The language a given personalization decision's copy must be written in: the recipient
    // country's language for a Country decision (English for US/UK), else the base language.
    private static String fillLanguageFor(Map<String, Object> p) {
        String fieldApi = String.valueOf(p.get('fieldApiName'));
        if (fieldApi != null && fieldApi.toLowerCase().contains('country')) {
            String label = p.get('label') != null ? String.valueOf(p.get('label')) : '';
            String v = strOf(p.get('value'), label);
            if (p.get('values') instanceof List<Object>) {
                List<Object> vals = (List<Object>) p.get('values');
                if (!vals.isEmpty()) { v = String.valueOf(vals[0]); }
            }
            String lang = languageForCountry(v);
            if (String.isBlank(lang)) { lang = languageForCountry(label); }
            if (String.isNotBlank(lang)) { return lang; }
        }
        return 'English';
    }

    private static final Map<String, String> TYPE_TO_SPEC = new Map<String, String>{
        'heading'   => 'Element type: heading. Target length: short, under 10 words.',
        'paragraph' => 'Element type: paragraph. Target length: 1 to 2 sentences.',
        'button'    => 'Element type: button label. Target length: 2 to 4 words.'
    };

    // Appended to the title/subject/preheader specs: these three render outside the data-graph
    // context, so a merge token in them hard-fails the build. Slot body copy never gets this.
    private static final String NO_TOKEN_SPEC =
        ' IMPORTANT: write plain text only -- do NOT include any merge token or {{...}} placeholder '
        + '(no {{FirstName}}, {{LastName}}, {{AccountName}}, etc.); this element cannot resolve them.';

    // Deterministic backstop for the above: remove any merge token that slipped into a meta field.
    // {{x|fallback}} -> fallback; {{x}} -> removed; then tidy orphaned spaces/greeting punctuation
    // so "Hi {{FirstName}}, join us" -> "Hi, join us" and "{{FirstName}}, welcome" -> "welcome".
    @TestVisible
    static String stripMergeTokens(String s) {
        if (String.isBlank(s)) { return s; }
        s = s.replaceAll('\\{\\{[^{}|]*\\|([^{}]*)\\}\\}', '$1');  // keep the fallback
        s = s.replaceAll('\\{\\{[^{}]*\\}\\}', '');                // drop the token
        s = s.replaceAll('\\s+', ' ');                            // collapse whitespace
        s = s.replaceAll(' +([,.!?;:])', '$1');                   // no space before punctuation
        s = s.replaceAll('([,;:])\\s*([.!?,;:])', '$2');          // collapse orphaned punct runs ("Save now,!" -> "Save now!")
        s = s.replaceAll('^[\\s,;:.!?\\-]+', '');                 // no leading punctuation
        s = s.replaceAll('[\\s,;:\\-]+$', '');                    // no trailing punctuation
        return s.trim();
    }

    static String blankTo(String s, String dflt) { return String.isBlank(s) ? dflt : s; }

    private static String strOf(Object o, String dflt) {
        return (o == null || String.isBlank(String.valueOf(o))) ? dflt : String.valueOf(o);
    }

    // Best-effort human field label for the RuleCase sentence: ssot__PrimaryIndustry__c -> "PrimaryIndustry".
    private static String humanizeField(String fieldApiName) {
        String f = String.isBlank(fieldApiName) ? 'attribute' : fieldApiName;
        if (f.startsWith('ssot__')) { f = f.substring(6); }
        if (f.endsWith('__c')) { f = f.substring(0, f.length() - 3); }
        if (f.endsWith('Id') && f.length() > 2) { f = f.substring(0, f.length() - 2); }
        return String.isBlank(f) ? 'attribute' : f;
    }

    // For name/company fields, the personalization inserts the recipient's actual value via a merge
    // token the send resolves -- NOT static text. Returns the token FillSlot must embed, else ''.
    private static String mergeTokenFor(String fieldApiName) {
        String f = (fieldApiName == null ? '' : fieldApiName).toLowerCase();
        if (f.contains('firstname')) { return '{{FirstName}}'; }
        if (f.contains('lastname')) { return '{{LastName}}'; }
        if (f.contains('companyname') || f.contains('accountname')) { return '{{AccountName}}'; }
        return '';
    }

    // Built-in "customize by language" use case: DC keys on the recipient's Country
    // (ssot__CountryId__c) and each country's variant copy is WRITTEN in that country's language.
    // English-speaking countries (US/UK) stay in the default English -- no special instruction.
    // Accepts either a country form (US, FR, Japan, ...) OR a language name (French, ...) as the
    // decision value, so both the country-keyed and the full-translate use cases resolve.
    private static final Map<String, String> COUNTRY_TO_LANGUAGE = new Map<String, String>{
        'us' => 'English', 'usa' => 'English', 'united states' => 'English', 'united states of america' => 'English',
        'gb' => 'English', 'uk' => 'English', 'united kingdom' => 'English', 'great britain' => 'English', 'england' => 'English', 'en' => 'English', 'eng' => 'English', 'english' => 'English',
        'jp' => 'Japanese', 'jpn' => 'Japanese', 'japan' => 'Japanese', 'ja' => 'Japanese', 'japanese' => 'Japanese',
        'fr' => 'French', 'fra' => 'French', 'france' => 'French', 'french' => 'French',
        'es' => 'Spanish', 'esp' => 'Spanish', 'sp' => 'Spanish', 'spain' => 'Spanish', 'espana' => 'Spanish', 'mx' => 'Spanish', 'mexico' => 'Spanish', 'spanish' => 'Spanish',
        'de' => 'German', 'deu' => 'German', 'germany' => 'German', 'deutschland' => 'German', 'german' => 'German',
        'it' => 'Italian', 'ita' => 'Italian', 'italy' => 'Italian', 'italia' => 'Italian', 'italian' => 'Italian',
        'br' => 'Portuguese', 'bra' => 'Portuguese', 'brazil' => 'Portuguese', 'brasil' => 'Portuguese', 'pt' => 'Portuguese', 'portugal' => 'Portuguese', 'portuguese' => 'Portuguese',
        'cn' => 'Chinese', 'chn' => 'Chinese', 'china' => 'Chinese', 'zh' => 'Chinese', 'chinese' => 'Chinese',
        'kr' => 'Korean', 'kor' => 'Korean', 'korea' => 'Korean', 'south korea' => 'Korean', 'ko' => 'Korean', 'korean' => 'Korean'
    };
    private static String languageForCountry(String v) {
        if (String.isBlank(v)) { return ''; }
        String key = v.trim().toLowerCase();
        return COUNTRY_TO_LANGUAGE.containsKey(key) ? COUNTRY_TO_LANGUAGE.get(key) : '';
    }

    // ---- Full-translate ("multi-lingual email") intent + deterministic PP injection ------------
    // Translation is one of this agent's two core jobs (the other is dynamic content). A whole-
    // email translate is a SINGLE Country personalization axis applied to EVERY text slot -- but
    // asking the plan LLM to hand-emit that axis (one decision per country, every slot listed in
    // appliesToSlots) proved flaky: on some passes it emitted an empty personalizations array and
    // the email shipped English-only while the summary still promised translations. So the LLM now
    // only signals INTENT (a top-level fullTranslate boolean + optional translateCountries), and
    // this class builds the Country PP deterministically -- the fragile structured part is no
    // longer the model's job. Default languages: French, Spanish, Japanese (English is the
    // untranslated base/default, so it needs no decision).
    private static final List<String> DEFAULT_TRANSLATE_COUNTRIES = new List<String>{ 'FR', 'ES', 'JP' };

    // Deterministic backstop so natural phrasing sets full-translate even when the LLM omits the
    // boolean: scan the verbatim user intent the plan prompt echoes back. Kept literal + narrow to
    // avoid false positives; only consulted when the plan has NO explicit fullTranslate flag (an
    // explicit false -- a deliberate localize-just-a-section plan -- is always respected).
    @TestVisible
    static Boolean intentAsksFullTranslate(String intent) {
        if (String.isBlank(intent)) { return false; }
        String s = intent.toLowerCase();
        return s.contains('translate')            // translate / translated / translation
            || s.contains('multilingual')
            || s.contains('multi-lingual')
            || s.contains('multi lingual')
            || s.contains('multi-language')
            || s.contains('multi language')
            || s.contains('multiple languages')
            || s.contains('several languages')
            || s.contains('different languages')
            || s.contains('each language')
            || s.contains('every language')
            || s.contains('localize the whole') || s.contains('localise the whole')
            || s.contains('localize the entire') || s.contains('localise the entire');
    }

    // Does the plan carry any personalization axis OTHER than Country? Such a plan is a NORMAL
    // multi-axis email (industry/tier/name/etc.) -- translation there is a confined one-area
    // section, NOT a whole-email one-Country-axis full translate. Used to keep a mixed
    // "personalize AND translate" request in normal mode instead of collapsing it to full-translate
    // (which is exclusive: one Country axis across every slot, no other personalization).
    private static Boolean hasNonCountryAxis(Map<String, Object> plan) {
        List<Object> pers = plan.get('personalizations') instanceof List<Object>
            ? (List<Object>) plan.get('personalizations') : new List<Object>();
        for (Object pObj : pers) {
            if (pObj instanceof Map<String, Object>) {
                String f = String.valueOf(((Map<String, Object>) pObj).get('fieldApiName')).toLowerCase();
                if (String.isNotBlank(f) && !f.contains('country')) { return true; }
            }
        }
        return false;
    }

    // Resolve whether THIS plan is a WHOLE-EMAIL translate (full-translate = one Country axis, one
    // PP, N language OPs, spanning every text slot -- and NOTHING else). Distinct from normal mode,
    // where multiple axes (industry/tier/name) coexist and translation, if any, is confined to one
    // section (a single-slot Country PP the LLM emits like any other axis).
    //   - Explicit fullTranslate == true always wins (the LLM deliberately chose whole-email).
    //   - Keyword backstop (translate/multi-lingual phrasing) overrides a lazy/omitted flag ONLY
    //     when the plan has no other axis -- so "multi-lingual email" fires even if the model left
    //     the default false, but "personalize by industry AND translate" stays NORMAL mode (its
    //     industry axis would be wiped by the exclusive full-translate injection otherwise).
    //   - Otherwise respect the explicit flag (false), i.e. normal mode.
    @TestVisible
    static Boolean isFullTranslate(Map<String, Object> plan) {
        Object flag = plan.get('fullTranslate');
        if (flag instanceof Boolean && (Boolean) flag) { return true; }
        if (intentAsksFullTranslate(String.valueOf(plan.get('userIntent'))) && !hasNonCountryAxis(plan)) {
            return true;
        }
        return (flag instanceof Boolean) ? (Boolean) flag : false;
    }

    // The country list to translate into: whatever the plan named, else the default set. English-
    // speaking countries are kept out of the decision list here (English is the base/default copy).
    private static List<String> translateCountries(Map<String, Object> plan) {
        List<String> out = new List<String>();
        Object tc = plan.get('translateCountries');
        if (tc instanceof List<Object>) {
            for (Object o : (List<Object>) tc) {
                String c = String.valueOf(o).trim();
                if (String.isNotBlank(c)) { out.add(c); }
            }
        }
        return out.isEmpty() ? DEFAULT_TRANSLATE_COUNTRIES.clone() : out;
    }

    // Build the single Country PersonalizationPoint (one Equals decision per non-English country)
    // applied to every text slot, and REPLACE any LLM-emitted personalizations with it. Replace,
    // not merge: full-translate covers all text slots, so any other per-slot axis would collide
    // ("one axis per slot") -- the deterministic language axis wins for a whole-email translate.
    // Returns the list of injected personalization Maps (empty if there are no text slots or every
    // requested country is English -- in which case nothing needs translating).
    private static List<Object> buildLanguagePersonalizations(List<Object> slots, List<String> countries) {
        List<Object> textSlotKeys = new List<Object>();
        for (Object sObj : slots) {
            Map<String, Object> s = (Map<String, Object>) sObj;
            if (String.valueOf(s.get('type')) != 'image') { textSlotKeys.add(String.valueOf(s.get('key'))); }
        }
        List<Object> langPers = new List<Object>();
        if (textSlotKeys.isEmpty()) { return langPers; }
        Set<String> usedNames = new Set<String>();
        for (String c : countries) {
            String lang = languageForCountry(c);
            if (lang == 'English') { continue; }        // English is the untranslated base -- no decision
            if (String.isBlank(lang)) { lang = c; }      // unknown country -> still translate, name it verbatim
            String nm = 'lang_' + c.toLowerCase().replaceAll('[^a-z0-9]+', '_');
            if (!usedNames.add(nm)) { continue; }
            langPers.add(new Map<String, Object>{
                'name' => nm,
                'label' => lang + ' (' + c + ')',
                'fieldApiName' => 'ssot__CountryId__c',
                'scope' => 'RecipientAddress',
                'matchType' => 'Equals',
                'value' => c,
                'appliesToSlots' => textSlotKeys.clone()
            });
        }
        return langPers;
    }

    // Deterministically turn a personalization decision into a plain-language audience description
    // for the fill prompt -- the LLM never parses the rule structure itself. For name/company
    // fields it also tells FillSlot to embed the merge token (fixes the "Dear ," empty-greeting
    // bug where the fill left the name spot blank).
    private static String buildRuleCase(Map<String, Object> p) {
        String mt = strOf(p.get('matchType'), 'HasValue');
        String fieldApi = String.valueOf(p.get('fieldApiName'));
        String field = humanizeField(fieldApi);
        String label = p.get('label') != null ? String.valueOf(p.get('label')) : '';
        String seg = String.isNotBlank(label) ? (' (segment: ' + label + ')') : '';
        String base;
        if (mt == 'Equals') {
            base = 'recipients whose ' + field + ' is "' + strOf(p.get('value'), label) + '"' + seg;
        } else if (mt == 'In') {
            List<Object> vals = p.get('values') instanceof List<Object> ? (List<Object>) p.get('values') : new List<Object>();
            List<String> ss = new List<String>();
            for (Object v : vals) { ss.add(String.valueOf(v)); }
            String joined = ss.isEmpty() ? label : String.join(ss, ', ');
            base = 'recipients whose ' + field + ' is one of: ' + joined + seg;
        } else {
            base = 'recipients who have a ' + field + ' on file' + seg;
        }
        String token = mergeTokenFor(fieldApi);
        if (String.isNotBlank(token)) {
            base += ' -- address the recipient by their ' + field + ' by writing the exact merge token '
                + token + ' where the value goes (verbatim, double braces); never leave it blank.';
        }
        // Built-in language-by-country: if this decision is on the Country field, write the copy
        // in that country's language (English countries stay English).
        if (fieldApi != null && fieldApi.toLowerCase().contains('country')) {
            String cval = (mt == 'In') ? '' : strOf(p.get('value'), label);
            if (mt == 'In') {
                List<Object> vals = p.get('values') instanceof List<Object> ? (List<Object>) p.get('values') : new List<Object>();
                if (!vals.isEmpty()) { cval = String.valueOf(vals[0]); }
            }
            String lang = languageForCountry(cval);
            if (String.isBlank(lang)) { lang = languageForCountry(label); }
            if (String.isNotBlank(lang) && lang != 'English') {
                base += ' -- IMPORTANT: write this element ENTIRELY in ' + lang + ' (the recipient is in ' + cval
                    + '); do NOT write it in English. Keep any {{merge tokens}} exactly as-is (do not translate tokens).';
            }
        }
        return base;
    }

    private static String buildTheme(Map<String, Object> plan) {
        String combined = (strOf(plan.get('titleGoal'), '') + ' ' + strOf(plan.get('subjectLineGoal'), '')).trim();
        return String.isBlank(combined) ? 'a marketing email' : combined;
    }

    @InvocableMethod(label='Fill Email Copy' description='Deterministically fills every copy cell (each slot default plus one variant per personalization decision) with a narrow per-cell LLM call, guaranteeing complete coverage. Returns the copyJson shape Assemble Content Plan expects. Replaces the monolithic Write Email Copy step -- makes no changes and creates nothing.')
    public static List<Result> fillCopy(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result res = new Result();
            res.success = false;
            res.copyJson = '';
            // Default to the input plan verbatim so the caller can bind base_content_structurePlanJson
            // to this unconditionally -- even on an early error it never wipes the plan.
            res.normalizedPlanJson = req.structurePlanJson;
            res.errorMessage = '';
            try {
                Map<String, Object> plan = (Map<String, Object>) JSON.deserializeUntyped(req.structurePlanJson);
                List<Object> slots = plan.get('slots') instanceof List<Object> ? (List<Object>) plan.get('slots') : new List<Object>();

                // Prefer the REAL user intent (bound from the agent's captured variable) over the
                // plan LLM's echo -- the echo can be missing/paraphrased on a cold turn, which is
                // exactly what let a "multi-lingual email" request slip past full-translate.
                if (String.isNotBlank(req.userIntent)) { plan.put('userIntent', req.userIntent); }

                // Whole-email translate: deterministically inject the one Country PP across every
                // text slot BEFORE anything reads personalizations, so the per-language copy cells
                // get filled below and Assemble Content Plan (fed the same normalized plan) emits
                // the PP. This is the fix for the "summary promised translations but the email
                // built English-only" bug -- the LLM now only signals intent (fullTranslate flag /
                // translate phrasing), never hand-builds the language axis.
                if (isFullTranslate(plan)) {
                    plan.put('personalizations', buildLanguagePersonalizations(slots, translateCountries(plan)));
                    plan.put('fullTranslate', true);
                    res.normalizedPlanJson = JSON.serialize(plan);
                }

                List<Object> pers = plan.get('personalizations') instanceof List<Object> ? (List<Object>) plan.get('personalizations') : new List<Object>();

                // slotKey -> personalizations that apply to it
                Map<String, List<Map<String, Object>>> persBySlot = new Map<String, List<Map<String, Object>>>();
                for (Object pObj : pers) {
                    Map<String, Object> p = (Map<String, Object>) pObj;
                    List<Object> applies = p.get('appliesToSlots') instanceof List<Object> ? (List<Object>) p.get('appliesToSlots') : new List<Object>();
                    for (Object sObj : applies) {
                        String sk = String.valueOf(sObj);
                        if (!persBySlot.containsKey(sk)) { persBySlot.put(sk, new List<Map<String, Object>>()); }
                        persBySlot.get(sk).add(p);
                    }
                }

                // Project the cell count (3 meta + per non-image slot: 1 default + applying decisions)
                Integer cells = 3;
                for (Object sObj : slots) {
                    Map<String, Object> s = (Map<String, Object>) sObj;
                    if (String.valueOf(s.get('type')) == 'image') { continue; }
                    cells += 1;
                    List<Map<String, Object>> ap = persBySlot.get(String.valueOf(s.get('key')));
                    if (ap != null) { cells += ap.size(); }
                }
                if (cells > MAX_CELLS) {
                    res.errorMessage = 'This email needs ' + cells + ' copy pieces (slot text plus one per personalization value), '
                        + 'which exceeds the limit of ' + MAX_CELLS + '. Ask the user to reduce the number of personalization '
                        + 'values or content slots.';
                    results.add(res);
                    continue;
                }

                String theme = buildTheme(plan);
                String voice = req.brandVoice;

                // Meta copy (title / subject / preheader) -- each its own narrow fill.
                // These render OUTSIDE the data-graph context, so a merge token here hard-fails
                // the CMS build ("placeholders not supported in the subject line"). Tell the model
                // plainly (NO_TOKEN_SPEC) and strip any that slip through (stripMergeTokens) --
                // belt-and-suspenders, deterministic. Slot body copy is untouched: {{FirstName}}
                // etc. are legitimate there.
                // Meta copy is the email's BASE (untranslated) layer -- always English; per-language
                // variants live in the slot body cells below.
                String title = stripMergeTokens(fillCell(theme, voice,
                    'Element type: internal email title. Target length: under 12 words.' + NO_TOKEN_SPEC,
                    strOf(plan.get('titleGoal'), 'a concise internal title for this email'), 'a general audience', 'English'));
                String subject = stripMergeTokens(fillCell(theme, voice,
                    'Element type: email subject line. Target length: under 60 characters.' + NO_TOKEN_SPEC,
                    strOf(plan.get('subjectLineGoal'), 'a compelling subject line'), 'a general audience', 'English'));
                String preheader = stripMergeTokens(fillCell(theme, voice,
                    'Element type: email preheader. Target length: under 100 characters.' + NO_TOKEN_SPEC,
                    strOf(plan.get('preheaderGoal'), 'a preheader that complements the subject line'), 'a general audience', 'English'));

                Map<String, Object> copyBySlot = new Map<String, Object>();
                for (Object sObj : slots) {
                    Map<String, Object> s = (Map<String, Object>) sObj;
                    String type = String.valueOf(s.get('type'));
                    if (type == 'image') { continue; }   // images carry a contentKey, not text
                    String key = String.valueOf(s.get('key'));
                    String spec = TYPE_TO_SPEC.containsKey(type) ? TYPE_TO_SPEC.get(type) : TYPE_TO_SPEC.get('paragraph');
                    String goal = strOf(s.get('goal'), 'write appropriate copy for this element');

                    Map<String, Object> slotCopy = new Map<String, Object>();
                    slotCopy.put('default', fillCell(theme, voice, spec, goal, 'a general audience with no specific segment', 'English'));
                    if (type == 'button') {
                        // URL is not an LLM decision -- same testing default the old copy step used.
                        slotCopy.put('url', 'https://www.example.com');
                    }
                    List<Map<String, Object>> ap = persBySlot.get(key);
                    if (ap != null && !ap.isEmpty()) {
                        Map<String, Object> byP = new Map<String, Object>();
                        for (Map<String, Object> p : ap) {
                            byP.put(String.valueOf(p.get('name')),
                                fillCell(theme, voice, spec, goal, buildRuleCase(p), fillLanguageFor(p)));
                        }
                        slotCopy.put('byPersonalization', byP);
                    }
                    copyBySlot.put(key, slotCopy);
                }

                res.copyJson = JSON.serialize(new Map<String, Object>{
                    'title' => title, 'subjectLine' => subject, 'preheader' => preheader, 'copyBySlot' => copyBySlot
                });
                res.success = true;
            } catch (Exception e) {
                res.success = false;
                res.errorMessage = 'Fill Email Copy failed: ' + e.getMessage();
            }
            results.add(res);
        }
        return results;
    }
}
