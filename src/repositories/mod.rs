//! Repository layer — data access abstracted behind traits.
//!
//! This module provides dependency inversion: API handlers depend on traits,
//! not on concrete implementations. This enables unit testing and
//! future flexibility to swap storage backends.

mod auth_repo;
mod listing_repo;
mod order_repo;
mod post_repo;
pub mod traits;
mod user_repo;
mod watchlist_repo;

pub use auth_repo::PostgresAuthRepository;
#[allow(unused_imports)]
pub use listing_repo::{
    ActiveRestrictionView, DeleteOwnedResult, ListingOrderTarget, ListingRestrictionDetails,
    MarketplaceStatsData, PostgresListingRepository, UpdateOwnedResult,
};
pub use order_repo::PostgresOrderRepository;
pub use post_repo::*;
pub use traits::*;
pub use user_repo::PostgresUserRepository;
pub use watchlist_repo::*;
