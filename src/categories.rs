//! Canonical marketplace category keys and legacy alias normalization.

use serde::{Deserialize, Serialize};

pub const MARKETPLACE_CATEGORIES: &[&str] = &[
    "electronics",
    "books",
    "digitalAccessories",
    "dailyGoods",
    "clothingShoes",
    "other",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum MarketplaceCategory {
    Electronics,
    Books,
    DigitalAccessories,
    DailyGoods,
    ClothingShoes,
    Other,
}

impl MarketplaceCategory {
    #[allow(dead_code)]
    pub const ALL: [MarketplaceCategory; 6] = [
        Self::Electronics,
        Self::Books,
        Self::DigitalAccessories,
        Self::DailyGoods,
        Self::ClothingShoes,
        Self::Other,
    ];

    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Electronics => "electronics",
            Self::Books => "books",
            Self::DigitalAccessories => "digitalAccessories",
            Self::DailyGoods => "dailyGoods",
            Self::ClothingShoes => "clothingShoes",
            Self::Other => "other",
        }
    }

    pub fn parse(input: &str) -> Option<Self> {
        match normalize_category(input) {
            Some("electronics") => Some(Self::Electronics),
            Some("books") => Some(Self::Books),
            Some("digitalAccessories") => Some(Self::DigitalAccessories),
            Some("dailyGoods") => Some(Self::DailyGoods),
            Some("clothingShoes") => Some(Self::ClothingShoes),
            Some("other") => Some(Self::Other),
            _ => None,
        }
    }
}

impl std::fmt::Display for MarketplaceCategory {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.as_str())
    }
}

impl std::str::FromStr for MarketplaceCategory {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Self::parse(s).ok_or_else(valid_category_message)
    }
}

impl<'de> Deserialize<'de> for MarketplaceCategory {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let s = String::deserialize(deserializer)?;
        MarketplaceCategory::parse(&s).ok_or_else(|| {
            serde::de::Error::custom(format!(
                "invalid marketplace category '{}', expected one of: {}",
                s,
                MARKETPLACE_CATEGORIES.join(", ")
            ))
        })
    }
}

impl Serialize for MarketplaceCategory {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        serializer.serialize_str(self.as_str())
    }
}

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
