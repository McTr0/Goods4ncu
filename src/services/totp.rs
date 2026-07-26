//! RFC 6238 TOTP for platform-admin MFA.
//!
//! Implemented directly on the `hmac`/`sha1` crates already in the tree rather
//! than pulling a TOTP dependency: the algorithm is ~40 lines, and every added
//! dependency is supply-chain surface on the authentication path — the one
//! place where that trade-off clearly favours vendoring. Correctness is pinned
//! by the RFC 4226 Appendix D and RFC 6238 Appendix B test vectors below.
//!
//! SHA-1 is the parameter set every authenticator app supports; HMAC-SHA1's
//! known weaknesses (collision attacks) do not apply to HMAC usage here.

use hmac::{Hmac, Mac};
use sha1::Sha1;

/// TOTP time step in seconds (RFC 6238 default, used by all major apps).
pub const STEP_SECS: i64 = 30;
/// Verification accepts the current step ±1 to absorb clock skew.
const SKEW_STEPS: i64 = 1;
/// 6-digit codes — the default that authenticator apps display.
const DIGITS: u32 = 6;

const BASE32_ALPHABET: &[u8; 32] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

/// Generate a new 160-bit secret, base32-encoded for authenticator apps.
pub fn generate_secret() -> String {
    use rand::Rng;
    let mut bytes = [0u8; 20];
    rand::rng().fill_bytes(&mut bytes);
    base32_encode(&bytes)
}

/// otpauth:// URI for QR-code enrollment in authenticator apps.
pub fn provisioning_uri(secret_base32: &str, account: &str, issuer: &str) -> String {
    // Minimal percent-encoding for the label parts we control.
    fn enc(s: &str) -> String {
        s.bytes()
            .flat_map(|b| match b {
                b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                    vec![b as char]
                }
                _ => format!("%{:02X}", b).chars().collect(),
            })
            .collect()
    }
    format!(
        "otpauth://totp/{}:{}?secret={}&issuer={}&algorithm=SHA1&digits={}&period={}",
        enc(issuer),
        enc(account),
        secret_base32,
        enc(issuer),
        DIGITS,
        STEP_SECS
    )
}

pub fn base32_encode(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len().div_ceil(5) * 8);
    for chunk in bytes.chunks(5) {
        let mut buf = [0u8; 5];
        buf[..chunk.len()].copy_from_slice(chunk);
        let n = u64::from(buf[0]) << 32
            | u64::from(buf[1]) << 24
            | u64::from(buf[2]) << 16
            | u64::from(buf[3]) << 8
            | u64::from(buf[4]);
        let quantums = [
            (n >> 35) & 31,
            (n >> 30) & 31,
            (n >> 25) & 31,
            (n >> 20) & 31,
            (n >> 15) & 31,
            (n >> 10) & 31,
            (n >> 5) & 31,
            n & 31,
        ];
        // RFC 4648: emit only the quantums covered by input bits; no padding —
        // authenticator apps accept unpadded secrets.
        let emit = match chunk.len() {
            1 => 2,
            2 => 4,
            3 => 5,
            4 => 7,
            _ => 8,
        };
        for &q in quantums.iter().take(emit) {
            out.push(BASE32_ALPHABET[q as usize] as char);
        }
    }
    out
}

pub fn base32_decode(input: &str) -> Option<Vec<u8>> {
    let mut bits: u64 = 0;
    let mut bit_count = 0;
    let mut out = Vec::with_capacity(input.len() * 5 / 8);
    for c in input.trim_end_matches('=').bytes() {
        let val = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a',
            b'2'..=b'7' => c - b'2' + 26,
            _ => return None,
        };
        bits = (bits << 5) | u64::from(val);
        bit_count += 5;
        if bit_count >= 8 {
            bit_count -= 8;
            out.push((bits >> bit_count) as u8);
        }
    }
    Some(out)
}

/// RFC 4226 HOTP value for one counter.
fn hotp(secret: &[u8], counter: u64) -> u32 {
    let mut mac = Hmac::<Sha1>::new_from_slice(secret).expect("HMAC accepts keys of any length");
    mac.update(&counter.to_be_bytes());
    let digest = mac.finalize().into_bytes();
    let offset = (digest[19] & 0x0f) as usize;
    let code = u32::from(digest[offset] & 0x7f) << 24
        | u32::from(digest[offset + 1]) << 16
        | u32::from(digest[offset + 2]) << 8
        | u32::from(digest[offset + 3]);
    code % 10u32.pow(DIGITS)
}

/// The TOTP code for a given secret and unix time — used by enrollment tests
/// and by clients of this module that need to display the expected format.
#[allow(dead_code)] // used from the lib crate by integration tests; the bin target never calls it
pub fn code_at(secret_base32: &str, unix_time: i64) -> Option<String> {
    let secret = base32_decode(secret_base32)?;
    let step = unix_time / STEP_SECS;
    Some(format!("{:06}", hotp(&secret, step as u64)))
}

