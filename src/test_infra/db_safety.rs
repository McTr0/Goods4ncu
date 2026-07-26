pub fn extract_db_name(database_url: &str) -> Option<String> {
    let without_query = database_url.split('?').next().unwrap_or(database_url);
    without_query.rsplit('/').next().map(|s| s.to_string())
}

pub fn with_database_name(database_url: &str, db_name: &str) -> Option<String> {
    let (base, query) = match database_url.split_once('?') {
        Some((b, q)) => (b, Some(q)),
        None => (database_url, None),
    };

    let slash_pos = base.rfind('/')?;
    let mut rebuilt = String::with_capacity(database_url.len() + db_name.len());
    rebuilt.push_str(&base[..slash_pos + 1]);
    rebuilt.push_str(db_name);
    if let Some(q) = query {
        rebuilt.push('?');
        rebuilt.push_str(q);
    }
    Some(rebuilt)
}

pub fn is_safe_db_identifier(db_name: &str) -> bool {
    !db_name.is_empty()
        && db_name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_')
}

pub fn validate_test_database_url(database_url: &str) -> Result<(), String> {
    let db_name = extract_db_name(database_url).unwrap_or_default();
    let allow_non_test_wipe = std::env::var("ALLOW_NON_TEST_DB_WIPE")
        .map(|v| v == "1")
        .unwrap_or(false);

    if db_name.to_lowercase().contains("test") || allow_non_test_wipe {
        return Ok(());
    }

    Err(format!(
        "Refusing to clean non-test database '{}'. Set TEST_DATABASE_URL to a *_test DB, or explicitly set ALLOW_NON_TEST_DB_WIPE=1 to override.",
        db_name
    ))
}

pub fn resolve_test_database_url() -> String {
    let database_url = std::env::var("TEST_DATABASE_URL")
        .or_else(|_| std::env::var("DATABASE_URL"))
        .unwrap_or_else(|_| "postgres://mctr0@localhost/goods4ncu_test".to_string());

    validate_test_database_url(&database_url)
        .expect("Unsafe test database URL; refusing to run destructive cleanup");

    database_url
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extract_db_name() {
        assert_eq!(
            extract_db_name("postgres://user:pass@localhost:5432/goods4ncu_test"),
            Some("goods4ncu_test".to_string())
        );
        assert_eq!(
            extract_db_name("postgres://localhost/goods4ncu?sslmode=disable"),
            Some("goods4ncu".to_string())
        );
    }

    #[test]
    fn test_with_database_name_preserves_query() {
        assert_eq!(
            with_database_name(
                "postgres://user:pass@localhost:5432/goods4ncu_test?sslmode=disable",
                "postgres"
            ),
            Some("postgres://user:pass@localhost:5432/postgres?sslmode=disable".to_string())
        );
    }

    #[test]
    fn test_safe_db_identifier() {
        assert!(is_safe_db_identifier("goods4ncu_test"));
        assert!(!is_safe_db_identifier(""));
        assert!(!is_safe_db_identifier("goods4ncu-test"));
        assert!(!is_safe_db_identifier("goods4ncu test"));
    }

    #[test]
    fn test_validate_test_database_url_enforces_test_db_name() {
        let ok = validate_test_database_url("postgres://localhost/goods4ncu_test");
        assert!(ok.is_ok());

        let bad = validate_test_database_url("postgres://localhost/goods4ncu");
        assert!(bad.is_err());
    }
}
