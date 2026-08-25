//! Canonical marketplace category keys and legacy alias normalization.

pub const MARKETPLACE_CATEGORIES: &[&str] = &[
    "electronics",
    "books",
    "digitalAccessories",
    "dailyGoods",
    "clothingShoes",
    "other",
];

pub fn normalize_category(input: &str) -> Option<&'static str> {
    let trimmed = input.trim();
    match trimmed {
        "electronics" | "电子产品" | "电子" | "数码产品" => Some("electronics"),
        "books" | "书籍" | "图书" | "教材" => Some("books"),
        "digitalAccessories" | "digital_accessories" | "数码配件" | "配件" => {
            Some("digitalAccessories")
        }
        "dailyGoods" | "daily_goods" | "生活用品" | "日用品" | "宿舍用品" => {
            Some("dailyGoods")
        }
        "clothingShoes" | "clothing_shoes" | "服装" | "服饰" | "服饰鞋包" | "鞋包" => {
            Some("clothingShoes")
        }
        "other" | "其他" | "其它" | "misc" => Some("other"),
        _ => None,
    }
}

pub fn normalize_category_or_other(input: &str) -> &'static str {
    normalize_category(input).unwrap_or("other")
}

pub fn normalize_category_list(input: &str) -> Vec<&'static str> {
    let mut normalized = Vec::new();
    for part in input.split(',') {
        if let Some(category) = normalize_category(part) {
            if !normalized.contains(&category) {
                normalized.push(category);
            }
        }
    }
    normalized
}

pub fn valid_category_message() -> String {
    format!(
        "category must be one of: {}",
        MARKETPLACE_CATEGORIES.join(", ")
    )
}

/// Unified post categories. This IS the post kind. Bootstrap fallback only —
/// the authoritative set lives in post_categories (migrations 0101/0103) and
/// is cached from the DB at runtime (see services::post::allowed_categories).
pub const POST_CATEGORIES: &[&str] = &[
    "offer", "wanted", "discussion", "event", "announcement",
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_legacy_chinese_categories() {
        assert_eq!(normalize_category("电子产品"), Some("electronics"));
        assert_eq!(normalize_category("书籍"), Some("books"));
        assert_eq!(normalize_category("数码配件"), Some("digitalAccessories"));
        assert_eq!(normalize_category("生活用品"), Some("dailyGoods"));
        assert_eq!(normalize_category("服装"), Some("clothingShoes"));
        assert_eq!(normalize_category("其他"), Some("other"));
    }

    #[test]
    fn normalizes_category_lists_and_deduplicates() {
        assert_eq!(
            normalize_category_list("电子产品,electronics,书籍"),
            vec!["electronics", "books"]
        );
    }
}