/// Verify a submitted code at `unix_time`.
///
/// Returns the matched time step on success so the caller can persist it as a
/// high-water mark — accepting only codes with `step > last_used_step` makes
/// every code single-use, closing the shoulder-surf/replay window that a
/// stateless check would leave open for the rest of the 30s period.
pub fn verify(
    secret_base32: &str,
    submitted: &str,
    unix_time: i64,
    last_used_step: i64,
) -> Option<i64> {
    if submitted.len() != DIGITS as usize || !submitted.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let secret = base32_decode(secret_base32)?;
    let current = unix_time / STEP_SECS;
    for offset in -SKEW_STEPS..=SKEW_STEPS {
        let step = current + offset;
        if step <= last_used_step || step < 0 {
            continue;
        }
        let expected = format!("{:06}", hotp(&secret, step as u64));
        // Constant-time comparison: don't leak digit positions via timing.
        let mut diff = 0u8;
        for (a, b) in expected.bytes().zip(submitted.bytes()) {
            diff |= a ^ b;
        }
        if diff == 0 {
            return Some(step);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    // RFC 4226 Appendix D secret: "12345678901234567890"
    const RFC_SECRET: &[u8] = b"12345678901234567890";

    #[test]
    fn hotp_matches_rfc4226_appendix_d_vectors() {
        let expected = [
            755224, 287082, 359152, 969429, 338314, 254676, 287922, 162583, 399871, 520489,
        ];
        for (counter, want) in expected.iter().enumerate() {
            assert_eq!(hotp(RFC_SECRET, counter as u64), *want, "counter {counter}");
        }
    }

    #[test]
    fn totp_matches_rfc6238_appendix_b_sha1_vectors() {
        let secret_b32 = base32_encode(RFC_SECRET);
        let cases = [
            (59, "94287082"),
            (1111111109, "07081804"),
            (1234567890, "89005924"),
            (2000000000, "69279037"),
        ];
        for (t, code8) in cases {
            // RFC vectors are 8-digit; ours are 6 — compare the low 6 digits,
            // which is the same HOTP value modulo 10^6.
            let got = code_at(&secret_b32, t).unwrap();
            assert_eq!(got, &code8[2..], "t={t}");
        }
    }

    #[test]
    fn base32_roundtrip_various_lengths() {
        for len in 0..=20 {
            let bytes: Vec<u8> = (0..len as u8).map(|b| b.wrapping_mul(37)).collect();
            let encoded = base32_encode(&bytes);
            assert_eq!(base32_decode(&encoded).unwrap(), bytes, "len {len}");
        }
    }

    #[test]
    fn verify_accepts_current_and_adjacent_steps_only() {
        let secret = base32_encode(RFC_SECRET);
        let now = 1_600_000_000;
        let code = code_at(&secret, now).unwrap();
        assert!(verify(&secret, &code, now, 0).is_some(), "current step");
        assert!(
            verify(&secret, &code, now + STEP_SECS, 0).is_some(),
            "one step of clock skew"
        );
        assert!(
            verify(&secret, &code, now + 3 * STEP_SECS, 0).is_none(),
            "codes expire after the skew window"
        );
    }

    #[test]
    fn verify_rejects_replay_of_consumed_step() {
        let secret = base32_encode(RFC_SECRET);
        let now = 1_600_000_000;
        let code = code_at(&secret, now).unwrap();
        let step = verify(&secret, &code, now, 0).expect("first use succeeds");
        assert!(
            verify(&secret, &code, now, step).is_none(),
            "the same code must not be accepted twice"
        );
    }

    #[test]
    fn verify_rejects_malformed_codes() {
        let secret = base32_encode(RFC_SECRET);
        for bad in ["", "12345", "1234567", "12345a", "12 456"] {
            assert!(verify(&secret, bad, 1_600_000_000, 0).is_none(), "{bad:?}");
        }
    }

    #[test]
    fn generated_secrets_are_unique_and_decodable() {
        let a = generate_secret();
        let b = generate_secret();
        assert_ne!(a, b);
        assert_eq!(base32_decode(&a).unwrap().len(), 20);
    }

    #[test]
    fn provisioning_uri_contains_required_fields() {
        let uri = provisioning_uri("ABC234", "admin@校园", "Goods4ncu");
        assert!(uri.starts_with("otpauth://totp/Goods4ncu:admin%40"));
        assert!(uri.contains("secret=ABC234"));
        assert!(uri.contains("issuer=Goods4ncu"));
        assert!(uri.contains("period=30"));
    }
}
