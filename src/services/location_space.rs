use std::collections::HashMap;

use chrono::{DateTime, Utc};
use serde::Serialize;
use sqlx::{PgPool, Row};
use uuid::Uuid;

use crate::api::error::ApiError;

const MAX_CHILDREN_PER_MEMBER_AND_LOCATION: i64 = 5;
const MAX_ACTIVE_CHILDREN_PER_LOCATION: i64 = 100;
const LOCATION_PRESENCE_TTL_SECONDS: i64 = 90;

#[derive(Debug, Clone, Serialize)]
pub struct LocationSpaceNode {
    pub id: Uuid,
    pub name: String,
    pub description: Option<String>,
    pub parent_space_id: Option<Uuid>,
    pub location_slug: Option<String>,
    pub location_kind: String,
    pub is_official: bool,
    pub is_member: bool,
    pub my_role: Option<String>,
    pub member_count: i64,
    pub online_count: i64,
    pub can_create_children: bool,
    /// Curated directory places without a verified geofence remain manually
    /// enterable but are excluded from automatic location matching.
    pub location_matchable: bool,
    pub children: Vec<LocationSpaceNode>,
}

#[derive(Debug, Clone, Serialize)]
pub struct LocationSpaceTree {
    pub items: Vec<LocationSpaceNode>,
}

#[derive(Debug, Clone, Serialize)]
pub struct LocationRecommendation {
    pub matched: bool,
    pub space: Option<LocationSpaceNode>,
}

#[derive(Debug, Clone, Serialize)]
pub struct LocationPresenceView {
    pub space_id: Uuid,
    pub active: bool,
    pub online_count: i64,
    pub expires_at: Option<String>,
    pub ttl_seconds: i64,
}

#[derive(Debug)]
struct FlatLocationSpace {
    node: LocationSpaceNode,
    sort_order: i16,
}

#[derive(Clone)]
pub struct LocationSpaceService {
    db: PgPool,
}

impl LocationSpaceService {
    pub fn new(db: PgPool) -> Self {
        Self { db }
    }

    pub async fn tree(
        &self,
        campus_id: Uuid,
        user_id: &str,
    ) -> Result<LocationSpaceTree, ApiError> {
        let rows = sqlx::query(
            "SELECT s.id, s.name, s.description, s.parent_space_id,
                    s.location_slug, s.location_kind, s.origin, s.allows_child_spaces,
                    s.location_sort_order,
                    (s.latitude IS NOT NULL AND s.longitude IS NOT NULL
                     AND s.radius_meters IS NOT NULL) AS location_matchable,
                    mine.role AS my_role,
                    (SELECT COUNT(*)::BIGINT
                       FROM chat_space_members member
                      WHERE member.space_id = s.id AND member.role <> 'banned') AS member_count,
                    (SELECT COUNT(*)::BIGINT
                        FROM chat_space_presence presence
                       WHERE presence.space_id = s.id
                         AND presence.expires_at > NOW()
                         AND NOT EXISTS (
                             SELECT 1 FROM chat_space_members banned
                              WHERE banned.space_id = presence.space_id
                                AND banned.user_id = presence.user_id
                                AND banned.role = 'banned'
                         )) AS online_count
               FROM chat_spaces s
               LEFT JOIN chat_space_members mine
                 ON mine.space_id = s.id AND mine.user_id = $2
              WHERE s.campus_id = $1
                AND s.status = 'active'
                AND s.origin IN ('campus_location', 'location_child')
              ORDER BY s.location_sort_order ASC, s.created_at ASC, s.name ASC",
        )
        .bind(campus_id)
        .bind(user_id)
        .fetch_all(&self.db)
        .await
        .map_err(db_error)?;

        let mut by_parent: HashMap<Option<Uuid>, Vec<FlatLocationSpace>> = HashMap::new();
        for row in rows {
            let my_role: Option<String> = row.try_get("my_role").ok().flatten();
            let origin: String = row.get("origin");
            let parent_space_id: Option<Uuid> = row.get("parent_space_id");
            by_parent
                .entry(parent_space_id)
                .or_default()
                .push(FlatLocationSpace {
                    node: LocationSpaceNode {
                        id: row.get("id"),
                        name: row.get("name"),
                        description: row.get("description"),
                        parent_space_id,
                        location_slug: row.get("location_slug"),
                        location_kind: row
                            .get::<Option<String>, _>("location_kind")
                            .unwrap_or_else(|| "custom".to_string()),
                        is_official: origin == "campus_location",
                        is_member: my_role.as_deref().is_some_and(|role| role != "banned"),
                        my_role,
                        member_count: row.get("member_count"),
                        online_count: row.get("online_count"),
                        can_create_children: row.get("allows_child_spaces"),
                        location_matchable: row.get("location_matchable"),
                        children: Vec::new(),
                    },
                    sort_order: row.get("location_sort_order"),
                });
        }

        Ok(LocationSpaceTree {
            items: materialize_children(None, &mut by_parent),
        })
    }

