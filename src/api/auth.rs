use argon2::{
    password_hash::{rand_core::OsRng, PasswordHash, PasswordHasher, PasswordVerifier, SaltString},
    Argon2,
};
use axum::http::HeaderMap;
use axum::{extract::State, Json};
use jsonwebtoken::{decode, encode, DecodingKey, EncodingKey, Header, Validation};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::api::error::ApiError;
use crate::api::AppState;
use crate::repositories::traits::{AuthRepository, UserRepository};
use crate::repositories::{PostgresAuthRepository, PostgresUserRepository};
use crate::services::campus::CampusService;

#[derive(Deserialize)]
pub struct AuthRequest {
    pub username: String,
    pub email: Option<String>,
    pub password: String,
}

#[derive(Serialize)]
pub struct AuthResponse {
    pub token: String,
    pub refresh_token: String,
    pub user_id: String,
    pub username: String,
    pub active_campus_id: Option<Uuid>,
    pub message: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub(crate) struct Claims {
    sub: String,             // subject (user_id)
    role: String,            // user role: "user" or "admin"
    exp: usize,              // expiration time
    jti: String,             // JWT ID for denylist revocation
    campus_id: Option<Uuid>, // active tenant
    #[serde(default, skip_serializing_if = "Option::is_none")]
    auth_time: Option<i64>, // last password authentication time
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuthSessionContext {
    pub user_id: String,
    pub role: String,
    pub campus_id: Option<Uuid>,
    pub auth_time: Option<i64>,
}

impl AuthSessionContext {
    pub fn recent_auth_expires_at(&self) -> Option<chrono::DateTime<chrono::Utc>> {
        let auth_time = self.auth_time?;
        let now = chrono::Utc::now().timestamp();
        if auth_time > now + 60 {
            return None;
        }
        chrono::DateTime::<chrono::Utc>::from_timestamp(auth_time + RECENT_AUTH_TTL_SECS, 0)
    }

    pub fn has_recent_authentication(&self) -> bool {
        self.recent_auth_expires_at()
            .is_some_and(|expires_at| expires_at > chrono::Utc::now())
    }
}

/// Refresh token: 7 days validity
const REFRESH_TOKEN_TTL_SECS: u64 = 7 * 24 * 3600;
/// Access token: 24 hours validity (long enough for persistent WS connections)
pub const ACCESS_TOKEN_TTL_SECS: u64 = 24 * 3600;
/// Password step-up remains valid for sensitive operations for 10 minutes.
pub const RECENT_AUTH_TTL_SECS: i64 = 10 * 60;

/// Generate a secure random refresh token (UUID v4)
fn generate_refresh_token() -> String {
    Uuid::new_v4().to_string()
}

/// Hash a refresh token with SHA-256 for storage (hex-encoded)
fn hash_token(token: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(token.as_bytes());
    let result = hasher.finalize();
    hex::encode(result)
}

/// Generate an access token (JWT) with configurable expiry.
/// Returns `(token_string, jti, expiration_timestamp)`.
#[allow(dead_code)]
pub fn generate_access_token(
    user_id: &str,
    role: &str,
    jwt_secret: &str,
    ttl_secs: u64,
) -> Result<(String, String, usize), jsonwebtoken::errors::Error> {
    generate_access_token_for_campus(user_id, role, None, jwt_secret, ttl_secs)
}

pub fn generate_access_token_for_campus(
    user_id: &str,
    role: &str,
    campus_id: Option<Uuid>,
    jwt_secret: &str,
    ttl_secs: u64,
) -> Result<(String, String, usize), jsonwebtoken::errors::Error> {
    generate_access_token_for_campus_with_auth_time(
        user_id,
        role,
        campus_id,
        Some(chrono::Utc::now().timestamp()),
        jwt_secret,
        ttl_secs,
    )
}

pub fn generate_access_token_for_campus_with_auth_time(
    user_id: &str,
    role: &str,
    campus_id: Option<Uuid>,
    auth_time: Option<i64>,
    jwt_secret: &str,
    ttl_secs: u64,
) -> Result<(String, String, usize), jsonwebtoken::errors::Error> {
    let now = chrono::Utc::now().timestamp();
    let now = if now >= 0 { now as usize } else { 0usize };
    let expiration = now + ttl_secs as usize;

    let jti = Uuid::new_v4().to_string();

    let claims = Claims {
        sub: user_id.to_string(),
        role: role.to_string(),
        exp: expiration,
        jti: jti.clone(),
        campus_id,
        auth_time,
    };

    let token = encode(
        &Header::default(),
        &claims,
        &EncodingKey::from_secret(jwt_secret.as_bytes()),
    )?;

    Ok((token, jti, expiration))
}

/// Store a refresh token using the auth repository.
async fn store_refresh_token(
    auth_repo: &PostgresAuthRepository,
    user_id: &str,
    token: &str,
    ttl_secs: u64,
    campus_id: Option<Uuid>,
) -> anyhow::Result<()> {
    let token_hash = hash_token(token);
    let expires_at = chrono::Utc::now() + chrono::Duration::seconds(ttl_secs as i64);

    auth_repo
        .store_refresh_token(user_id, &token_hash, expires_at, campus_id)
        .await
        .map_err(|e| anyhow::anyhow!("Failed to store refresh token: {}", e))?;
    Ok(())
}

/// Validate a refresh token: returns user_id if valid, None if invalid/revoked/expired
/// On success, atomically revokes the presented token and issues a new one.
async fn rotate_refresh_token(
    auth_repo: &PostgresAuthRepository,
    user_repo: &PostgresUserRepository,
    token: &str,
    jwt_secret: &str,
    campus_service: &CampusService,
    campus_override: Option<Uuid>,
    expected_user_id: Option<&str>,
) -> anyhow::Result<(String, String, Uuid)> {
    let token_hash = hash_token(token);

    // Find the token
    let token_data = auth_repo
        .find_refresh_token(&token_hash)
        .await
        .map_err(|e| anyhow::anyhow!("DB error: {}", e))?;

    let token_record = match token_data {
        Some(data) => data,
        None => return Err(anyhow::anyhow!("Invalid refresh token")),
    };
    let user_id = token_record.user_id;

    if expected_user_id.is_some_and(|expected| expected != user_id) {
        return Err(anyhow::anyhow!("Refresh token belongs to another user"));
    }

    // Check revoked
    if token_record.revoked_at.is_some() {
        auth_repo
            .revoke_all_user_tokens(&user_id)
            .await
            .map_err(|e| anyhow::anyhow!("DB error: {}", e))?;
        return Err(anyhow::anyhow!("Refresh token has been revoked"));
    }

    // Check expiry
    if token_record.expires_at < chrono::Utc::now() {
        return Err(anyhow::anyhow!("Refresh token has expired"));
    }

    // Revoke old token
    match auth_repo.revoke_refresh_token(&token_hash).await {
        Ok(()) => {}
        Err(ApiError::Unauthorized) => {
            auth_repo
                .revoke_all_user_tokens(&user_id)
                .await
                .map_err(|e| anyhow::anyhow!("DB error: {}", e))?;
            return Err(anyhow::anyhow!("Refresh token replay detected"));
        }
        Err(e) => return Err(anyhow::anyhow!("DB error: {}", e)),
    }

    // Fetch user role
    let user = user_repo
        .find_by_id(&user_id)
        .await
        .map_err(|e| anyhow::anyhow!("DB error: {}", e))?
        .ok_or_else(|| anyhow::anyhow!("User not found"))?;
    if user.status.eq_ignore_ascii_case("banned") {
        auth_repo
            .revoke_all_user_tokens(&user_id)
            .await
            .map_err(|e| anyhow::anyhow!("DB error: {}", e))?;
        return Err(anyhow::anyhow!("User is banned"));
    }
    let role = user.role;
    let campus_id = match campus_override.or(token_record.campus_id) {
        Some(campus_id) => campus_service
            .resolve_session_campus(&user_id, Some(campus_id))
            .await
            .map_err(|error| anyhow::anyhow!(error.to_string()))?,
        None => campus_service
            .resolve_user_campus(&user_id)
            .await
            .map_err(|error| anyhow::anyhow!(error.to_string()))?,
    };

    // Issue new tokens
    let new_refresh = generate_refresh_token();
    store_refresh_token(
        auth_repo,
        &user_id,
        &new_refresh,
        REFRESH_TOKEN_TTL_SECS,
        Some(campus_id),
    )
    .await?;
    let (new_access, _jti, _exp) = generate_access_token_for_campus_with_auth_time(
        &user_id,
        &role,
        Some(campus_id),
        None,
        jwt_secret,
        ACCESS_TOKEN_TTL_SECS,
    )?;

    Ok((new_access, new_refresh, campus_id))
}

/// Revoke all refresh tokens for a user
async fn revoke_all_refresh_tokens(
    auth_repo: &PostgresAuthRepository,
    user_id: &str,
) -> anyhow::Result<()> {
    auth_repo
        .revoke_all_user_tokens(user_id)
        .await
        .map_err(|e| anyhow::anyhow!("DB error: {}", e))?;
    Ok(())
}

/// Revoke a specific refresh token
async fn revoke_refresh_token(
    auth_repo: &PostgresAuthRepository,
    token: &str,
) -> anyhow::Result<()> {
    let token_hash = hash_token(token);
    match auth_repo.revoke_refresh_token(&token_hash).await {
        Ok(()) | Err(ApiError::Unauthorized) => Ok(()),
        Err(e) => Err(anyhow::anyhow!("DB error: {}", e)),
    }?;
    Ok(())
}

/// Format-validate a registration email and return its domain part. Campus
/// eligibility (does an active campus own this domain?) is checked against
/// the database by the caller — hardcoding one campus's domain here is what
/// made second-campus onboarding impossible.
fn validate_registration_email(email: &str) -> Result<&str, ApiError> {
    if email.is_empty() {
        return Err(ApiError::BadRequest("邮箱不能为空".to_string()));
    }
    if email.len() > 100 {
        return Err(ApiError::BadRequest("邮箱不能超过100个字符".to_string()));
    }

    let Some((local, domain)) = email.split_once('@') else {
        return Err(ApiError::BadRequest("邮箱格式无效".to_string()));
    };
    if domain.contains('@') || domain.is_empty() {
        return Err(ApiError::BadRequest("邮箱格式无效".to_string()));
    }
    if local.is_empty() || local.len() > 64 {
        return Err(ApiError::BadRequest("邮箱格式无效".to_string()));
    }
    if local.starts_with('.') || local.ends_with('.') || local.contains("..") {
        return Err(ApiError::BadRequest("邮箱格式无效".to_string()));
    }
    if !local
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'%' | b'+' | b'-'))
    {
        return Err(ApiError::BadRequest("邮箱格式无效".to_string()));
    }

