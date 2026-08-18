use rig::Embed;
use serde::{Deserialize, Serialize};

/// A document stored in the PostgreSQL vector database for semantic search.
/// Document must implement Embed so EmbeddingsBuilder can extract its content.
#[derive(Embed, Serialize, Deserialize, Clone, Debug)]
pub struct Document {
    pub id: String,
    #[embed]
    pub content: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_document_serialization() {
        let doc = Document {
            id: "doc-123".to_string(),
            content: "Test content for embedding".to_string(),
        };
        let json = serde_json::to_string(&doc).unwrap();
        assert!(json.contains("doc-123"));
        assert!(json.contains("Test content"));
    }

    #[test]
    fn test_document_deserialization() {
        let json = r#"{"id": "doc-456", "content": "Item description"}"#;
        let doc: Document = serde_json::from_str(json).unwrap();
        assert_eq!(doc.id, "doc-456");
        assert_eq!(doc.content, "Item description");
    }
}