    /// Resolve a coarse, one-shot coordinate against public campus geofences.
    /// The coordinate is neither inserted nor attached to the user.
    pub async fn recommend(
        &self,
        campus_id: Uuid,
        user_id: &str,
        latitude: f64,
        longitude: f64,
    ) -> Result<LocationRecommendation, ApiError> {
        validate_coordinate(latitude, longitude)?;
        let rows = sqlx::query(
            "SELECT s.id, s.name, s.description, s.parent_space_id,
                    s.location_slug, s.location_kind, s.latitude, s.longitude, s.radius_meters,
                    s.allows_child_spaces,
                    mine.role AS my_role,
                    (SELECT COUNT(*)::BIGINT
                       FROM chat_space_members member
                      WHERE member.space_id = s.id AND member.role <> 'banned') AS member_count,
                    (SELECT COUNT(*)::BIGINT
                        FROM chat_space_presence presence
                       WHERE presence.space_id = s.id
                         AND presence.expires_at > NOW()
                         AND NOT EXISTS (
                             SELECT 1 FROM chat_space_members banned
                              WHERE banned.space_id = presence.space_id
                                AND banned.user_id = presence.user_id
                                AND banned.role = 'banned'
                         )) AS online_count
               FROM chat_spaces s
               LEFT JOIN chat_space_members mine
                 ON mine.space_id = s.id AND mine.user_id = $2
              WHERE s.campus_id = $1
                AND s.status = 'active'
                AND s.origin = 'campus_location'
                AND s.latitude IS NOT NULL
                AND s.longitude IS NOT NULL
                AND s.radius_meters IS NOT NULL",
        )
        .bind(campus_id)
        .bind(user_id)
        .fetch_all(&self.db)
        .await
        .map_err(db_error)?;

        let mut best: Option<(i32, f64, LocationSpaceNode)> = None;
        for row in rows {
            let centre_latitude: f64 = row.get("latitude");
            let centre_longitude: f64 = row.get("longitude");
            let radius_meters: i32 = row.get("radius_meters");
            let distance = haversine_meters(latitude, longitude, centre_latitude, centre_longitude);
            if distance > f64::from(radius_meters) {
                continue;
            }

            let my_role: Option<String> = row.try_get("my_role").ok().flatten();
            let candidate = LocationSpaceNode {
                id: row.get("id"),
                name: row.get("name"),
                description: row.get("description"),
                parent_space_id: row.get("parent_space_id"),
                location_slug: row.get("location_slug"),
                location_kind: row.get("location_kind"),
                is_official: true,
                is_member: my_role.as_deref().is_some_and(|role| role != "banned"),
                my_role,
                member_count: row.get("member_count"),
                online_count: row.get("online_count"),
                can_create_children: row.get("allows_child_spaces"),
                location_matchable: true,
                children: Vec::new(),
            };
            let should_replace = best.as_ref().is_none_or(|(best_radius, best_distance, _)| {
                radius_meters < *best_radius
                    || (radius_meters == *best_radius && distance < *best_distance)
            });
            if should_replace {
                best = Some((radius_meters, distance, candidate));
            }
        }

        Ok(LocationRecommendation {
            matched: best.is_some(),
            space: best.map(|(_, _, node)| node),
        })
    }