    Ok(domain)
}

/// The domain must belong to an active campus; the resulting membership is
/// routed to that campus at creation time.
async fn ensure_campus_email_domain(db: &sqlx::PgPool, domain: &str) -> Result<(), ApiError> {
    let allowed: bool = sqlx::query_scalar(
        "SELECT EXISTS (
            SELECT 1 FROM campuses c
            WHERE c.status = 'active'
              AND EXISTS (
                  SELECT 1 FROM unnest(c.email_domains) AS d
                  WHERE lower(d) = lower($1)
              )
         )",
    )
    .bind(domain)
    .fetch_one(db)
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
    if !allowed {
        // Say which domain, not just that this one is wrong. This is the first
        // wall a real student hits, and "use a school email" without naming it
        // asks them to guess.
        let domains: Vec<String> = sqlx::query_scalar(
            // The primary campus only, and the LIMIT has to sit inside the
            // subquery: `unnest` expands after the outer limit, so limiting the
            // rows out here still listed every campus. Enumerating which
            // schools are onboard to anyone who mistypes an address is a leak,
            // and telling an NCU student about someone else's domain is noise.
            "SELECT unnest(email_domains) FROM (
                 SELECT email_domains FROM campuses
                 WHERE status = 'active'
                 ORDER BY (slug = 'ncu') DESC, created_at ASC
                 LIMIT 1
             ) primary_campus",
        )
        .fetch_all(db)
        .await
        .unwrap_or_default();
        return Err(ApiError::BadRequest(if domains.is_empty() {
            "请使用学校邮箱注册".to_string()
        } else {
            format!(
                "请使用学校邮箱注册（{}）",
                domains
                    .iter()
                    .map(|domain| format!("@{domain}"))
                    .collect::<Vec<_>>()
                    .join(" 或 ")
            )
        }));
    }
    Ok(())
}

#[derive(Deserialize)]
pub struct RefreshTokenRequest {
    pub refresh_token: String,
}

#[derive(Serialize)]
pub struct RefreshResponse {
    pub token: String,
    pub refresh_token: String,
    pub active_campus_id: Uuid,
}

#[derive(Deserialize)]
pub struct SwitchCampusRequest {
    pub campus_id: Uuid,
    pub refresh_token: String,
}

#[derive(Deserialize)]
pub struct LogoutRequest {
    pub refresh_token: Option<String>,
}

#[derive(Deserialize)]
pub struct ReauthenticateRequest {
    pub password: String,
    /// Required when the account has a confirmed TOTP factor. Absent for
    /// ordinary users and admins who have not yet enrolled.
    #[serde(default)]
    pub totp_code: Option<String>,
}

#[derive(Serialize)]
pub struct ReauthenticateResponse {
    pub token: String,
    pub recent_auth_expires_at: chrono::DateTime<chrono::Utc>,
}

/// Hash a password using Argon2id with a cryptographically secure random salt in a blocking task.
pub async fn hash_password(password: String) -> Result<String, ApiError> {
    let hash_result = tokio::task::spawn_blocking(move || {
        let salt = SaltString::generate(&mut OsRng);
        Argon2::default()
            .hash_password(password.as_bytes(), &salt)
            .map(|h| h.to_string())
    })
    .await;

    match hash_result {
        Ok(Ok(hash)) => Ok(hash),
        Ok(Err(e)) => {
            tracing::error!(err = %e, "Password hashing failed");
            Err(ApiError::Internal(anyhow::anyhow!(
                "Password hashing failed: {}",
                e
            )))
        }
        Err(e) => {
            tracing::error!(err = %e, "Spawning hashing task failed");
            Err(ApiError::Internal(anyhow::anyhow!("Internal error: {}", e)))
        }
    }
}

