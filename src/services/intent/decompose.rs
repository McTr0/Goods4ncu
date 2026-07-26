//! Reading several intents out of one sentence.
//!
//! The graduation-season case: "毕业了，宿舍里有台灯、小冰箱、两把椅子、一个书架，
//! 都便宜出" is five things to sell, said once. A listing form asks for that
//! five times, and gets it zero times — which is most of why the supply on a
//! campus never reaches the system at all.
//!
//! Two rules shape this module:
//!
//! * **Everything it produces is a draft.** Splitting a sentence is guesswork,
//!   and guessing wrong should cost the author one dismissal, not put five
//!   half-understood things in front of the campus. `create_draft_batch` is the
//!   only way out of here.
//! * **It works without the model.** Deciding what someone owns is not a place
//!   to hard-depend on an LLM being reachable, so the deterministic splitter is
//!   a real path rather than an error branch — and it is tried *first* on input
//!   that plainly enumerates, because a list separated by 、is not an inference
//!   problem.

use crate::services::intent::slots::{PriceSlot, Slots};

/// Below this many characters an input is one thing, not a list.
const MIN_LENGTH_TO_SPLIT: usize = 6;
/// A sentence yielding more than this is far more likely a parsing accident than
/// a dorm room. Runaway decomposition is worse than none: nobody confirms
/// thirty cards.
const MAX_ITEMS: usize = 20;
/// Confidence attached to a deterministic split — high, because a list the
/// author punctuated themselves is not a guess.
const SPLIT_CONFIDENCE: f32 = 0.8;
/// Confidence for a model reading.
const MODEL_CONFIDENCE: f32 = 0.6;

/// Characters people actually use to enumerate in Chinese and English.
const SEPARATORS: &[char] = &['、', '，', ',', '；', ';', '\n', '/'];

/// Words that mean "and the price is whatever" rather than naming an item.
///
/// Kept short on purpose. Over-matching here would silently drop something
/// someone owns, which is worse than leaving a clause they can delete.
const PRICE_PHRASES: &[&str] = &[
    "都便宜出",
    "便宜出",
    "能卖多少卖多少",
    "能卖就行",
    "随便给",
    "都可以谈",
    "价格可谈",
    "都出",
];

/// Clauses that set the scene rather than name a thing.
const PREAMBLE_PHRASES: &[&str] = &[
    "毕业了",
    "毕业",
    "宿舍要清空了",
    "宿舍里有",
    "宿舍有",
    "要搬走了",
    "搬宿舍",
    "清一下",
    "出一批",
];

/// Currency markers people write next to a number.
const CURRENCY_MARKERS: &[&str] = &["块", "元", "¥", "钱", "rmb", "RMB"];

/// Whether a fragment is a price rather than a thing, and what it says.
///
/// This matters more than it looks. "一台九成新的宿舍小台灯，30 块" is one item
/// with a price; splitting on the comma without this check produced two cards,
/// the second of them called "30 块". A decomposition that invents an item out
/// of the price is worse than no decomposition, because the author has to
/// notice and delete it every single time.
fn price_fragment_cents(fragment: &str) -> Option<i64> {
    let has_marker = CURRENCY_MARKERS
        .iter()
        .any(|marker| fragment.contains(marker));
    if !has_marker {
        return None;
    }
    let digits: String = fragment.chars().filter(char::is_ascii_digit).collect();
    if digits.is_empty() {
        return None;
    }
    // A fragment that is mostly a number and a unit is a price. One that also
    // carries a noun ("小台灯 30 块") is an item that happens to state its price,
    // and must not be discarded.
    let meaningful: usize = fragment
        .chars()
        .filter(|c| !c.is_whitespace() && !c.is_ascii_digit() && !c.is_ascii_punctuation())
        .count();
    let marker_len: usize = CURRENCY_MARKERS
        .iter()
        .filter(|m| fragment.contains(*m))
        .map(|m| m.chars().count())
        .max()
        .unwrap_or(0);
    if meaningful > marker_len {
        return None;
    }
    digits.parse::<i64>().ok().map(|yuan| yuan * 100)
}

/// One item read out of the input.
#[derive(Debug, Clone, PartialEq)]
pub struct DecomposedItem {
    pub slots: Slots,
    pub confidence: f32,
}

/// What the input turned out to be.
#[derive(Debug, Clone, PartialEq)]
pub enum Decomposition {
    /// One thing. The caller should record it directly rather than making the
    /// author confirm a single card they just typed.
    Single,
    /// Several things, all of which need confirming.
    Several(Vec<DecomposedItem>),
}