    /// Location rooms are campus commons, not durable groups. A verified
    /// campus member may read and write without joining, unless explicitly
    /// banned from that room. Non-location spaces keep their membership rules.
    pub async fn has_transient_chat_access(
        &self,
        campus_id: Uuid,
        user_id: &str,
        space_id: Uuid,
    ) -> Result<bool, ApiError> {
        let row = sqlx::query(
            "SELECT s.origin, s.status, mine.role AS my_role
               FROM chat_spaces s
               LEFT JOIN chat_space_members mine
                 ON mine.space_id = s.id AND mine.user_id = $3
              WHERE s.id = $1 AND s.campus_id = $2",
        )
        .bind(space_id)
        .bind(campus_id)
        .bind(user_id)
        .fetch_optional(&self.db)
        .await
        .map_err(db_error)?
        .ok_or(ApiError::NotFound)?;

        let origin: String = row.get("origin");
        if !matches!(origin.as_str(), "campus_location" | "location_child") {
            return Ok(false);
        }
        if row.get::<String, _>("status") != "active" {
            return Err(ApiError::NotFound);
        }
        if row
            .try_get::<Option<String>, _>("my_role")
            .ok()
            .flatten()
            .as_deref()
            == Some("banned")
        {
            return Err(ApiError::Forbidden);
        }
        Ok(true)
    }

    pub async fn presence(
        &self,
        campus_id: Uuid,
        user_id: &str,
        space_id: Uuid,
    ) -> Result<LocationPresenceView, ApiError> {
        if !self
            .has_transient_chat_access(campus_id, user_id, space_id)
            .await?
        {
            return Err(ApiError::NotFound);
        }
        self.load_presence(campus_id, user_id, space_id).await
    }

    pub async fn heartbeat_presence(
        &self,
        campus_id: Uuid,
        user_id: &str,
        space_id: Uuid,
        active: bool,
    ) -> Result<LocationPresenceView, ApiError> {
        if !self
            .has_transient_chat_access(campus_id, user_id, space_id)
            .await?
        {
            return Err(ApiError::NotFound);
        }

        if active {
            sqlx::query(
                "INSERT INTO chat_space_presence (
                     space_id, campus_id, user_id, expires_at, updated_at
                 ) VALUES (
                     $1, $2, $3, NOW() + make_interval(secs => $4::double precision), NOW()
                 )
                 ON CONFLICT (space_id, user_id)
                 DO UPDATE SET campus_id = EXCLUDED.campus_id,
                               expires_at = EXCLUDED.expires_at,
                               updated_at = NOW()",
            )
            .bind(space_id)
            .bind(campus_id)
            .bind(user_id)
            .bind(LOCATION_PRESENCE_TTL_SECONDS as f64)
            .execute(&self.db)
            .await
            .map_err(db_error)?;
        } else {
            sqlx::query(
                "DELETE FROM chat_space_presence
                  WHERE space_id = $1 AND campus_id = $2 AND user_id = $3",
            )
            .bind(space_id)
            .bind(campus_id)
            .bind(user_id)
            .execute(&self.db)
            .await
            .map_err(db_error)?;
        }

        // Expired leases do not affect counts even if this opportunistic cleanup
        // loses a race with another heartbeat.
        sqlx::query(
            "DELETE FROM chat_space_presence
              WHERE space_id = $1 AND campus_id = $2 AND expires_at <= NOW()",
        )
        .bind(space_id)
        .bind(campus_id)
        .execute(&self.db)
        .await
        .map_err(db_error)?;

