// Shared JSON-normalization helper for the DC agent's LLM-authored inputs. More capable models
// (Claude Sonnet 4.5 / Haiku 4.5) sometimes wrap JSON output in a markdown code fence
// (```json ... ```) even when the prompt forbids it, which makes a raw JSON.deserializeUntyped throw
// "Unexpected character ('`' (code 96)) at input location [1,2]". Every action that ingests an
// LLM-authored JSON string runs it through stripFence first. Pure string op -- no callout, no DML.
public with sharing class AuraPocJson {

    // Remove a surrounding markdown code fence (```lang ... ```) or a bare backtick run, if present.
    // Idempotent and null-safe: a string with no fence comes back trimmed but otherwise unchanged, so
    // it is safe to wrap every parse site unconditionally.
    public static String stripFence(String raw) {
        if (raw == null) { return null; }
        String s = raw.trim();
        if (String.isEmpty(s)) { return s; }

        // Opening fence: one or more backticks, an optional language tag (json, JSON, ...), then EOL.
        // Strip it and the matching trailing backtick run.
        if (s.startsWith('`')) {
            // Drop the leading backtick run.
            Integer i = 0;
            while (i < s.length() && s.charAt(i) == 96) { i++; }
            s = s.substring(i);
            // Drop an optional language tag on the opening fence (e.g. "json"), whether it is
            // followed by a newline (fence on its own line) or a space (fence inline with content).
            // A short leading alpha run before the first { or [ is a language hint, not content.
            Matcher lang = Pattern.compile('^[A-Za-z]{1,12}(?=\\s*[\\{\\[])').matcher(s);
            if (lang.find()) {
                s = s.substring(lang.end());
            } else {
                // No JSON delimiter right after the tag -> fall back to dropping a leading tag line.
                Integer nl = s.indexOf('\n');
                if (nl != -1) {
                    String firstLine = s.substring(0, nl).trim();
                    if (firstLine.length() <= 12 && firstLine.replaceAll('[A-Za-z]', '').length() == 0) {
                        s = s.substring(nl + 1);
                    }
                }
            }
            // Drop any trailing backtick run (and whitespace after it).
            s = s.trim();
            Integer j = s.length();
            while (j > 0 && s.charAt(j - 1) == 96) { j--; }
            s = s.substring(0, j);
        }
        return s.trim();
    }
}