/// Verify a password against an Argon2 password hash in a blocking task.
/// Returns `Ok(true)` if valid, `Ok(false)` if invalid or unparseable, or `Err(ApiError)` on runtime failure.
pub async fn verify_password(password: String, password_hash: String) -> Result<bool, ApiError> {
    tokio::task::spawn_blocking(move || {
        let Ok(parsed_hash) = PasswordHash::new(&password_hash) else {
            return false;
        };
        Argon2::default()
            .verify_password(password.as_bytes(), &parsed_hash)
            .is_ok()
    })
    .await
    .map_err(|e| {
        tracing::error!(err = %e, "Password verification task failed");
        ApiError::Internal(anyhow::anyhow!("Password verification task failed: {}", e))
    })
}

/// POST /api/auth/register — returns 201 Created on success, 409 Conflict on duplicate.
pub async fn register(
    State(state): State<AppState>,
    Json(payload): Json<AuthRequest>,
) -> Result<Json<AuthResponse>, ApiError> {
    // Reject oversized inputs before they can trigger CPU-intensive hashing or bloat storage.
    if payload.username.is_empty() {
        return Err(ApiError::BadRequest("用户名不能为空".to_string()));
    }
    if payload.username.len() > 50 {
        return Err(ApiError::BadRequest("用户名不能超过50个字符".to_string()));
    }
    if payload.password.is_empty() {
        return Err(ApiError::BadRequest("密码不能为空".to_string()));
    }
    if payload.password.len() > 128 {
        return Err(ApiError::BadRequest("密码不能超过128个字符".to_string()));
    }
    if payload.password.len() < 8 {
        return Err(ApiError::BadRequest("密码至少需要8个字符".to_string()));
    }

    // Validate email format and campus eligibility (optional but validated if
    // provided): the domain must belong to an active campus, and the initial
    // pending membership routes to that campus.
    if let Some(ref email) = payload.email {
        let domain = validate_registration_email(email)?;
        ensure_campus_email_domain(&state.infra.db, domain).await?;
    }

    let password_hash = hash_password(payload.password.clone()).await?;

    // Create user via repository
    let user_id = state
        .auth_repo
        .create_user(&payload.username, payload.email.as_deref(), &password_hash)
        .await;

    match user_id {
        Ok(user_id) => {
            let campus_id = CampusService::new(state.infra.db.clone())
                .resolve_user_campus(&user_id)
                .await?;
            let (token, _jti, _exp) = generate_access_token_for_campus(
                &user_id,
                "user",
                Some(campus_id),
                &state.secrets.jwt_secret,
                ACCESS_TOKEN_TTL_SECS,
            )?;
            let refresh = generate_refresh_token();
            store_refresh_token(
                &state.auth_repo,
                &user_id,
                &refresh,
                REFRESH_TOKEN_TTL_SECS,
                Some(campus_id),
            )
            .await
            .map_err(|e| {
                ApiError::Internal(anyhow::anyhow!("Failed to store refresh token: {}", e))
            })?;
            Ok(Json(AuthResponse {
                token,
                refresh_token: refresh,
                user_id,
                username: payload.username.clone(),
                active_campus_id: Some(campus_id),
                message: "注册成功".to_string(),
            }))
        }
        Err(e) => {
            tracing::warn!(err = %e, username = %payload.username, "Registration failed");
            // AuthRepository::create_user returns ApiError::Conflict for duplicate username
            Err(e)
        }
    }
}

/// POST /api/auth/login — returns 200 OK with token on success, 401 Unauthorized on bad credentials.
pub async fn login(
    State(state): State<AppState>,
    Json(payload): Json<AuthRequest>,
) -> Result<Json<AuthResponse>, ApiError> {
    tracing::info!(username = %payload.username, "LOGIN ATTEMPT");
    // Sanity check before hitting the database — prevents wasteful full-table scans.
    if payload.username.is_empty() || payload.password.is_empty() {
        return Err(ApiError::AuthFailed("用户名或密码错误".to_string()));
    }
    if payload.username.len() > 50 || payload.password.len() > 128 {
        return Err(ApiError::AuthFailed("用户名或密码错误".to_string()));
    }

    // Fetch user from database using repository
    let user = match state
        .auth_repo
        .find_user_by_username(&payload.username)
        .await
    {
        Ok(Some(user)) => user,
        Ok(None) => {
            // Return 401 to prevent username enumeration
            tracing::warn!(username = %payload.username, "Login failed — user not found");
            return Err(ApiError::AuthFailed("用户名或密码错误".to_string()));
        }
        Err(e) => {
            tracing::error!(err = %e, "Database error during login");
            return Err(ApiError::Internal(anyhow::anyhow!("Database error: {}", e)));
        }
    };

    if user.status.eq_ignore_ascii_case("banned") {
        tracing::warn!(
            username = %payload.username,
            user_id = %user.id,
            "Login failed — banned user"
        );
        return Err(ApiError::AuthFailed("账号已被封禁".to_string()));
    }

    if !verify_password(payload.password, user.password_hash).await? {
        // Return 401 for wrong password — do NOT distinguish from wrong username
        tracing::warn!(username = %payload.username, "Login failed — wrong password");
        return Err(ApiError::AuthFailed("用户名或密码错误".to_string()));
    }

    let campus_id = CampusService::new(state.infra.db.clone())
        .resolve_user_campus(&user.id)
        .await?;
    let (token, _jti, _exp) = generate_access_token_for_campus(
        &user.id,
        &user.role,
        Some(campus_id),
        &state.secrets.jwt_secret,
        ACCESS_TOKEN_TTL_SECS,
    )?;
    let refresh = generate_refresh_token();
    store_refresh_token(
        &state.auth_repo,
        &user.id,
        &refresh,
        REFRESH_TOKEN_TTL_SECS,
        Some(campus_id),
    )
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("Failed to store refresh token: {}", e)))?;
    Ok(Json(AuthResponse {
        token,
        refresh_token: refresh,
        user_id: user.id,
        username: user.username,
        active_campus_id: Some(campus_id),
        message: "登录成功".to_string(),
    }))
}

/// POST /api/auth/reauth — verify the current password and issue a recently-authenticated access token.
pub async fn reauthenticate(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(payload): Json<ReauthenticateRequest>,
) -> Result<Json<ReauthenticateResponse>, ApiError> {
    let session = extract_auth_session_from_token(&headers, &state.secrets.jwt_secret)
        .map_err(|_| ApiError::Unauthorized)?;
    if payload.password.is_empty() || payload.password.len() > 128 {
        return Err(ApiError::RecentAuthenticationFailed);
    }

    let user = state
        .user_repo
        .find_by_id(&session.user_id)
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?
        .ok_or(ApiError::Unauthorized)?;
    if user.status != "active" {
        return Err(ApiError::Forbidden);
    }

    if !verify_password(payload.password, user.password_hash).await? {
        tracing::warn!(user_id = %session.user_id, "Recent authentication failed");
        return Err(ApiError::RecentAuthenticationFailed);
    }

    // Second factor: once an admin has confirmed a TOTP enrollment, password
    // alone must never open the sensitive-write window again. The check runs
    // only after the password has been verified so a stolen token cannot use
    // this endpoint as a TOTP-validity oracle.
    if user.role == "admin" {
        let mfa = crate::services::admin_mfa::AdminMfaService::new(state.infra.db.clone());
        if mfa
            .is_enforced(&session.user_id)
            .await
            .map_err(ApiError::Internal)?
        {
            let code = payload
                .totp_code
                .as_deref()
                .filter(|code| !code.is_empty())
                .ok_or(ApiError::MfaRequired)?;
            let now = chrono::Utc::now().timestamp();
            match mfa
                .verify_and_consume(&session.user_id, code, now)
                .await
                .map_err(ApiError::Internal)?
            {
                Ok(()) => {}
                Err(_) => {
                    tracing::warn!(user_id = %session.user_id, "Admin TOTP verification failed");
                    return Err(ApiError::RecentAuthenticationFailed);
                }
            }
        }
    }

    let auth_time = chrono::Utc::now().timestamp();
    let (token, _, _) = generate_access_token_for_campus_with_auth_time(
        &session.user_id,
        &user.role,
        session.campus_id,
        Some(auth_time),
        &state.secrets.jwt_secret,
        ACCESS_TOKEN_TTL_SECS,
    )?;
    let recent_auth_expires_at =
        chrono::DateTime::<chrono::Utc>::from_timestamp(auth_time + RECENT_AUTH_TTL_SECS, 0)
            .ok_or_else(|| {
                ApiError::Internal(anyhow::anyhow!("Invalid authentication timestamp"))
            })?;

    tracing::info!(user_id = %session.user_id, "Recent authentication completed");
    Ok(Json(ReauthenticateResponse {
        token,
        recent_auth_expires_at,
    }))
}

