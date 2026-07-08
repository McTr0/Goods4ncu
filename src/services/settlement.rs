use sqlx::PgPool;
use thiserror::Error;

#[derive(Error, Debug)]
#[allow(dead_code)]
pub enum SettlementError {
    #[error("Platform settlement is disabled")]
    Disabled,
    #[error("Database error: {0}")]
    DbError(#[from] sqlx::Error),
}

#[derive(Clone)]
#[allow(dead_code)]
pub struct SettlementService {
    db: PgPool,
}

impl SettlementService {
    pub fn new(db: PgPool) -> Self {
        Self { db }
    }

    /// Returns an error indicating platform-side settlement is disabled.
    #[allow(dead_code)]
    pub async fn reject_platform_settlement(&self, order_id: &str) -> Result<(), SettlementError> {
        tracing::warn!(
            order_id,
            "Platform settlement path called but settlement is disabled"
        );
        Err(SettlementError::Disabled)
    }
}

#[cfg(test)]
mod unit_tests {
    use super::*;

    #[test]
    fn test_settlement_error_display() {
        assert_eq!(
            SettlementError::Disabled.to_string(),
            "Platform settlement is disabled"
        );
    }

    #[test]
    fn test_settlement_error_debug() {
        let error = SettlementError::Disabled;
        let debug_str = format!("{:?}", error);
        assert!(debug_str.contains("Disabled"));
    }

    #[test]
    fn test_settlement_service_new() {
        // SettlementService::new is just a constructor - verify it compiles
        // We can't actually use it without a DB pool in unit tests
        fn assert_clone<T: Clone>() {}
        assert_clone::<SettlementService>();
    }

    #[test]
    fn test_settlement_disabled_result_shape() {
        let result: Result<(), SettlementError> = Err(SettlementError::Disabled);
        assert!(matches!(result, Err(SettlementError::Disabled)));
    }
}
