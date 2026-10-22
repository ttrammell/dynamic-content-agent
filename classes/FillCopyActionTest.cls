@IsTest
private class FillCopyActionTest {

    // A SlotFiller that always returns the SAME string -- simulates the real-world failure mode where
    // the fill model keeps returning one generic tagline for every segment, so the re-roll layer can
    // NEVER break the collision. This forces the DETERMINISTIC fallback in dedupeHeadingVariants to be
    // the thing that guarantees distinct headings. (No live LLM callout -- the @TestVisible `filler`
    // seam is swapped for this mock.)
    private class CollidingFiller implements FillCopyAction.SlotFiller {
        private String canned;
        CollidingFiller(String s) { this.canned = s; }
        public String fill(String theme, String voice, String spec, String goal, String ruleCase, String language) {
            return this.canned;
        }
    }

    // The core guarantee: even when every re-roll returns an identical heading, the output is distinct.
    @IsTest
    static void deterministicFallbackGuaranteesDistinctHeadings() {
        String collide = 'Smart connectivity built for your everyday needs.';
        FillCopyAction.filler = new CollidingFiller(collide);

        Map<String, Object> byP = new Map<String, Object>{
            'jobtitle_ceo'             => collide,
            'jobtitle_cto'             => collide,
            'jobtitle_it_manager'      => collide,
            'jobtitle_product_manager' => collide,
            'jobtitle_operations'      => collide
        };
        Map<String, String> labelByName = new Map<String, String>{
            'jobtitle_ceo'             => 'CEO',
            'jobtitle_cto'             => 'CTO',
            'jobtitle_it_manager'      => 'IT Manager',
            'jobtitle_product_manager' => 'Product Manager',
            'jobtitle_operations'      => 'Operations'
        };
        Map<String, String> empty = new Map<String, String>();

        Test.startTest();
        FillCopyAction.dedupeHeadingVariants(
            byP, empty, empty, labelByName,
            'Welo High Tech role-based solutions', 'confident, modern',
            'Element type: heading. Target length: short, under 12 words.',
            'A short role-based connectivity headline',
            collide,                 // default heading (also seeds "taken")
            true                     // hasNameAxis (skip name-token stripping)
        );
        Test.stopTest();

        // Every heading must be distinct (case-insensitive) -- the whole point of the fix.
        Set<String> distinct = new Set<String>();
        for (String k : byP.keySet()) {
            distinct.add(String.valueOf(byP.get(k)).trim().toLowerCase());
        }
        System.assertEquals(5, distinct.size(),
            'All 5 heading variants must be distinct even when the model keeps colliding. Got: ' + byP.values());

        // And none may equal the seeded default collide string verbatim (that was the inert bug).
        for (String k : byP.keySet()) {
            System.assertNotEquals(collide.toLowerCase(), String.valueOf(byP.get(k)).trim().toLowerCase(),
                'Variant ' + k + ' still equals the generic default heading -- fallback did not fire.');
        }

        // The deterministic fallback appends the segment label; at least the colliding ones should
        // carry their role label so the uniqueness is meaningful, not random.
        System.assert(String.valueOf(byP.get('jobtitle_cto')).contains('CTO'),
            'Fallback should anchor the CTO variant to its role label. Got: ' + byP.get('jobtitle_cto'));
    }

    // Guard the numeric-discriminator branch: if two decisions share the SAME label (the planner
    // sometimes collapses names), the fallback must STILL produce distinct strings via "(n)".
    @IsTest
    static void fallbackDisambiguatesDuplicateLabels() {
        String collide = 'One Heading To Rule Them All';
        FillCopyAction.filler = new CollidingFiller(collide);

        Map<String, Object> byP = new Map<String, Object>{
            'd1' => collide, 'd2' => collide, 'd3' => collide
        };
        Map<String, String> sameLabel = new Map<String, String>{
            'd1' => 'Leader', 'd2' => 'Leader', 'd3' => 'Leader'    // deliberately identical labels
        };
        Map<String, String> empty = new Map<String, String>();

        Test.startTest();
        FillCopyAction.dedupeHeadingVariants(
            byP, empty, empty, sameLabel,
            'theme', 'voice', 'Element type: heading.', 'goal', collide, true
        );
        Test.stopTest();

        Set<String> distinct = new Set<String>();
        for (String k : byP.keySet()) {
            distinct.add(String.valueOf(byP.get(k)).trim().toLowerCase());
        }
        System.assertEquals(3, distinct.size(),
            'Even with identical labels, the numeric discriminator must keep all variants distinct. Got: ' + byP.values());
    }
}