/// POST /api/auth/refresh — rotate a refresh token, returns new access + refresh token pair
pub async fn refresh_token(
    State(state): State<AppState>,
    Json(payload): Json<RefreshTokenRequest>,
) -> Result<Json<RefreshResponse>, ApiError> {
    let campus_service = CampusService::new(state.infra.db.clone());
    let (new_access, new_refresh, active_campus_id) = rotate_refresh_token(
        &state.auth_repo,
        &state.user_repo,
        &payload.refresh_token,
        &state.secrets.jwt_secret,
        &campus_service,
        None,
        None,
    )
    .await
    .map_err(|e| {
        tracing::warn!(err = %e, "Refresh token rotation failed");
        ApiError::Unauthorized
    })?;

    Ok(Json(RefreshResponse {
        token: new_access,
        refresh_token: new_refresh,
        active_campus_id,
    }))
}

/// POST /api/user/active-campus — rotate this device session into another verified campus.
pub async fn switch_active_campus(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(payload): Json<SwitchCampusRequest>,
) -> Result<Json<RefreshResponse>, ApiError> {
    let claims = extract_claims_from_token(&headers, &state.secrets.jwt_secret)?;
    let campus_service = CampusService::new(state.infra.db.clone());
    campus_service
        .require_verified_in_campus(&claims.sub, payload.campus_id)
        .await?;

    let (new_access, new_refresh, active_campus_id) = rotate_refresh_token(
        &state.auth_repo,
        &state.user_repo,
        &payload.refresh_token,
        &state.secrets.jwt_secret,
        &campus_service,
        Some(payload.campus_id),
        Some(&claims.sub),
    )
    .await
    .map_err(|error| {
        tracing::warn!(err = %error, user_id = %claims.sub, "Campus switch failed");
        ApiError::Unauthorized
    })?;

    let expires_at = chrono::DateTime::<chrono::Utc>::from_timestamp(claims.exp as i64, 0)
        .unwrap_or_else(chrono::Utc::now);
    revoke_access_token_jti(&state, &claims.jti, expires_at).await?;

    Ok(Json(RefreshResponse {
        token: new_access,
        refresh_token: new_refresh,
        active_campus_id,
    }))
}

/// POST /api/auth/logout — revoke refresh token(s) to invalidate the session
pub async fn logout(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(payload): Json<LogoutRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let claims = extract_claims_from_token(&headers, &state.secrets.jwt_secret)?;

    let expires_at = chrono::DateTime::<chrono::Utc>::from_timestamp(claims.exp as i64, 0)
        .unwrap_or_else(chrono::Utc::now);
    revoke_access_token_jti(&state, &claims.jti, expires_at).await?;

    if let Some(ref token) = payload.refresh_token {
        revoke_refresh_token(&state.auth_repo, token).await?;
    }
    revoke_all_refresh_tokens(&state.auth_repo, &claims.sub).await?;

    tracing::info!(user_id = %claims.sub, "User logged out, all sessions revoked");

    Ok(Json(serde_json::json!({
        "message": "已退出登录"
    })))
}

#[derive(Deserialize)]
pub struct ChangePasswordRequest {
    pub current_password: String,
    pub new_password: String,
}

/// POST /api/auth/change-password — change password (requires auth)
pub async fn change_password(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(payload): Json<ChangePasswordRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let user_id = extract_user_id_from_token(&headers, &state.secrets.jwt_secret)
        .map_err(|_| ApiError::Unauthorized)?;

    if payload.current_password.is_empty() {
        return Err(ApiError::BadRequest("当前密码不能为空".to_string()));
    }
    if payload.new_password.is_empty() {
        return Err(ApiError::BadRequest("新密码不能为空".to_string()));
    }
    if payload.new_password.len() < 8 {
        return Err(ApiError::BadRequest("新密码至少需要8个字符".to_string()));
    }
    if payload.new_password.len() > 128 {
        return Err(ApiError::BadRequest("新密码不能超过128个字符".to_string()));
    }

    // Fetch user via repository
    let user = state
        .user_repo
        .find_by_id(&user_id)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
        .ok_or(ApiError::Unauthorized)?;

    if !verify_password(payload.current_password, user.password_hash).await? {
        tracing::warn!(user_id = %user_id, "Password change failed — wrong current password");
        return Err(ApiError::AuthFailed("当前密码错误".to_string()));
    }

    let new_hash = hash_password(payload.new_password).await?;

    state
        .user_repo
        .update_password_hash(&user_id, &new_hash)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    tracing::info!(user_id = %user_id, "Password changed successfully");

    Ok(Json(serde_json::json!({
        "message": "密码修改成功"
    })))
}

/// Extract and validate the user_id from a raw JWT token string.
/// Returns `Ok(user_id)` if the token is valid, or `Err(message)` if invalid.
pub fn extract_user_id_from_token_str(token: &str, jwt_secret: &str) -> Result<String, String> {
    let claims = decode_claims_from_token_str(token, jwt_secret)?;

    Ok(claims.sub)
}

pub fn extract_auth_session_from_token_str(
    token: &str,
    jwt_secret: &str,
) -> Result<AuthSessionContext, String> {
    let claims = decode_claims_from_token_str(token, jwt_secret)?;
    Ok(AuthSessionContext {
        user_id: claims.sub,
        role: claims.role,
        campus_id: claims.campus_id,
        auth_time: claims.auth_time,
    })
}

fn decode_claims_from_token_str(token: &str, jwt_secret: &str) -> Result<Claims, String> {
    let token_data = decode::<Claims>(
        token,
        &DecodingKey::from_secret(jwt_secret.as_bytes()),
        &Validation::default(),
    )
    .map_err(|e| format!("Invalid token: {}", e))?;

    Ok(token_data.claims)
}

pub fn extract_jti_from_token_str(token: &str, jwt_secret: &str) -> Result<String, String> {
    let claims = decode_claims_from_token_str(token, jwt_secret)?;
    Ok(claims.jti)
}