        self.load_presence(campus_id, user_id, space_id).await
    }

    async fn load_presence(
        &self,
        campus_id: Uuid,
        user_id: &str,
        space_id: Uuid,
    ) -> Result<LocationPresenceView, ApiError> {
        let row = sqlx::query(
            "SELECT
                 (SELECT COUNT(*)::BIGINT
                    FROM chat_space_presence active
                   WHERE active.space_id = $1
                     AND active.campus_id = $2
                     AND active.expires_at > NOW()
                     AND NOT EXISTS (
                         SELECT 1 FROM chat_space_members banned
                          WHERE banned.space_id = active.space_id
                            AND banned.user_id = active.user_id
                            AND banned.role = 'banned'
                     )) AS online_count,
                 (SELECT mine.expires_at
                    FROM chat_space_presence mine
                   WHERE mine.space_id = $1
                     AND mine.campus_id = $2
                     AND mine.user_id = $3
                     AND mine.expires_at > NOW()) AS expires_at",
        )
        .bind(space_id)
        .bind(campus_id)
        .bind(user_id)
        .fetch_one(&self.db)
        .await
        .map_err(db_error)?;
        let expires_at: Option<DateTime<Utc>> = row.try_get("expires_at").ok().flatten();
        Ok(LocationPresenceView {
            space_id,
            active: expires_at.is_some(),
            online_count: row.get("online_count"),
            expires_at: expires_at.map(|value| value.to_rfc3339()),
            ttl_seconds: LOCATION_PRESENCE_TTL_SECONDS,
        })
    }

    pub async fn join(
        &self,
        campus_id: Uuid,
        user_id: &str,
        space_id: Uuid,
    ) -> Result<(), ApiError> {
        let exists: bool = sqlx::query_scalar(
            "SELECT EXISTS(
                SELECT 1 FROM chat_spaces
                 WHERE id = $1 AND campus_id = $2 AND status = 'active'
                   AND origin IN ('campus_location', 'location_child')
             )",
        )
        .bind(space_id)
        .bind(campus_id)
        .fetch_one(&self.db)
        .await
        .map_err(db_error)?;
        if !exists {
            return Err(ApiError::NotFound);
        }

        let current_role = sqlx::query_scalar::<_, String>(
            "SELECT role FROM chat_space_members WHERE space_id = $1 AND user_id = $2",
        )
        .bind(space_id)
        .bind(user_id)
        .fetch_optional(&self.db)
        .await
        .map_err(db_error)?;
        if current_role.as_deref() == Some("banned") {
            return Err(ApiError::Forbidden);
        }
        if current_role.is_none() {
            sqlx::query(
                "INSERT INTO chat_space_members (space_id, user_id, role)
                 VALUES ($1, $2, 'member')",
            )
            .bind(space_id)
            .bind(user_id)
            .execute(&self.db)
            .await
            .map_err(db_error)?;
        }
        Ok(())
    }

    pub async fn create_child(
        &self,
        campus_id: Uuid,
        user_id: &str,
        parent_space_id: Uuid,
        name: &str,
        description: Option<&str>,
    ) -> Result<Uuid, ApiError> {
        let name = name.trim();
        if name.is_empty() || name.chars().count() > 80 {
            return Err(ApiError::BadRequest(
                "小聊天室名称必须为 1 到 80 字".to_string(),
            ));
        }
        let description = description.map(str::trim).filter(|value| !value.is_empty());
        if description.is_some_and(|value| value.chars().count() > 400) {
            return Err(ApiError::BadRequest(
                "小聊天室简介不能超过 400 字".to_string(),
            ));
        }

        let mut tx = self.db.begin().await.map_err(db_error)?;
        let parent = sqlx::query(
            "SELECT origin, allows_child_spaces
               FROM chat_spaces
              WHERE id = $1 AND campus_id = $2 AND status = 'active'
              FOR UPDATE",
        )
        .bind(parent_space_id)
        .bind(campus_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(db_error)?
        .ok_or(ApiError::NotFound)?;
        if parent.get::<String, _>("origin") != "campus_location"
            || !parent.get::<bool, _>("allows_child_spaces")
        {
            return Err(ApiError::CodedConflict {
                code: "location_parent_not_leaf",
                message: "只能在地点叶节点下创建小聊天室".to_string(),
            });
        }

        let role = sqlx::query_scalar::<_, String>(
            "SELECT role FROM chat_space_members
              WHERE space_id = $1 AND user_id = $2",
        )
        .bind(parent_space_id)
        .bind(user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(db_error)?;
        if role.as_deref().is_none_or(|role| role == "banned") {
            return Err(ApiError::Forbidden);
        }

        let member_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM chat_spaces
              WHERE parent_space_id = $1 AND owner_id = $2
                AND origin = 'location_child' AND status = 'active'",
        )
        .bind(parent_space_id)
        .bind(user_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(db_error)?;
        if member_count >= MAX_CHILDREN_PER_MEMBER_AND_LOCATION {
            return Err(ApiError::CodedConflict {
                code: "location_child_member_limit",
                message: "你在这个地点创建的小聊天室已达到上限".to_string(),
            });
        }
        let total_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM chat_spaces
              WHERE parent_space_id = $1
                AND origin = 'location_child' AND status = 'active'",
        )
        .bind(parent_space_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(db_error)?;
        if total_count >= MAX_ACTIVE_CHILDREN_PER_LOCATION {
            return Err(ApiError::CodedConflict {
                code: "location_child_capacity_reached",
                message: "这个地点的小聊天室数量已达到上限".to_string(),
            });
        }

        let space_id = Uuid::new_v4();
        let inserted = sqlx::query(
            "INSERT INTO chat_spaces (
                 id, campus_id, kind, name, description, owner_id, status,
                 origin, purpose, parent_space_id, location_kind,
                 allows_child_spaces, location_sort_order
             ) VALUES (
                 $1, $2, 'group', $3, $4, $5, 'active',
                 'location_child', $4, $6, 'custom', FALSE, 1000
             )",
        )
        .bind(space_id)
        .bind(campus_id)
        .bind(name)
        .bind(description)
        .bind(user_id)
        .bind(parent_space_id)
        .execute(&mut *tx)
        .await;
        if let Err(error) = inserted {
            if error
                .as_database_error()
                .and_then(|error| error.code())
                .as_deref()
                == Some("23505")
            {
                return Err(ApiError::CodedConflict {
                    code: "location_child_name_taken",
                    message: "这个地点已有同名小聊天室".to_string(),
                });
            }
            return Err(db_error(error));
        }
        sqlx::query(
            "INSERT INTO chat_space_members (space_id, user_id, role)
             VALUES ($1, $2, 'owner')",
        )
        .bind(space_id)
        .bind(user_id)
        .execute(&mut *tx)
        .await
        .map_err(db_error)?;
        tx.commit().await.map_err(db_error)?;
        Ok(space_id)
    }
}