/// Split an input without asking a model.
///
/// Tried before the model, and not as a fallback: when someone writes a list
/// with 、between the items, the enumeration is *stated*, and asking an LLM to
/// re-derive it adds latency, cost and the chance of a worse answer.
///
/// Returns [`Decomposition::Single`] when it cannot see a list, which is the
/// honest answer far more often than not.
pub fn split_deterministically(raw_input: &str) -> Decomposition {
    let trimmed = raw_input.trim();
    if trimmed.chars().count() < MIN_LENGTH_TO_SPLIT {
        return Decomposition::Single;
    }

    // A shared price phrase applies to every item: "台灯、小冰箱，都便宜出" prices
    // both, not just the last one.
    let shared_price = PRICE_PHRASES
        .iter()
        .find(|phrase| trimmed.contains(*phrase))
        .map(|phrase| PriceSlot::Whatever {
            hint: Some((*phrase).to_string()),
        });

    let mut items: Vec<DecomposedItem> = Vec::new();
    // A bare price anywhere in the list prices the whole list, the same way a
    // phrase like "都便宜出" does.
    let stated_price = trimmed
        .split(SEPARATORS)
        .filter_map(|fragment| price_fragment_cents(fragment.trim()))
        .next()
        .map(|cents| PriceSlot::Exact { cents });
    let shared_price = shared_price.or(stated_price);

    for fragment in trimmed.split(SEPARATORS) {
        let mut piece = fragment.trim().to_string();
        if piece.is_empty() {
            continue;
        }
        // A price is not a thing someone owns.
        if price_fragment_cents(&piece).is_some() {
            continue;
        }
        // Strip the scene-setting and the price clause, leaving the thing.
        for phrase in PREAMBLE_PHRASES.iter().chain(PRICE_PHRASES.iter()) {
            piece = piece.replace(phrase, "");
        }
        let subject = piece
            .trim()
            .trim_matches(['。', '.', '!', '！', '~'])
            .trim();
        if subject.chars().count() < 2 {
            continue;
        }
        items.push(DecomposedItem {
            slots: Slots {
                subject: Some(subject.to_string()),
                price: shared_price.clone(),
                ..Default::default()
            },
            confidence: SPLIT_CONFIDENCE,
        });
        if items.len() >= MAX_ITEMS {
            break;
        }
    }

    if items.len() < 2 {
        Decomposition::Single
    } else {
        Decomposition::Several(items)
    }
}

/// Prompt for the model path, used only when the deterministic split found
/// nothing — i.e. the author wrote prose rather than a list.
pub fn model_prompt(raw_input: &str) -> String {
    format!(
        "把下面这句话里提到的**每一件要出的东西**拆成一条一条。\n\
         只输出 JSON，格式：{{\"items\":[{{\"subject\":\"台灯\"}},{{\"subject\":\"小冰箱\"}}]}}\n\
         规则：\n\
         - subject 只写物品名，不要写价格、不要写「毕业了」这类背景\n\
         - 如果只提到一件东西，就只输出一条\n\
         - 最多 {MAX_ITEMS} 条\n\
         - 不确定的东西也列出来，作者会自己删\n\n\
         句子：{raw_input}"
    )
}

#[derive(serde::Deserialize)]
struct ModelItems {
    items: Vec<ModelItem>,
}

#[derive(serde::Deserialize)]
struct ModelItem {
    subject: String,
}