pub(crate) async fn revoke_access_token_jti(
    state: &AppState,
    jti: &str,
    expires_at: chrono::DateTime<chrono::Utc>,
) -> Result<(), ApiError> {
    sqlx::query(
        r#"INSERT INTO revoked_access_tokens (jti, expires_at)
           VALUES ($1, $2)
           ON CONFLICT (jti)
           DO UPDATE SET expires_at = GREATEST(revoked_access_tokens.expires_at, EXCLUDED.expires_at)"#,
    )
    .bind(jti)
    .bind(expires_at)
    .execute(&state.infra.db)
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    state
        .infra
        .token_denylist
        .deny(jti, expires_at.timestamp().max(0) as u64);

    Ok(())
}

/// Check whether a token is revoked via in-memory and persisted denylist.
pub async fn ensure_token_not_revoked(state: &AppState, token: &str) -> Result<(), String> {
    let jti = extract_jti_from_token_str(token, &state.secrets.jwt_secret)?;

    state.infra.token_denylist.cleanup_expired();
    if state.infra.token_denylist.is_denied(&jti) {
        return Err("Token revoked".to_string());
    }

    if state.infra.token_denylist.is_verified(&jti) {
        return Ok(());
    }

    let persisted_exp = sqlx::query_scalar::<_, i64>(
        "SELECT EXTRACT(EPOCH FROM expires_at)::bigint
         FROM revoked_access_tokens
         WHERE jti = $1 AND expires_at > NOW()",
    )
    .bind(&jti)
    .fetch_optional(&state.infra.db)
    .await;

    match persisted_exp {
        Ok(Some(exp)) if exp > 0 => {
            state.infra.token_denylist.deny(&jti, exp as u64);
            Err("Token revoked".to_string())
        }
        Ok(_) => {
            state.infra.token_denylist.mark_verified(&jti);
            Ok(())
        }
        Err(e) => Err(format!("Denylist query failed: {}", e)),
    }
}

pub async fn ensure_user_not_banned(state: &AppState, user_id: &str) -> Result<(), ApiError> {
    if let Some(cached_status) = state.infra.token_denylist.get_user_status(user_id) {
        if cached_status.eq_ignore_ascii_case("banned") {
            return Err(ApiError::AuthFailed("账号已被封禁".to_string()));
        }
        return Ok(());
    }

    let status = sqlx::query_scalar::<_, String>("SELECT status FROM users WHERE id = $1")
        .bind(user_id)
        .fetch_optional(&state.infra.db)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
        .ok_or(ApiError::Unauthorized)?;

    state.infra.token_denylist.set_user_status(user_id, &status);

    if status.eq_ignore_ascii_case("banned") {
        return Err(ApiError::AuthFailed("账号已被封禁".to_string()));
    }

    Ok(())
}

/// Extract and validate the user_id and role from a raw JWT token string.
/// Returns `Ok((user_id, role))` if the token is valid, or `Err(message)` if invalid.
pub fn extract_user_id_and_role_from_token_str(
    token: &str,
    jwt_secret: &str,
) -> Result<(String, String), String> {
    let claims = decode_claims_from_token_str(token, jwt_secret)?;

    Ok((claims.sub, claims.role))
}

/// Extract and validate the user_id from the Authorization header using the provided secret.
/// Returns `Ok(user_id)` if the token is valid, or `Err(message)` if invalid/missing.
#[allow(dead_code)]
pub fn extract_user_id_from_token(headers: &HeaderMap, jwt_secret: &str) -> Result<String, String> {
    let auth_header = headers
        .get("Authorization")
        .and_then(|v| v.to_str().ok())
        .ok_or_else(|| "Missing Authorization header".to_string())?;

    let token = auth_header
        .strip_prefix("Bearer ")
        .ok_or_else(|| "Invalid Authorization format".to_string())?;

    extract_user_id_from_token_str(token, jwt_secret)
}

pub fn extract_auth_session_from_token(
    headers: &HeaderMap,
    jwt_secret: &str,
) -> Result<AuthSessionContext, String> {
    let auth_header = headers
        .get("Authorization")
        .and_then(|value| value.to_str().ok())
        .ok_or_else(|| "Missing Authorization header".to_string())?;
    let token = auth_header
        .strip_prefix("Bearer ")
        .ok_or_else(|| "Invalid Authorization format".to_string())?;
    extract_auth_session_from_token_str(token, jwt_secret)
}

fn bearer_token(headers: &HeaderMap) -> Result<&str, ApiError> {
    headers
        .get("Authorization")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .ok_or(ApiError::Unauthorized)
}

pub(crate) fn extract_claims_from_token(
    headers: &HeaderMap,
    jwt_secret: &str,
) -> Result<Claims, ApiError> {
    let token = bearer_token(headers)?;
    decode_claims_from_token_str(token, jwt_secret).map_err(|_| ApiError::Unauthorized)
}

