//! Deterministic text post-processing for final transcripts.
//!
//! Whisper already handles most punctuation and capitalization, so this stays
//! intentionally light: whitespace normalization, optional filler removal, and
//! a single leading-capital fix.

/// Clean up a final transcript.
///
/// - trims surrounding whitespace
/// - collapses runs of whitespace into a single space
/// - optionally removes standalone filler words (um, uh, erm)
/// - capitalizes the first alphabetic character
pub fn clean(text: &str, remove_fillers: bool) -> String {
    let mut s = collapse_whitespace(text.trim());
    if remove_fillers {
        s = strip_fillers(&s);
    }
    capitalize_first(&s)
}

/// Collapse any run of whitespace into a single ASCII space.
fn collapse_whitespace(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Words considered fillers when they appear as standalone tokens.
const FILLERS: &[&str] = &["um", "uh", "erm", "uhh", "umm"];

/// Remove standalone filler tokens. A token whose alphabetic core is a filler
/// is dropped, but any sentence-ending punctuation it carried (. ! ?) is
/// preserved so we don't lose sentence boundaries (e.g. "well uh." -> "well.").
/// Other attached punctuation (e.g. a disfluency comma) is dropped with it.
fn strip_fillers(text: &str) -> String {
    let mut kept: Vec<String> = Vec::new();
    for tok in text.split_whitespace() {
        let core: String = tok
            .chars()
            .filter(|c| c.is_alphabetic())
            .collect::<String>()
            .to_lowercase();

        if FILLERS.contains(&core.as_str()) {
            // Preserve only sentence-ending punctuation from the dropped token,
            // appending it to the previous kept token.
            let tail: String = tok.chars().filter(|c| matches!(c, '.' | '!' | '?')).collect();
            if !tail.is_empty() {
                if let Some(last) = kept.last_mut() {
                    last.push_str(&tail);
                } else {
                    kept.push(tail);
                }
            }
        } else {
            kept.push(tok.to_string());
        }
    }

    let joined = kept.join(" ");
    // Fix " ," / " ." style artifacts left by removing a token before punctuation.
    fix_space_before_punct(&joined)
}

/// Remove spaces that immediately precede common punctuation.
fn fix_space_before_punct(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        if matches!(c, ',' | '.' | '!' | '?' | ';' | ':') {
            while out.ends_with(' ') {
                out.pop();
            }
        }
        out.push(c);
    }
    // Collapse any double spaces introduced and trim.
    collapse_whitespace(out.trim())
}

/// Capitalize the first alphabetic character of the string, leaving the rest
/// untouched. No-op if the first letter is already uppercase or absent.
fn capitalize_first(text: &str) -> String {
    let mut chars = text.chars();
    let mut out = String::with_capacity(text.len());
    let mut capitalized = false;
    for c in chars.by_ref() {
        if !capitalized && c.is_alphabetic() {
            out.extend(c.to_uppercase());
            capitalized = true;
        } else {
            out.push(c);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trims_and_collapses_whitespace() {
        assert_eq!(clean("  hello   world  ", false), "Hello world");
        assert_eq!(clean("hello\n\tworld", false), "Hello world");
    }

    #[test]
    fn capitalizes_first_letter() {
        assert_eq!(clean("hello world.", false), "Hello world.");
        assert_eq!(clean("\"quoted\" start", false), "\"Quoted\" start");
    }

    #[test]
    fn already_capitalized_is_unchanged() {
        assert_eq!(clean("Hello world.", false), "Hello world.");
    }

    #[test]
    fn empty_stays_empty() {
        assert_eq!(clean("", false), "");
        assert_eq!(clean("   ", false), "");
    }

    #[test]
    fn removes_fillers_when_enabled() {
        assert_eq!(clean("um hello uh world", true), "Hello world");
        assert_eq!(clean("so uh, the thing", true), "So the thing");
    }

    #[test]
    fn keeps_fillers_when_disabled() {
        assert_eq!(clean("um hello uh world", false), "Um hello uh world");
    }

    #[test]
    fn filler_substring_is_not_removed() {
        // "umbrella" contains "um" but must not be dropped.
        assert_eq!(clean("the umbrella", true), "The umbrella");
        assert_eq!(clean("uhuh maybe", true), "Uhuh maybe");
    }

    #[test]
    fn removing_filler_before_punct_cleans_space() {
        assert_eq!(clean("well uh.", true), "Well.");
    }
}
