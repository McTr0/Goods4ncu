//! Reading a photo of a room as a list of things.
//!
//! Graduation is the largest supply event in the academic year and the listing
//! form is at its worst exactly then: twenty items, twenty forms, so none of it
//! is ever posted. One photo of a dorm room is the whole inventory in a single
//! gesture.
//!
//! Three constraints shape this:
//!
//! * **It is optional.** No vision provider configured means the photo path is
//!   simply absent, not broken. Everything else — the text splitter, the model
//!   text path, manual entry — keeps working. A campus that cannot afford a
//!   vision API still gets a product.
//! * **Everything it produces is a draft.** Reading a photo is guesswork of a
//!   higher order than splitting a sentence, and a wrong reading must cost one
//!   dismissal rather than putting six half-understood things in front of the
//!   campus.
//! * **It names things, not conditions.** The model is asked for objects only.
//!   Letting it invent "九成新" or a price would put words in the owner's mouth
//!   about the two things buyers care most about, and neither is visible from a
//!   photo with any reliability.
//!
//! The call goes over plain HTTP rather than through the rig abstraction, which
//! is text-only. Image moderation already talks to a provider this way, so the
//! shape is familiar rather than novel.

use anyhow::Result;
use std::time::Duration;

use crate::services::intent::decompose::{DecomposedItem, Decomposition};
use crate::services::intent::slots::Slots;

/// A photo yielding more than this is a misread, not a dorm room. Confirming
/// thirty cards is worse than filling in one form.
const MAX_ITEMS: usize = 20;
/// Vision is a guess about a picture; lower than the text splitter's, which
/// works from words the author chose.
const CONFIDENCE: f32 = 0.45;
/// Long enough for a large image, short enough that somebody posting does not
/// sit and wait.
const TIMEOUT: Duration = Duration::from_secs(20);
/// Refuse oversized uploads before spending a request on them.
const MAX_IMAGE_BYTES: usize = 6 * 1024 * 1024;

/// Whether a vision provider is configured.
///
/// Checked before offering the photo affordance at all: an button that always
/// fails is worse than no button.
pub fn is_available(gemini_api_key: &str) -> bool {
    !gemini_api_key.trim().is_empty()
}

const PROMPT: &str = "\
列出这张照片里可以出二手的物品。\n\
只输出 JSON：{\"items\":[{\"subject\":\"台灯\"},{\"subject\":\"小冰箱\"}]}\n\
规则：\n\
- subject 只写物品名称，不要写成色、不要写价格、不要写颜色和品牌猜测\n\
- 看不清的不要写\n\
- 墙、地板、天花板这类不属于个人物品的不要写\n\
- 最多 20 条";

#[derive(serde::Deserialize)]
struct VisionItems {
    items: Vec<VisionItem>,
}

#[derive(serde::Deserialize)]
struct VisionItem {
    subject: String,
}

/// Read a photo as a list of items.
///
/// `image_base64` is the raw image, `mime` its type. Returns
/// [`Decomposition::Single`] when nothing usable came back — the caller then
/// records one intent from whatever the author typed, so a failed reading never
/// costs them their post.
pub async fn decompose_photo(
    gemini_api_key: &str,
    image_base64: &str,
    mime: &str,
) -> Result<Decomposition> {
    if !is_available(gemini_api_key) {
        anyhow::bail!("no vision provider configured");
    }
    // Base64 is about 4/3 of the bytes it encodes.
    if image_base64.len() > MAX_IMAGE_BYTES * 4 / 3 {
        anyhow::bail!("image too large");
    }
    if !matches!(mime, "image/jpeg" | "image/png" | "image/webp") {
        anyhow::bail!("unsupported image type: {}", mime);
    }

    let body = serde_json::json!({
        "contents": [{
            "parts": [
                { "text": PROMPT },
                { "inline_data": { "mime_type": mime, "data": image_base64 } }
            ]
        }],
        "generationConfig": { "temperature": 0.1 }
    });

    let url = format!(
        "https://generativelanguage.googleapis.com/v1beta/models/\
         gemini-2.0-flash:generateContent?key={gemini_api_key}"
    );
    let response = reqwest::Client::builder()
        .timeout(TIMEOUT)
        .build()?
        .post(url)
        .header(reqwest::header::CONTENT_TYPE, "application/json")
        .json(&body)
        .send()
        .await?;

    if !response.status().is_success() {
        // Deliberately does not include the response body: a provider error can
        // echo the request, and the request contains someone's photo.
        anyhow::bail!("vision request failed with {}", response.status());
    }

    let payload: serde_json::Value = response.json().await?;
    let text = payload["candidates"][0]["content"]["parts"][0]["text"]
        .as_str()
        .unwrap_or_default();
    Ok(parse_items(text))
}