/// Extract and validate the user_id and role from the Authorization header using the provided secret.
/// Returns `Ok((user_id, role))` if the token is valid, or `Err(message)` if invalid/missing.
#[allow(dead_code)]
pub fn extract_user_id_and_role_from_token(
    headers: &HeaderMap,
    jwt_secret: &str,
) -> Result<(String, String), String> {
    let auth_header = headers
        .get("Authorization")
        .and_then(|v| v.to_str().ok())
        .ok_or_else(|| "Missing Authorization header".to_string())?;

    let token = auth_header
        .strip_prefix("Bearer ")
        .ok_or_else(|| "Invalid Authorization format".to_string())?;

    extract_user_id_and_role_from_token_str(token, jwt_secret)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::agents::router::IntentRouter;
    use crate::api::{ApiAgents, ApiInfrastructure, ApiSecrets, AppState};
    use crate::repositories::{AuthRepository, PostgresAuthRepository, PostgresUserRepository};
    use crate::services::{self, notification::NotificationService};
    use crate::test_infra::with_test_pool;
    use axum::{extract::State, Json};
    use sqlx::Row;
    use std::sync::Arc;

    pub(crate) fn build_test_state(pool: sqlx::PgPool) -> AppState {
        let admin_service = services::admin::AdminService::new(pool.clone());

        AppState {
            secrets: ApiSecrets {
                jwt_secret: "test_jwt_secret_at_least_32_characters_long".to_string(),
                gemini_api_key: "test-gemini-key".to_string(),
                oss_endpoint: "https://oss-cn-beijing.aliyuncs.com".to_string(),
                oss_bucket: "test-bucket".to_string(),
                oss_role_arn: None,
                oss_access_key_id: None,
                oss_access_key_secret: None,
            },
            infra: {
                let ws_hub = Arc::new(crate::api::ws::WsHub::new());
                ApiInfrastructure {
                    db: pool.clone(),
                    rate_limit: {
                        let factory =
                            crate::middleware::rate_limit::RateLimiterFactory::new(100, 60);
                        crate::middleware::rate_limit::RateLimitStateHandle::new(
                            factory.build_local(),
                        )
                    },
                    notification: NotificationService::new(pool.clone()),
                    ws_hub,
                    metrics: Arc::new(crate::api::metrics::MetricsService::new()),
                    order_service: services::order::OrderService::new(pool.clone()),
                    admin_service,
                    moderation: services::moderation::ModerationService::new(
                        &crate::config::AppConfig::test_defaults(),
                    ),
                    token_denylist: services::token_denylist::TokenDenylist::new(),
                    media_signer: None,
                    shutdown: crate::lifecycle::ShutdownSignal::never(),
                    deployment_profile: crate::config::DeploymentProfile::Local,
                    #[cfg(feature = "redis")]
                    replicated_runtime: None,
                }
            },

            agents: ApiAgents {
                llm_provider: Arc::new(
                    crate::llm::gemini::GeminiProvider::new("test-key", 768)
                        .expect("gemini provider init"),
                ),
                tri_tier_router: crate::agents::router::TriTierIntentRouter::new(
                    IntentRouter::new(vec![]),
                    None,
                    None,
                ),
                agent_enabled: true,
            },
            listing_repo: crate::repositories::PostgresListingRepository::new(pool.clone()),
            user_repo: PostgresUserRepository::new(pool.clone()),
            auth_repo: PostgresAuthRepository::new(pool.clone()),
            order_repo: crate::repositories::PostgresOrderRepository::new(pool),
        }
    }

    #[test]
    fn test_extract_user_id_from_token_missing_header() {
        let headers = HeaderMap::new();
        let result = extract_user_id_from_token(&headers, "secret123456789012345678901234567890");
        assert!(result.is_err());
        assert_eq!(result.unwrap_err(), "Missing Authorization header");
    }

    #[test]
    fn test_extract_user_id_from_token_invalid_format() {
        let mut headers = HeaderMap::new();
        headers.insert("Authorization", "Basic dXNlcjpwYXNz".parse().unwrap());
        let result = extract_user_id_from_token(&headers, "secret123456789012345678901234567890");
        assert!(result.is_err());
        assert_eq!(result.unwrap_err(), "Invalid Authorization format");
    }

    #[test]
    fn test_generate_token_produces_valid_jwt() {
        let (token, jti, exp) = generate_access_token(
            "user-123",
            "user",
            "secret123456789012345678901234567890",
            3600,
        )
        .unwrap();
        // A valid JWT has three parts separated by dots
        let parts: Vec<&str> = token.split('.').collect();
        assert_eq!(parts.len(), 3);
        assert!(!jti.is_empty());
        assert!(exp > 0);
    }

    #[test]
    fn test_campus_claim_round_trips_and_legacy_token_stays_compatible() {
        let secret = "test_jwt_secret_at_least_32_characters_long";
        let campus_id = Uuid::new_v4();
        let (token, _, _) =
            generate_access_token_for_campus("campus-user", "user", Some(campus_id), secret, 3600)
                .expect("campus token");
        let context =
            extract_auth_session_from_token_str(&token, secret).expect("decode campus token");
        assert_eq!(context.user_id, "campus-user");
        assert_eq!(context.campus_id, Some(campus_id));
        assert!(context.has_recent_authentication());

        let (legacy_token, _, _) = generate_access_token_for_campus_with_auth_time(
            "legacy-user",
            "user",
            None,
            None,
            secret,
            3600,
        )
        .expect("legacy-compatible token");
        let legacy_context = extract_auth_session_from_token_str(&legacy_token, secret)
            .expect("decode legacy-compatible token");
        assert_eq!(legacy_context.campus_id, None);
        assert!(!legacy_context.has_recent_authentication());
    }

    #[test]
    fn test_auth_request_validation_concerns() {
        // These are compile-time checks via struct validation
        // The actual validation happens in the handler, but we can test the logic
        let req = AuthRequest {
            username: "testuser".to_string(),
            email: None,
            password: "password123".to_string(),
        };
        assert_eq!(req.username.len(), 8);
        assert_eq!(req.password.len(), 11);
    }

    #[test]
    fn test_auth_request_deserialization() {
        let json = r#"{"username": "alice", "password": "secretpass"}"#;
        let req: AuthRequest = serde_json::from_str(json).unwrap();
        assert_eq!(req.username, "alice");
        assert_eq!(req.password, "secretpass");
    }

    #[test]
    fn test_auth_response_serialization() {
        let resp = AuthResponse {
            token: "jwt.token.here".to_string(),
            refresh_token: "refresh.here".to_string(),
            user_id: "user-abc".to_string(),
            username: "alice".to_string(),
            active_campus_id: None,
            message: "登录成功".to_string(),
        };
        let json = serde_json::to_string(&resp).unwrap();
        assert!(json.contains("jwt.token.here"));
        assert!(json.contains("refresh.here"));
        assert!(json.contains("user-abc"));
        assert!(json.contains("alice"));
        assert!(json.contains("登录成功"));
    }

    #[test]
    fn test_claims_serialization() {
        let claims = Claims {
            sub: "user-xyz".to_string(),
            role: "user".to_string(),
            exp: 1700000000,
            jti: "jti-xyz".to_string(),
            campus_id: None,
            auth_time: Some(1699999999),
        };
        let json = serde_json::to_string(&claims).unwrap();
        assert!(json.contains("user-xyz"));
        assert!(json.contains("1700000000"));
        assert!(json.contains("jti-xyz"));
    }

    #[test]
    fn test_claims_deserialization() {
        let json = r#"{"sub": "user-123", "role": "admin", "exp": 1700000000, "jti": "jti-123"}"#;
        let claims: Claims = serde_json::from_str(json).unwrap();
        assert_eq!(claims.sub, "user-123");
        assert_eq!(claims.role, "admin");
        assert_eq!(claims.exp, 1700000000);
        assert_eq!(claims.jti, "jti-123");
        assert!(claims.auth_time.is_none());
    }

    #[test]
    fn test_claims_deserialization_without_jti_fails() {
        let json = r#"{"sub": "user-legacy", "role": "user", "exp": 1700000000}"#;
        let claims: Result<Claims, _> = serde_json::from_str(json);
        assert!(claims.is_err());
    }

    #[test]
    fn test_generate_token_with_empty_user_id() {
        let (token, _jti, _exp) =
            generate_access_token("", "user", "secret123456789012345678901234567890", 3600)
                .unwrap();
        let parts: Vec<&str> = token.split('.').collect();
        assert_eq!(parts.len(), 3);
    }

    #[test]
    fn test_generate_token_verifies_correctly() {
        let secret = "secret123456789012345678901234567890";
        let (token, _jti, _exp) =
            generate_access_token("test-user", "admin", secret, 3600).unwrap();
        let extracted = extract_user_id_from_token(
            &{
                let mut h = HeaderMap::new();
                h.insert(
                    "Authorization",
                    format!("Bearer {}", token).parse().unwrap(),
                );
                h
            },
            secret,
        );
        assert!(extracted.is_ok());
        assert_eq!(extracted.unwrap(), "test-user");
    }

    #[test]
    fn test_generate_token_includes_role() {
        let secret = "secret123456789012345678901234567890";
        let (token, _jti, _exp) =
            generate_access_token("test-user", "admin", secret, 3600).unwrap();
        let (user_id, role) = extract_user_id_and_role_from_token_str(&token, secret).unwrap();
        assert_eq!(user_id, "test-user");
        assert_eq!(role, "admin");
    }

    #[test]
    fn test_extract_user_id_accepts_valid_token() {
        let secret = "secret_12345678901234567890123456789012";
        let (token, _jti, _exp) =
            generate_access_token("valid-user", "user", secret, 3600).unwrap();

        let extracted = extract_user_id_from_token_str(&token, secret);
        assert!(extracted.is_ok());
        assert_eq!(extracted.unwrap(), "valid-user");
    }

    #[test]
    fn test_extract_user_id_rejects_wrong_secret() {
        let secret = "secret_12345678901234567890123456789012";
        let wrong_secret = "wrong_secret_1234567890123456789012345";
        let (token, _jti, _exp) =
            generate_access_token("valid-user", "user", secret, 3600).unwrap();

        let extracted = extract_user_id_from_token_str(&token, wrong_secret);
        assert!(extracted.is_err());
    }

    #[test]
    fn test_extract_user_id_and_role_accepts_valid_token() {
        let secret = "secret_12345678901234567890123456789012";
        let (token, _jti, _exp) =
            generate_access_token("test-admin", "admin", secret, 3600).unwrap();

        let extracted = extract_user_id_and_role_from_token_str(&token, secret).unwrap();
        assert_eq!(extracted.0, "test-admin");
        assert_eq!(extracted.1, "admin");
    }

    #[test]
    fn test_extract_user_id_from_header_accepts_valid_token() {
        let secret = "secret_12345678901234567890123456789012";
        let (token, _jti, _exp) =
            generate_access_token("header-user", "user", secret, 3600).unwrap();

        let mut headers = HeaderMap::new();
        headers.insert(
            "Authorization",
            format!("Bearer {}", token).parse().unwrap(),
        );

        let extracted = extract_user_id_from_token(&headers, secret);
        assert!(extracted.is_ok());
        assert_eq!(extracted.unwrap(), "header-user");
    }

    #[test]
    fn test_extract_jti_from_token() {
        let secret = "secret_12345678901234567890123456789012";
        let (token, expected_jti, _exp) =
            generate_access_token("user-jti", "user", secret, 3600).unwrap();

        let jti = extract_jti_from_token_str(&token, secret).unwrap();
        assert_eq!(jti, expected_jti);
    }

    #[test]
    fn test_extract_claims_from_token_success() {
        let secret = "test_current_secret_32_characters_long";
        let campus_id = Uuid::new_v4();

        let (token, jti, exp) =
            generate_access_token_for_campus("user-1", "user", Some(campus_id), secret, 3600)
                .expect("generate current token");
        let mut headers = HeaderMap::new();
        headers.insert("Authorization", format!("Bearer {token}").parse().unwrap());

        let claims =
            extract_claims_from_token(&headers, secret).expect("extract claims with secret");
        assert_eq!(claims.sub, "user-1");
        assert_eq!(claims.campus_id, Some(campus_id));
        assert_eq!(claims.jti, jti);
        assert_eq!(claims.exp, exp);

        // Missing Authorization header
        let empty_headers = HeaderMap::new();
        let err = extract_claims_from_token(&empty_headers, secret);
        assert!(matches!(err, Err(ApiError::Unauthorized)));

        // Invalid Authorization format
        let mut malformed_headers = HeaderMap::new();
        malformed_headers.insert("Authorization", "Basic 12345".parse().unwrap());
        let err = extract_claims_from_token(&malformed_headers, secret);
        assert!(matches!(err, Err(ApiError::Unauthorized)));
    }

    #[tokio::test]
    async fn test_revoke_refresh_token_is_single_use() {
        with_test_pool(|pool| async move {
            sqlx::query(
                "INSERT INTO users (id, username, password_hash, role) VALUES ($1, $2, 'hash', 'user')",
            )
            .bind("auth-user-single-use")
            .bind("auth_single_use")
            .execute(&pool)
            .await
            .expect("insert user");

            let auth_repo = PostgresAuthRepository::new(pool.clone());
            let token_hash = hash_token("single-use-refresh-token");
            let expires_at = chrono::Utc::now() + chrono::Duration::hours(1);

            sqlx::query(
                "INSERT INTO refresh_tokens (user_id, token_hash, expires_at) VALUES ($1, $2, $3)",
            )
            .bind("auth-user-single-use")
            .bind(&token_hash)
            .bind(expires_at)
            .execute(&pool)
            .await
            .expect("insert refresh token");

            auth_repo
                .revoke_refresh_token(&token_hash)
                .await
                .expect("first revoke should succeed");

            let second = auth_repo.revoke_refresh_token(&token_hash).await;
            assert!(matches!(second, Err(ApiError::Unauthorized)));
        })
        .await;
    }

    #[tokio::test]
    async fn test_rotate_refresh_replay_revokes_all_user_sessions() {
        with_test_pool(|pool| async move {
            let user_id = "auth-user-replay";
            sqlx::query(
                "INSERT INTO users (id, username, password_hash, role) VALUES ($1, $2, 'hash', 'user')",
            )
            .bind(user_id)
            .bind("auth_replay")
            .execute(&pool)
            .await
            .expect("insert user");

            let revoked_hash = hash_token("revoked-refresh-token");
            let active_hash = hash_token("active-refresh-token");
            let expires_at = chrono::Utc::now() + chrono::Duration::hours(1);

            sqlx::query(
                "INSERT INTO refresh_tokens (user_id, token_hash, expires_at, revoked_at) VALUES ($1, $2, $3, NOW())",
            )
            .bind(user_id)
            .bind(&revoked_hash)
            .bind(expires_at)
            .execute(&pool)
            .await
            .expect("insert revoked token");

            sqlx::query(
                "INSERT INTO refresh_tokens (user_id, token_hash, expires_at) VALUES ($1, $2, $3)",
            )
            .bind(user_id)
            .bind(&active_hash)
            .bind(expires_at)
            .execute(&pool)
            .await
            .expect("insert active token");

            let auth_repo = PostgresAuthRepository::new(pool.clone());
            let user_repo = PostgresUserRepository::new(pool.clone());
            let campus_service = CampusService::new(pool.clone());

            let result = rotate_refresh_token(
                &auth_repo,
                &user_repo,
                "revoked-refresh-token",
                "test_jwt_secret_at_least_32_characters_long",
                &campus_service,
                None,
                None,
            )
            .await;
            assert!(result.is_err());

            let active_count: i64 = sqlx::query_scalar(
                "SELECT COUNT(*) FROM refresh_tokens WHERE user_id = $1 AND revoked_at IS NULL",
            )
            .bind(user_id)
            .fetch_one(&pool)
            .await
            .expect("count active tokens");

            assert_eq!(active_count, 0);
        })
        .await;
    }

    #[tokio::test]
    async fn test_create_user_dual_writes_shadow_uuid_column() {
        with_test_pool(|pool| async move {
            let auth_repo = PostgresAuthRepository::new(pool.clone());

            let user_id = auth_repo
                .create_user("shadow_user", Some("shadow@example.com"), "hash")
                .await
                .expect("create user");
            let user_uuid = Uuid::parse_str(&user_id).expect("uuid id");

            let row = sqlx::query("SELECT new_id, username, email FROM users WHERE id = $1")
                .bind(&user_id)
                .fetch_one(&pool)
                .await
                .expect("select user");

            assert_eq!(row.get::<Uuid, _>("new_id"), user_uuid);
            assert_eq!(row.get::<String, _>("username"), "shadow_user");
            assert_eq!(
                row.get::<Option<String>, _>("email").as_deref(),
                Some("shadow@example.com")
            );
        })
        .await;
    }

    #[tokio::test]
    async fn test_change_password_updates_hash_via_repository_path() {
        with_test_pool(|pool| async move {
            let old_hash = hash_password("current-pass-123".to_string())
                .await
                .expect("hash password");

            let user_repo = PostgresUserRepository::new(pool.clone());
            let user_id = user_repo
                .create("change_password_user", None, &old_hash, "user")
                .await
                .expect("create user");

            let state = build_test_state(pool.clone());
            let (token, _jti, _exp) =
                generate_access_token(&user_id, "user", &state.secrets.jwt_secret, 3600)
                    .expect("generate token");

            let mut headers = HeaderMap::new();
            headers.insert(
                "Authorization",
                format!("Bearer {}", token).parse().unwrap(),
            );

            let _ = change_password(
                State(state),
                headers,
                Json(ChangePasswordRequest {
                    current_password: "current-pass-123".to_string(),
                    new_password: "brand-new-pass-456".to_string(),
                }),
            )
            .await
            .expect("change password");

            let updated_hash: String =
                sqlx::query_scalar("SELECT password_hash FROM users WHERE id = $1")
                    .bind(&user_id)
                    .fetch_one(&pool)
                    .await
                    .expect("select updated hash");

            assert!(
                verify_password("brand-new-pass-456".to_string(), updated_hash)
                    .await
                    .expect("new password verifies")
            );
        })
        .await;
    }

    #[tokio::test]
    async fn test_reauthenticate_rejects_wrong_password_and_issues_recent_token() {
        with_test_pool(|pool| async move {
            let password = "reauth-pass-123";
            let password_hash = hash_password(password.to_string())
                .await
                .expect("hash password");
            let user_repo = PostgresUserRepository::new(pool.clone());
            let user_id = user_repo
                .create(
                    &format!("reauth_{}", Uuid::new_v4()),
                    None,
                    &password_hash,
                    "admin",
                )
                .await
                .expect("create admin");
            let state = build_test_state(pool);
            let (stale_token, _, _) = generate_access_token_for_campus_with_auth_time(
                &user_id,
                "admin",
                None,
                None,
                &state.secrets.jwt_secret,
                3600,
            )
            .expect("stale token");
            let mut headers = HeaderMap::new();
            headers.insert(
                "Authorization",
                format!("Bearer {stale_token}").parse().expect("header"),
            );

            let error = reauthenticate(
                State(state.clone()),
                headers.clone(),
                Json(ReauthenticateRequest {
                    password: "wrong-password".to_string(),
                    totp_code: None,
                }),
            )
            .await
            .err()
            .expect("wrong password must fail");
            assert!(matches!(error, ApiError::RecentAuthenticationFailed));

            let response = reauthenticate(
                State(state.clone()),
                headers,
                Json(ReauthenticateRequest {
                    password: password.to_string(),
                    totp_code: None,
                }),
            )
            .await
            .expect("reauthenticate")
            .0;
            let context =
                extract_auth_session_from_token_str(&response.token, &state.secrets.jwt_secret)
                    .expect("decode recent token");
            assert_eq!(context.user_id, user_id);
            assert!(context.has_recent_authentication());
            assert!(response.recent_auth_expires_at > chrono::Utc::now());
        })
        .await;
    }

    #[tokio::test]
    async fn test_switch_active_campus_rotates_session_and_revokes_access_token() {
        with_test_pool(|pool| async move {
            let suffix = Uuid::new_v4();
            let user_repo = PostgresUserRepository::new(pool.clone());
            let user_id = user_repo
                .create(&format!("campus_switch_{suffix}"), None, "hash", "user")
                .await
                .expect("create user");
            let ncu_id = Uuid::parse_str("c0000000-0000-0000-0000-000000000001").expect("ncu id");
            let second_campus_id = Uuid::new_v4();
            sqlx::query(
                "INSERT INTO campuses (id, slug, name_zh, name_en, email_domains)
                 VALUES ($1, $2, '第二校园', 'Second Campus', ARRAY['second.example.edu'])",
            )
            .bind(second_campus_id)
            .bind(format!("second-{suffix}"))
            .execute(&pool)
            .await
            .expect("insert second campus");
            sqlx::query(
                "UPDATE campus_memberships
                 SET status = 'verified', verification_method = 'test', verified_at = NOW()
                 WHERE campus_id = $1 AND user_id = $2",
            )
            .bind(ncu_id)
            .bind(&user_id)
            .execute(&pool)
            .await
            .expect("verify ncu membership");
            sqlx::query(
                "INSERT INTO campus_memberships (
                    campus_id, user_id, status, role, verification_method, verified_at
                 ) VALUES ($1, $2, 'verified', 'member', 'test', NOW())",
            )
            .bind(second_campus_id)
            .bind(&user_id)
            .execute(&pool)
            .await
            .expect("insert second verified membership");

            let state = build_test_state(pool.clone());
            let current_refresh = format!("refresh-{suffix}");
            state
                .auth_repo
                .store_refresh_token(
                    &user_id,
                    &hash_token(&current_refresh),
                    chrono::Utc::now() + chrono::Duration::hours(1),
                    Some(ncu_id),
                )
                .await
                .expect("store current refresh token");
            let (current_access, current_jti, _) = generate_access_token_for_campus(
                &user_id,
                "user",
                Some(ncu_id),
                &state.secrets.jwt_secret,
                3600,
            )
            .expect("current access token");
            let mut headers = HeaderMap::new();
            headers.insert(
                "Authorization",
                format!("Bearer {current_access}").parse().expect("header"),
            );

            let response = switch_active_campus(
                State(state.clone()),
                headers,
                Json(SwitchCampusRequest {
                    campus_id: second_campus_id,
                    refresh_token: current_refresh,
                }),
            )
            .await
            .expect("switch active campus")
            .0;
            assert_eq!(response.active_campus_id, second_campus_id);
            let new_context =
                extract_auth_session_from_token_str(&response.token, &state.secrets.jwt_secret)
                    .expect("decode switched access token");
            assert_eq!(new_context.campus_id, Some(second_campus_id));
            assert!(!new_context.has_recent_authentication());

            let new_record = state
                .auth_repo
                .find_refresh_token(&hash_token(&response.refresh_token))
                .await
                .expect("load switched refresh token")
                .expect("switched refresh token exists");
            assert_eq!(new_record.user_id, user_id);
            assert_eq!(new_record.campus_id, Some(second_campus_id));
            let revoked: bool = sqlx::query_scalar(
                "SELECT EXISTS(SELECT 1 FROM revoked_access_tokens WHERE jti = $1)",
            )
            .bind(current_jti)
            .fetch_one(&pool)
            .await
            .expect("check access revocation");
            assert!(revoked);
        })
        .await;
    }

    #[tokio::test]
    async fn test_hash_and_verify_password_round_trip() {
        let password = "test_secure_password_123".to_string();
        let hash = hash_password(password.clone())
            .await
            .expect("hash_password succeeds");
        assert!(hash.starts_with("$argon2"));

        let matches = verify_password(password, hash.clone())
            .await
            .expect("verify_password succeeds");
        assert!(matches);

        let wrong_matches = verify_password("wrong_password".to_string(), hash)
            .await
            .expect("verify_password succeeds");
        assert!(!wrong_matches);
    }

    #[tokio::test]
    async fn test_verify_password_invalid_hash_returns_false() {
        let matches = verify_password(
            "test_password".to_string(),
            "invalid_hash_string".to_string(),
        )
        .await
        .expect("verify_password with invalid hash should return Ok(false)");
        assert!(!matches);
    }
}