fn materialize_children(
    parent_id: Option<Uuid>,
    by_parent: &mut HashMap<Option<Uuid>, Vec<FlatLocationSpace>>,
) -> Vec<LocationSpaceNode> {
    let mut flats = by_parent.remove(&parent_id).unwrap_or_default();
    flats.sort_by(|left, right| {
        left.sort_order
            .cmp(&right.sort_order)
            .then_with(|| left.node.name.cmp(&right.node.name))
    });
    flats
        .into_iter()
        .map(|flat| {
            let mut node = flat.node;
            node.children = materialize_children(Some(node.id), by_parent);
            node
        })
        .collect()
}

fn validate_coordinate(latitude: f64, longitude: f64) -> Result<(), ApiError> {
    if !latitude.is_finite()
        || !longitude.is_finite()
        || !(-90.0..=90.0).contains(&latitude)
        || !(-180.0..=180.0).contains(&longitude)
    {
        return Err(ApiError::BadRequest("定位坐标无效".to_string()));
    }
    Ok(())
}

fn haversine_meters(latitude: f64, longitude: f64, other_lat: f64, other_lon: f64) -> f64 {
    const EARTH_RADIUS_METERS: f64 = 6_371_000.0;
    let lat1 = latitude.to_radians();
    let lat2 = other_lat.to_radians();
    let delta_lat = (other_lat - latitude).to_radians();
    let delta_lon = (other_lon - longitude).to_radians();
    let a =
        (delta_lat / 2.0).sin().powi(2) + lat1.cos() * lat2.cos() * (delta_lon / 2.0).sin().powi(2);
    2.0 * EARTH_RADIUS_METERS * a.sqrt().atan2((1.0 - a).sqrt())
}

fn db_error(error: sqlx::Error) -> ApiError {
    ApiError::Internal(anyhow::anyhow!(error))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn coordinate_validation_rejects_non_finite_and_out_of_range_values() {
        assert!(validate_coordinate(28.66, 115.8).is_ok());
        assert!(validate_coordinate(f64::NAN, 115.8).is_err());
        assert!(validate_coordinate(91.0, 115.8).is_err());
        assert!(validate_coordinate(28.66, 181.0).is_err());
    }

    #[test]
    fn haversine_distance_is_zero_at_the_same_point() {
        assert!(haversine_meters(28.663, 115.8, 28.663, 115.8) < 0.01);
    }
}
