//! Domain service for user watchlist workflows.

use sqlx::PgPool;
use uuid::Uuid;

use crate::repositories::watchlist_repo::{
    PostgresWatchlistRepository, WatchlistListingTarget, WatchlistRow,
};

#[derive(Debug, thiserror::Error)]
pub enum WatchlistError {
    #[error("listing not found or unavailable")]
    NotFound,
    #[error("cannot add own listing to watchlist")]
    CannotWatchOwnListing,
    #[error("database error: {0}")]
    Database(#[from] sqlx::Error),
}

#[derive(Clone)]
pub struct WatchlistService {
    pool: PgPool,
    repo: PostgresWatchlistRepository,
}

impl WatchlistService {
    pub fn new(pool: PgPool) -> Self {
        let repo = PostgresWatchlistRepository::new(pool.clone());
        Self { pool, repo }
    }

    /// List active watched listings for a user with total count.
    pub async fn get_user_watchlist(
        &self,
        user_id: &str,
        limit: i64,
        offset: i64,
    ) -> Result<(Vec<WatchlistRow>, i64), WatchlistError> {
        self.repo
            .list_watchlist(user_id, limit, offset)
            .await
            .map_err(WatchlistError::Database)
    }

    /// Add an active, unrestricted listing to user's watchlist within a transaction.
    /// Rejects non-active/restricted listings and prevents users from watchlisting their own listings.
    pub async fn add_to_watchlist(
        &self,
        user_id: &str,
        listing_id: &str,
        campus_id: Uuid,
    ) -> Result<(), WatchlistError> {
        let mut tx = self.pool.begin().await?;

        let target: WatchlistListingTarget = self
            .repo
            .get_listing_for_watch(&mut tx, listing_id, campus_id)
            .await?
            .ok_or(WatchlistError::NotFound)?;

        if target.status != "active" || target.restricted {
            return Err(WatchlistError::NotFound);
        }
        if target.owner_id == user_id {
            return Err(WatchlistError::CannotWatchOwnListing);
        }

        self.repo.insert(&mut tx, user_id, listing_id).await?;
        tx.commit().await?;

        Ok(())
    }

    /// Remove a listing from user's watchlist.
    pub async fn remove_from_watchlist(
        &self,
        user_id: &str,
        listing_id: &str,
    ) -> Result<(), WatchlistError> {
        self.repo
            .delete(user_id, listing_id)
            .await
            .map_err(WatchlistError::Database)
    }

    /// Check if a listing exists in user's watchlist.
    pub async fn check_watchlist(
        &self,
        user_id: &str,
        listing_id: &str,
    ) -> Result<bool, WatchlistError> {
        self.repo
            .exists(user_id, listing_id)
            .await
            .map_err(WatchlistError::Database)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn watchlist_error_display() {
        assert_eq!(
            WatchlistError::NotFound.to_string(),
            "listing not found or unavailable"
        );
        assert_eq!(
            WatchlistError::CannotWatchOwnListing.to_string(),
            "cannot add own listing to watchlist"
        );
    }
}
