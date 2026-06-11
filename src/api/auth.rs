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
    pub message: String,
}

#[derive(Debug, Serialize, Deserialize)]
struct Claims {
    sub: String,         // subject (user_id)
    role: String,        // user role: "user" or "admin"
    exp: usize,          // expiration time
    jti: Option<String>, // JWT ID for denylist revocation (optional for legacy tokens)
}

/// Refresh token: 7 days validity
const REFRESH_TOKEN_TTL_SECS: u64 = 7 * 24 * 3600;
/// Access token: 24 hours validity (long enough for persistent WS connections)
pub const ACCESS_TOKEN_TTL_SECS: u64 = 24 * 3600;

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
pub fn generate_access_token(
    user_id: &str,
    role: &str,
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
        jti: Some(jti.clone()),
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
) -> anyhow::Result<()> {
    let token_hash = hash_token(token);
    let expires_at = chrono::Utc::now() + chrono::Duration::seconds(ttl_secs as i64);

    auth_repo
        .store_refresh_token(user_id, &token_hash, expires_at)
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
) -> anyhow::Result<(String, String)> {
    let token_hash = hash_token(token);

    // Find the token
    let token_data = auth_repo
        .find_refresh_token(&token_hash)
        .await
        .map_err(|e| anyhow::anyhow!("DB error: {}", e))?;

    let (user_id, revoked_at, expires_at) = match token_data {
        Some(data) => data,
        None => return Err(anyhow::anyhow!("Invalid refresh token")),
    };

    // Check revoked
    if revoked_at.is_some() {
        auth_repo
            .revoke_all_user_tokens(&user_id)
            .await
            .map_err(|e| anyhow::anyhow!("DB error: {}", e))?;
        return Err(anyhow::anyhow!("Refresh token has been revoked"));
    }

    // Check expiry
    if expires_at < chrono::Utc::now() {
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

    // Issue new tokens
    let new_refresh = generate_refresh_token();
    store_refresh_token(auth_repo, &user_id, &new_refresh, REFRESH_TOKEN_TTL_SECS).await?;
    let (new_access, _jti, _exp) =
        generate_access_token(&user_id, &role, jwt_secret, ACCESS_TOKEN_TTL_SECS)?;

    Ok((new_access, new_refresh))
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

fn validate_ncu_email(email: &str) -> Result<(), ApiError> {
    if email.is_empty() {
        return Err(ApiError::BadRequest("邮箱不能为空".to_string()));
    }
    if email.len() > 100 {
        return Err(ApiError::BadRequest("邮箱不能超过100个字符".to_string()));
    }

    let Some((local, domain)) = email.split_once('@') else {
        return Err(ApiError::BadRequest("邮箱格式无效".to_string()));
    };
    if domain.contains('@') || !domain.eq_ignore_ascii_case("email.ncu.edu.cn") {
        return Err(ApiError::BadRequest(
            "必须使用 @email.ncu.edu.cn 邮箱注册".to_string(),
        ));
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
}

#[derive(Deserialize)]
pub struct LogoutRequest {
    pub refresh_token: Option<String>,
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

    // Validate email domain (optional but validated if provided)
    if let Some(ref email) = payload.email {
        validate_ncu_email(email)?;
    }

    let password = payload.password.clone();

    // Hash password in a blocking task to avoid starving the tokio runtime
    let hash_result = tokio::task::spawn_blocking(move || {
        let salt = SaltString::generate(&mut OsRng);
        let argon2 = Argon2::default();
        argon2
            .hash_password(password.as_bytes(), &salt)
            .map(|h| h.to_string())
    })
    .await;

    let password_hash = match hash_result {
        Ok(Ok(hash)) => hash,
        Ok(Err(e)) => {
            tracing::error!(err = %e, "Password hashing failed");
            return Err(ApiError::Internal(anyhow::anyhow!(
                "Password hashing failed: {}",
                e
            )));
        }
        Err(e) => {
            tracing::error!(err = %e, "Spawning hashing task failed");
            return Err(ApiError::Internal(anyhow::anyhow!("Internal error: {}", e)));
        }
    };

    // Create user via repository
    let user_id = state
        .auth_repo
        .create_user(&payload.username, payload.email.as_deref(), &password_hash)
        .await;

    match user_id {
        Ok(user_id) => {
            let (token, _jti, _exp) = generate_access_token(
                &user_id,
                "user",
                &state.secrets.jwt_secret,
                ACCESS_TOKEN_TTL_SECS,
            )?;
            let refresh = generate_refresh_token();
            store_refresh_token(&state.auth_repo, &user_id, &refresh, REFRESH_TOKEN_TTL_SECS)
                .await
                .map_err(|e| {
                    ApiError::Internal(anyhow::anyhow!("Failed to store refresh token: {}", e))
                })?;
            Ok(Json(AuthResponse {
                token,
                refresh_token: refresh,
                user_id,
                username: payload.username.clone(),
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

    let password = payload.password.clone();
    let hash_clone = user.password_hash.clone();

    // Verify password in a blocking task
    let verify_result = tokio::task::spawn_blocking(move || -> bool {
        let parsed_hash = match PasswordHash::new(&hash_clone) {
            Ok(h) => h,
            Err(_) => return false,
        };
        Argon2::default()
            .verify_password(password.as_bytes(), &parsed_hash)
            .is_ok()
    })
    .await;

    match verify_result {
        Ok(true) => {
            let (token, _jti, _exp) = generate_access_token(
                &user.id,
                &user.role,
                &state.secrets.jwt_secret,
                ACCESS_TOKEN_TTL_SECS,
            )?;
            let refresh = generate_refresh_token();
            store_refresh_token(&state.auth_repo, &user.id, &refresh, REFRESH_TOKEN_TTL_SECS)
                .await
                .map_err(|e| {
                    ApiError::Internal(anyhow::anyhow!("Failed to store refresh token: {}", e))
                })?;
            Ok(Json(AuthResponse {
                token,
                refresh_token: refresh,
                user_id: user.id,
                username: user.username.clone(),
                message: "登录成功".to_string(),
            }))
        }
        Ok(false) => {
            // Return 401 for wrong password — do NOT distinguish from wrong username
            tracing::warn!(username = %payload.username, "Login failed — wrong password");
            Err(ApiError::AuthFailed("用户名或密码错误".to_string()))
        }
        Err(e) => {
            tracing::error!(err = %e, "Password verification task failed");
            Err(ApiError::Internal(anyhow::anyhow!("Internal error: {}", e)))
        }
    }
}

/// POST /api/auth/refresh — rotate a refresh token, returns new access + refresh token pair
pub async fn refresh_token(
    State(state): State<AppState>,
    Json(payload): Json<RefreshTokenRequest>,
) -> Result<Json<RefreshResponse>, ApiError> {
    let (new_access, new_refresh) = rotate_refresh_token(
        &state.auth_repo,
        &state.user_repo,
        &payload.refresh_token,
        &state.secrets.jwt_secret,
    )
    .await
    .map_err(|e| {
        tracing::warn!(err = %e, "Refresh token rotation failed");
        ApiError::Unauthorized
    })?;

    Ok(Json(RefreshResponse {
        token: new_access,
        refresh_token: new_refresh,
    }))
}

/// POST /api/auth/logout — revoke refresh token(s) to invalidate the session
pub async fn logout(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(payload): Json<LogoutRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let user_id = extract_user_id_from_token_with_fallback(
        &headers,
        &state.secrets.jwt_secret,
        state.secrets.jwt_secret_old.as_deref(),
    )
    .map_err(|_| ApiError::Unauthorized)?;

    let token = headers
        .get("Authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .ok_or(ApiError::Unauthorized)?;
    let claims = decode_claims_from_token_str_with_fallback(
        token,
        &state.secrets.jwt_secret,
        state.secrets.jwt_secret_old.as_deref(),
    )
    .map_err(|_| ApiError::Unauthorized)?;

    if let Some(jti) = claims.jti.as_deref() {
        let expires_at = chrono::DateTime::<chrono::Utc>::from_timestamp(claims.exp as i64, 0)
            .unwrap_or_else(chrono::Utc::now);
        revoke_access_token_jti(&state, jti, expires_at).await?;
    }

    if let Some(ref token) = payload.refresh_token {
        revoke_refresh_token(&state.auth_repo, token).await?;
    }
    revoke_all_refresh_tokens(&state.auth_repo, &user_id).await?;

    tracing::info!(user_id = %user_id, "User logged out, all sessions revoked");

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
    let user_id = extract_user_id_from_token_with_fallback(
        &headers,
        &state.secrets.jwt_secret,
        state.secrets.jwt_secret_old.as_deref(),
    )
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

    let verify_result = tokio::task::spawn_blocking(move || -> bool {
        let parsed_hash = match PasswordHash::new(&user.password_hash) {
            Ok(h) => h,
            Err(_) => return false,
        };
        Argon2::default()
            .verify_password(payload.current_password.as_bytes(), &parsed_hash)
            .is_ok()
    })
    .await;

    match verify_result {
        Ok(true) => {}
        Ok(false) => {
            tracing::warn!(user_id = %user_id, "Password change failed — wrong current password");
            return Err(ApiError::AuthFailed("当前密码错误".to_string()));
        }
        Err(e) => {
            tracing::error!(err = %e, "Password verification task failed");
            return Err(ApiError::Internal(anyhow::anyhow!("Internal error: {}", e)));
        }
    }

    let new_hash = tokio::task::spawn_blocking(move || {
        let salt = SaltString::generate(&mut OsRng);
        Argon2::default()
            .hash_password(payload.new_password.as_bytes(), &salt)
            .map(|h| h.to_string())
    })
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("Hashing error: {}", e)))?
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("Hashing error: {}", e)))?;

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

fn decode_claims_from_token_str(token: &str, jwt_secret: &str) -> Result<Claims, String> {
    let token_data = decode::<Claims>(
        token,
        &DecodingKey::from_secret(jwt_secret.as_bytes()),
        &Validation::default(),
    )
    .map_err(|e| format!("Invalid token: {}", e))?;

    Ok(token_data.claims)
}

fn decode_claims_from_token_str_with_fallback(
    token: &str,
    jwt_secret: &str,
    jwt_secret_old: Option<&str>,
) -> Result<Claims, String> {
    match decode_claims_from_token_str(token, jwt_secret) {
        Ok(claims) => Ok(claims),
        Err(primary_err) => {
            if let Some(old) = jwt_secret_old {
                decode_claims_from_token_str(token, old)
                    .map_err(|_| format!("Invalid token (primary+fallback): {}", primary_err))
            } else {
                Err(primary_err)
            }
        }
    }
}

pub fn extract_jti_from_token_str(token: &str, jwt_secret: &str) -> Result<String, String> {
    let claims = decode_claims_from_token_str(token, jwt_secret)?;
    claims.jti.ok_or_else(|| "Token missing jti".to_string())
}

pub fn extract_jti_from_token_str_with_fallback(
    token: &str,
    jwt_secret: &str,
    jwt_secret_old: Option<&str>,
) -> Result<String, String> {
    match extract_jti_from_token_str(token, jwt_secret) {
        Ok(jti) => Ok(jti),
        Err(primary_err) => {
            if let Some(old) = jwt_secret_old {
                match extract_jti_from_token_str(token, old) {
                    Ok(jti) => Ok(jti),
                    Err(fallback_err) if fallback_err == "Token missing jti" => Err(fallback_err),
                    Err(_) => Err(format!("Invalid token (primary+fallback): {}", primary_err)),
                }
            } else {
                Err(primary_err)
            }
        }
    }
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
///
/// For legacy tokens without jti, this returns Ok(()) to preserve backward compatibility
/// during rollout; those tokens still expire normally via JWT exp.
pub async fn ensure_token_not_revoked(state: &AppState, token: &str) -> Result<(), String> {
    let jti = match extract_jti_from_token_str_with_fallback(
        token,
        &state.secrets.jwt_secret,
        state.secrets.jwt_secret_old.as_deref(),
    ) {
        Ok(jti) => jti,
        Err(err) if err.contains("Token missing jti") => return Ok(()),
        Err(err) => return Err(err),
    };

    state.infra.token_denylist.cleanup_expired();
    if state.infra.token_denylist.is_denied(&jti) {
        return Err("Token revoked".to_string());
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
        Ok(_) => Ok(()),
        Err(e) => Err(format!("Denylist query failed: {}", e)),
    }
}

pub async fn ensure_user_not_banned(state: &AppState, user_id: &str) -> Result<(), ApiError> {
    let status = sqlx::query_scalar::<_, String>("SELECT status FROM users WHERE id = $1")
        .bind(user_id)
        .fetch_optional(&state.infra.db)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
        .ok_or(ApiError::Unauthorized)?;

    if status.eq_ignore_ascii_case("banned") {
        return Err(ApiError::AuthFailed("账号已被封禁".to_string()));
    }

    Ok(())
}

pub fn extract_user_id_from_token_str_with_fallback(
    token: &str,
    jwt_secret: &str,
    jwt_secret_old: Option<&str>,
) -> Result<String, String> {
    match extract_user_id_from_token_str(token, jwt_secret) {
        Ok(user_id) => Ok(user_id),
        Err(primary_err) => {
            if let Some(old) = jwt_secret_old {
                extract_user_id_from_token_str(token, old)
                    .map_err(|_| format!("Invalid token (primary+fallback): {}", primary_err))
            } else {
                Err(primary_err)
            }
        }
    }
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

pub fn extract_user_id_and_role_from_token_str_with_fallback(
    token: &str,
    jwt_secret: &str,
    jwt_secret_old: Option<&str>,
) -> Result<(String, String), String> {
    match extract_user_id_and_role_from_token_str(token, jwt_secret) {
        Ok(v) => Ok(v),
        Err(primary_err) => {
            if let Some(old) = jwt_secret_old {
                extract_user_id_and_role_from_token_str(token, old)
                    .map_err(|_| format!("Invalid token (primary+fallback): {}", primary_err))
            } else {
                Err(primary_err)
            }
        }
    }
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

pub fn extract_user_id_from_token_with_fallback(
    headers: &HeaderMap,
    jwt_secret: &str,
    jwt_secret_old: Option<&str>,
) -> Result<String, String> {
    let auth_header = headers
        .get("Authorization")
        .and_then(|v| v.to_str().ok())
        .ok_or_else(|| "Missing Authorization header".to_string())?;

    let token = auth_header
        .strip_prefix("Bearer ")
        .ok_or_else(|| "Invalid Authorization format".to_string())?;

    extract_user_id_from_token_str_with_fallback(token, jwt_secret, jwt_secret_old)
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

#[allow(dead_code)]
pub fn extract_user_id_and_role_from_token_with_fallback(
    headers: &HeaderMap,
    jwt_secret: &str,
    jwt_secret_old: Option<&str>,
) -> Result<(String, String), String> {
    let auth_header = headers
        .get("Authorization")
        .and_then(|v| v.to_str().ok())
        .ok_or_else(|| "Missing Authorization header".to_string())?;

    let token = auth_header
        .strip_prefix("Bearer ")
        .ok_or_else(|| "Invalid Authorization format".to_string())?;

    extract_user_id_and_role_from_token_str_with_fallback(token, jwt_secret, jwt_secret_old)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agents::router::IntentRouter;
    use crate::api::{ApiAgents, ApiInfrastructure, ApiSecrets, AppState};
    use crate::repositories::{AuthRepository, PostgresAuthRepository, PostgresUserRepository};
    use crate::services::{self, notification::NotificationService};
    use crate::test_infra::with_test_pool;
    use axum::{extract::State, Json};
    use sqlx::Row;
    use std::sync::Arc;

    fn build_test_state(pool: sqlx::PgPool) -> AppState {
        let (service_manager, _rx) = services::ServiceManager::new(pool.clone());
        let admin_service = service_manager.admin.clone();
        let event_tx = service_manager.event_tx.clone();

        AppState {
            secrets: ApiSecrets {
                jwt_secret: "test_jwt_secret_at_least_32_characters_long".to_string(),
                jwt_secret_old: None,
                gemini_api_key: "test-gemini-key".to_string(),
                oss_endpoint: "https://oss-cn-beijing.aliyuncs.com".to_string(),
                oss_bucket: "test-bucket".to_string(),
                oss_role_arn: None,
                oss_access_key_id: None,
                oss_access_key_secret: None,
            },
            infra: ApiInfrastructure {
                db: pool.clone(),
                event_tx,
                rate_limit: {
                    let factory = crate::middleware::rate_limit::RateLimiterFactory::new(100, 60);
                    crate::middleware::rate_limit::RateLimitStateHandle::new(factory.build_local())
                },
                notification: NotificationService::new(pool.clone()),
                ws_connections: crate::api::ws::new_ws_state(),
                metrics: Arc::new(crate::api::metrics::MetricsService::new()),
                order_service: services::order::OrderService::new(pool.clone()),
                admin_service,
                moderation: services::moderation::ModerationService::new(
                    &crate::config::AppConfig {
                        gemini_api_key: "test-gemini-key".to_string(),
                        minimax_api_key: None,
                        minimax_api_base_url: None,
                        llm_api_key: None,
                        jwt_secret: "test_jwt_secret_at_least_32_characters_long".to_string(),
                        jwt_secret_old: None,
                        database_url: "postgres://test/test".to_string(),
                        oss_access_key_id: None,
                        oss_access_key_secret: None,
                        llm_provider: "gemini".to_string(),
                        llm_model: "gemini-3-flash-preview".to_string(),
                        llm_base_url: None,
                        vector_dim: 768,
                        cors_origins: vec![],
                        oss_endpoint: "https://oss-cn-beijing.aliyuncs.com".to_string(),
                        oss_bucket: "test-bucket".to_string(),
                        oss_role_arn: None,
                        redis_url: None,
                        rate_limit_max_requests: 100,
                        rate_limit_window_secs: 60,
                        server_host: "127.0.0.1".to_string(),
                        server_port: 3000,
                        event_bus_capacity: 2048,
                        hitl_expire_scan_interval_secs: 600,
                        hitl_expire_timeout_hours: 48,
                        moka_cache_max_capacity: 100_000,
                        access_token_ttl_secs: 86_400,
                        refresh_token_ttl_secs: 604_800,
                        conversation_history_limit: 10,
                        max_keyword_len: 200,
                        price_tolerance: 0.5,
                        categories: vec!["other".to_string()],
                        blocked_keywords: vec![],
                        moderation_image_enabled: false,
                        moderation_image_api_url: None,
                        moderation_image_api_key: None,
                    },
                ),
                token_denylist: services::token_denylist::TokenDenylist::new(),
            },
            agents: ApiAgents {
                llm_provider: Arc::new(
                    crate::llm::gemini::GeminiProvider::new("test-key", 768)
                        .expect("gemini provider init"),
                ),
                router: IntentRouter::new(vec![]),
            },
            listing_repo: crate::repositories::PostgresListingRepository::new(pool.clone()),
            user_repo: PostgresUserRepository::new(pool.clone()),
            chat_repo: crate::repositories::PostgresChatRepository::new(pool.clone()),
            auth_repo: PostgresAuthRepository::new(pool.clone()),
            order_repo: crate::repositories::PostgresOrderRepository::new(pool),
        }
    }

    #[derive(Serialize)]
    struct LegacyClaims {
        sub: String,
        role: String,
        exp: usize,
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
            jti: Some("jti-xyz".to_string()),
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
        assert_eq!(claims.jti.as_deref(), Some("jti-123"));
    }

    #[test]
    fn test_claims_deserialization_legacy_without_jti() {
        let json = r#"{"sub": "user-legacy", "role": "user", "exp": 1700000000}"#;
        let claims: Claims = serde_json::from_str(json).unwrap();
        assert_eq!(claims.sub, "user-legacy");
        assert_eq!(claims.role, "user");
        assert_eq!(claims.exp, 1700000000);
        assert!(claims.jti.is_none());
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
    fn test_extract_user_id_with_fallback_accepts_old_secret_token() {
        let current_secret = "current_secret_1234567890123456789012";
        let old_secret = "old_secret_12345678901234567890123456";
        let (token, _jti, _exp) =
            generate_access_token("legacy-user", "user", old_secret, 3600).unwrap();

        let extracted =
            extract_user_id_from_token_str_with_fallback(&token, current_secret, Some(old_secret));

        assert!(extracted.is_ok());
        assert_eq!(extracted.unwrap(), "legacy-user");
    }

    #[test]
    fn test_extract_user_id_with_fallback_rejects_without_old_secret() {
        let current_secret = "current_secret_1234567890123456789012";
        let old_secret = "old_secret_12345678901234567890123456";
        let (token, _jti, _exp) =
            generate_access_token("legacy-user", "user", old_secret, 3600).unwrap();

        let extracted = extract_user_id_from_token_str_with_fallback(&token, current_secret, None);

        assert!(extracted.is_err());
    }

    #[test]
    fn test_extract_user_id_with_fallback_rejects_malformed_token() {
        let result = extract_user_id_from_token_str_with_fallback(
            "not.a.valid.jwt",
            "current_secret_1234567890123456789012",
            Some("old_secret_12345678901234567890123456"),
        );

        assert!(result.is_err());
        assert!(result
            .unwrap_err()
            .contains("Invalid token (primary+fallback)"));
    }

    #[test]
    fn test_extract_user_id_and_role_with_fallback_accepts_old_secret_token() {
        let current_secret = "current_secret_1234567890123456789012";
        let old_secret = "old_secret_12345678901234567890123456";
        let (token, _jti, _exp) =
            generate_access_token("legacy-admin", "admin", old_secret, 3600).unwrap();

        let extracted = extract_user_id_and_role_from_token_str_with_fallback(
            &token,
            current_secret,
            Some(old_secret),
        )
        .unwrap();

        assert_eq!(extracted.0, "legacy-admin");
        assert_eq!(extracted.1, "admin");
    }

    #[test]
    fn test_extract_user_id_from_header_with_fallback_accepts_old_secret_token() {
        let current_secret = "current_secret_1234567890123456789012";
        let old_secret = "old_secret_12345678901234567890123456";
        let (token, _jti, _exp) =
            generate_access_token("legacy-user", "user", old_secret, 3600).unwrap();

        let mut headers = HeaderMap::new();
        headers.insert(
            "Authorization",
            format!("Bearer {}", token).parse().unwrap(),
        );

        let extracted =
            extract_user_id_from_token_with_fallback(&headers, current_secret, Some(old_secret));

        assert!(extracted.is_ok());
        assert_eq!(extracted.unwrap(), "legacy-user");
    }

    #[test]
    fn test_extract_jti_with_fallback_preserves_legacy_missing_jti_error() {
        let current_secret = "current_secret_1234567890123456789012";
        let old_secret = "old_secret_12345678901234567890123456";
        let now = chrono::Utc::now().timestamp();
        let now = if now >= 0 { now as usize } else { 0usize };
        let expiration = now + 3600;

        let legacy_token = encode(
            &Header::default(),
            &LegacyClaims {
                sub: "legacy-user".to_string(),
                role: "user".to_string(),
                exp: expiration,
            },
            &EncodingKey::from_secret(old_secret.as_bytes()),
        )
        .unwrap();

        let jti = extract_jti_from_token_str_with_fallback(
            &legacy_token,
            current_secret,
            Some(old_secret),
        );
        assert!(jti.is_err());
        assert_eq!(jti.unwrap_err(), "Token missing jti");
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

            let result = rotate_refresh_token(
                &auth_repo,
                &user_repo,
                "revoked-refresh-token",
                "test_jwt_secret_at_least_32_characters_long",
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
            let old_hash = tokio::task::spawn_blocking(|| {
                let salt = SaltString::generate(&mut OsRng);
                Argon2::default()
                    .hash_password("current-pass-123".as_bytes(), &salt)
                    .map(|h| h.to_string())
            })
            .await
            .expect("hash task")
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

            let parsed_hash = PasswordHash::new(&updated_hash).expect("parse updated hash");
            Argon2::default()
                .verify_password("brand-new-pass-456".as_bytes(), &parsed_hash)
                .expect("new password verifies");
        })
        .await;
    }
}