/// Read the model's reply into items.
///
/// Anything unparseable is [`Decomposition::Single`] rather than an error. A
/// JSON slip should cost the photo path, not the author's post.
pub fn parse_items(reply: &str) -> Decomposition {
    let Some(json) = extract_object(reply) else {
        return Decomposition::Single;
    };
    let Ok(parsed) = serde_json::from_str::<VisionItems>(json) else {
        return Decomposition::Single;
    };

    let mut seen: Vec<String> = Vec::new();
    let items: Vec<DecomposedItem> = parsed
        .items
        .into_iter()
        .filter_map(|item| {
            let subject = item.subject.trim().to_string();
            // Two chairs in one photo are one card, not two: the author says
            // how many, and a duplicate is more likely double-counting than a
            // second item.
            if subject.chars().count() < 2 || seen.contains(&subject) {
                return None;
            }
            seen.push(subject.clone());
            Some(DecomposedItem {
                slots: Slots {
                    subject: Some(subject),
                    // No price, no condition. Neither is visible from a photo
                    // with any reliability, and inventing them puts words in
                    // the owner's mouth about what buyers care most about.
                    ..Default::default()
                },
                confidence: CONFIDENCE,
            })
        })
        .take(MAX_ITEMS)
        .collect();

    if items.is_empty() {
        Decomposition::Single
    } else {
        Decomposition::Several(items)
    }
}

/// Models wrap JSON in prose or fences; take the outermost object.
fn extract_object(reply: &str) -> Option<&str> {
    match (reply.find('{'), reply.rfind('}')) {
        (Some(start), Some(end)) if end > start => Some(&reply[start..=end]),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn subjects(decomposition: &Decomposition) -> Vec<String> {
        match decomposition {
            Decomposition::Single => vec![],
            Decomposition::Several(items) => items
                .iter()
                .map(|i| i.slots.subject.clone().unwrap_or_default())
                .collect(),
        }
    }

    #[test]
    fn a_room_becomes_a_list_of_things() {
        let reply = r#"{"items":[{"subject":"台灯"},{"subject":"小冰箱"},
                        {"subject":"书架"}]}"#;
        assert_eq!(
            subjects(&parse_items(reply)),
            vec!["台灯", "小冰箱", "书架"]
        );
    }

    #[test]
    fn nothing_is_invented_about_condition_or_price() {
        // The two things buyers care most about, and neither is visible from a
        // photo. Guessing would put words in the owner's mouth.
        let Decomposition::Several(items) =
            parse_items(r#"{"items":[{"subject":"台灯"},{"subject":"椅子"}]}"#)
        else {
            panic!("expected several");
        };
        for item in items {
            assert!(item.slots.price.is_none());
            assert!(item.slots.condition_score.is_none());
            assert!(item.slots.category.is_none());
        }
    }

    #[test]
    fn a_repeated_name_is_one_card() {
        // Two chairs in one photo are one card. The author says how many, and a
        // duplicate is more likely double-counting than a second item.
        let reply = r#"{"items":[{"subject":"椅子"},{"subject":"椅子"},
                        {"subject":"台灯"}]}"#;
        assert_eq!(subjects(&parse_items(reply)), vec!["椅子", "台灯"]);
    }

    #[test]
    fn an_unreadable_reply_costs_the_photo_not_the_post() {
        // The caller falls back to recording one intent from what the author
        // typed, so a JSON slip never loses their words.
        for reply in [
            "",
            "抱歉我看不清",
            "{\"items\": broken",
            "{}",
            "{\"items\":[]}",
        ] {
            assert_eq!(parse_items(reply), Decomposition::Single, "reply: {reply}");
        }
    }

    #[test]
    fn a_runaway_reading_is_capped() {
        let many = (0..40)
            .map(|i| format!(r#"{{"subject":"物品{i}"}}"#))
            .collect::<Vec<_>>()
            .join(",");
        let Decomposition::Several(items) = parse_items(&format!(r#"{{"items":[{many}]}}"#)) else {
            panic!("expected several");
        };
        assert_eq!(items.len(), MAX_ITEMS);
    }

    #[test]
    fn json_wrapped_in_prose_is_still_read() {
        let reply = "我看到这些：\n```json\n{\"items\":[{\"subject\":\"台灯\"}]}\n```";
        assert_eq!(subjects(&parse_items(reply)), vec!["台灯"]);
    }

    #[test]
    fn even_a_single_item_from_a_photo_needs_confirming() {
        // Unlike the text splitter, which returns Single for one item because
        // making someone approve the sentence they just typed is worse than not
        // splitting. Here the author typed nothing: the one item is the model's
        // guess about a picture, and it has to be checked like any other.
        assert!(matches!(
            parse_items(r#"{"items":[{"subject":"台灯"}]}"#),
            Decomposition::Several(_)
        ));
    }

    #[test]
    fn the_prompt_forbids_the_guesses_that_would_mislead() {
        assert!(PROMPT.contains("不要写成色"));
        assert!(PROMPT.contains("不要写价格"));
        assert!(PROMPT.contains("看不清的不要写"));
    }

    #[test]
    fn the_photo_path_is_absent_rather_than_broken_without_a_key() {
        // A button that always fails is worse than no button.
        assert!(!is_available(""));
        assert!(!is_available("   "));
        assert!(is_available("a-key"));
    }
}