/// Parse a model reply into items.
///
/// Anything unparseable is [`Decomposition::Single`] rather than an error: a
/// bad model reply should degrade to "one thing, as typed", never to a failed
/// post. The author's sentence is not worth losing to a JSON slip.
pub fn parse_model_reply(reply: &str, raw_input: &str) -> Decomposition {
    let shared_price = PRICE_PHRASES
        .iter()
        .find(|phrase| raw_input.contains(*phrase))
        .map(|phrase| PriceSlot::Whatever {
            hint: Some((*phrase).to_string()),
        });

    // Models like to wrap JSON in prose or fences; take the outermost object.
    let json = match (reply.find('{'), reply.rfind('}')) {
        (Some(start), Some(end)) if end > start => &reply[start..=end],
        _ => return Decomposition::Single,
    };
    let Ok(parsed) = serde_json::from_str::<ModelItems>(json) else {
        return Decomposition::Single;
    };

    let items: Vec<DecomposedItem> = parsed
        .items
        .into_iter()
        .filter_map(|item| {
            let subject = item.subject.trim();
            (subject.chars().count() >= 2).then(|| DecomposedItem {
                slots: Slots {
                    subject: Some(subject.to_string()),
                    price: shared_price.clone(),
                    ..Default::default()
                },
                confidence: MODEL_CONFIDENCE,
            })
        })
        .take(MAX_ITEMS)
        .collect();

    if items.len() < 2 {
        Decomposition::Single
    } else {
        Decomposition::Several(items)
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
    fn a_graduation_sentence_becomes_one_item_per_thing() {
        // The case this module exists for. Five things, said once, and a form
        // would have asked five times.
        let result =
            split_deterministically("毕业了，宿舍里有台灯、小冰箱、两把椅子、一个书架，都便宜出");
        assert_eq!(
            subjects(&result),
            vec!["台灯", "小冰箱", "两把椅子", "一个书架"],
            "the scene-setting and the price clause are not things",
        );
    }

    #[test]
    fn a_price_clause_applies_to_everything_in_the_list() {
        // "都便宜出" prices the whole list, not just the fragment it sits in.
        let Decomposition::Several(items) = split_deterministically("台灯、小冰箱、书架，都便宜出")
        else {
            panic!("expected several");
        };
        assert_eq!(items.len(), 3);
        for item in &items {
            assert_eq!(
                item.slots.price,
                Some(PriceSlot::Whatever {
                    hint: Some("都便宜出".to_string())
                }),
                "every item carries the price the author stated once",
            );
        }
    }

    #[test]
    fn one_thing_stays_one_thing() {
        // Splitting a single item into a confirmation card is worse than not
        // splitting: the author typed one thing and would be asked to approve
        // their own sentence.
        for input in ["一台九成新的宿舍小台灯，30 块", "想收个二手显示器", "台灯"]
        {
            assert_eq!(
                split_deterministically(input),
                Decomposition::Single,
                "input: {input}",
            );
        }
    }

    #[test]
    fn a_price_is_not_an_item() {
        // Found by the single-item test: splitting on 、 turned "…台灯，30 块"
        // into two cards, the second called "30 块". Inventing an item out of
        // the price is worse than not splitting, because the author has to
        // notice and delete it every time.
        assert_eq!(
            split_deterministically("一台九成新的宿舍小台灯，30 块"),
            Decomposition::Single,
        );

        // And in a real list, the price attaches to the items instead of
        // becoming one.
        let Decomposition::Several(items) = split_deterministically("台灯、小冰箱、书架，30 块")
        else {
            panic!("expected several");
        };
        assert_eq!(
            subjects(&Decomposition::Several(items.clone())),
            vec!["台灯", "小冰箱", "书架"]
        );
        assert!(items
            .iter()
            .all(|i| i.slots.price == Some(PriceSlot::Exact { cents: 3_000 })));
    }

    #[test]
    fn an_item_that_states_its_own_price_is_still_an_item() {
        // The distinction the guard has to get right: "30 块" is a price,
        // "小台灯 30 块" is a thing.
        assert!(price_fragment_cents("30 块").is_some());
        assert!(
            price_fragment_cents("￥50").is_none(),
            "no digits parsed from a bare symbol is fine"
        );
        assert!(price_fragment_cents("小台灯 30 块").is_none());
        assert!(price_fragment_cents("台灯").is_none());
        assert!(price_fragment_cents("50 元").is_some());
    }

    #[test]
    fn a_runaway_split_is_capped() {
        // Thirty cards to confirm is worse than a form. Better to hand back
        // twenty and let the author post the rest.
        let long = (0..40)
            .map(|i| format!("物品{i}"))
            .collect::<Vec<_>>()
            .join("、");
        let Decomposition::Several(items) = split_deterministically(&long) else {
            panic!("expected several");
        };
        assert_eq!(items.len(), MAX_ITEMS);
    }

    #[test]
    fn separators_people_actually_use_all_work() {
        for input in [
            "台灯、小冰箱、书架",
            "台灯，小冰箱，书架",
            "台灯; 小冰箱; 书架",
            "台灯 / 小冰箱 / 书架",
            "台灯\n小冰箱\n书架",
        ] {
            assert_eq!(
                subjects(&split_deterministically(input)).len(),
                3,
                "{input}"
            );
        }
    }

    #[test]
    fn a_stated_list_never_reaches_the_model() {
        // The deterministic path runs first on purpose. When someone punctuated
        // the list themselves the enumeration is stated, not inferred, and
        // asking a model to re-derive it costs latency and risks a worse answer.
        assert!(matches!(
            split_deterministically("台灯、小冰箱、书架"),
            Decomposition::Several(_)
        ));
    }

    #[test]
    fn a_model_reply_is_read_even_when_wrapped_in_prose() {
        let reply = "好的，我拆好了：\n```json\n{\"items\":[{\"subject\":\"台灯\"},\
                     {\"subject\":\"小冰箱\"}]}\n```\n还需要什么吗？";
        assert_eq!(
            subjects(&parse_model_reply(reply, "")),
            vec!["台灯", "小冰箱"]
        );
    }

    #[test]
    fn a_broken_model_reply_degrades_to_one_thing_not_to_an_error() {
        // The author's sentence must not be lost to a JSON slip.
        for reply in ["", "不好意思我不明白", "{\"items\": broken", "{}"] {
            assert_eq!(
                parse_model_reply(reply, "毕业了东西都出"),
                Decomposition::Single,
                "reply: {reply}",
            );
        }
    }

    #[test]
    fn the_model_path_also_spreads_a_stated_price() {
        let reply = r#"{"items":[{"subject":"台灯"},{"subject":"小冰箱"}]}"#;
        let Decomposition::Several(items) =
            parse_model_reply(reply, "毕业了，台灯和小冰箱能卖多少卖多少")
        else {
            panic!("expected several");
        };
        assert!(items
            .iter()
            .all(|i| matches!(i.slots.price, Some(PriceSlot::Whatever { .. }))));
    }

    #[test]
    fn the_prompt_tells_the_model_what_not_to_include() {
        // A prompt that omits this gets back "毕业了" and "都便宜出" as items.
        let prompt = model_prompt("毕业了，台灯、小冰箱");
        assert!(prompt.contains("不要写价格"));
        assert!(prompt.contains("毕业了"));
        assert!(prompt.contains("最多 20 条"));
    }
}
