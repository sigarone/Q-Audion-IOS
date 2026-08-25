## 2026-08-22 - Token Leakage via Swift Struct Default Reflection
**Vulnerability:** The authentication credential structs (`OtpAuthResult`, `AuthCredentials`, and `AuthTokenPair`) implicitly relied on Swift's default reflection when logged or printed, which exposed sensitive fields (`accessToken`, `refreshToken`) in plaintext logs.
**Learning:** In Swift, logging structs directly with `print()` or similar functions will enumerate and output all their stored properties if they don't explicitly override it. This creates a critical risk of leaking tokens or passwords into logs, analytics, or debugging tools.
**Prevention:** Always explicitly implement `CustomStringConvertible` and `CustomDebugStringConvertible` for any struct or class containing credentials, tokens, or sensitive user data, specifically redacting those fields (e.g., returning `"<redacted>"`).

## 2026-08-23 - Token Leakage via Swift Struct Default Reflection in Device Renew Client
**Vulnerability:** Similar to previous token leakage, `BCryptoDeviceRenewClient.RenewedTokens` and `BCryptoDeviceRenewClient.RenewResp` did not override default reflection, risking exposure of `accessToken` and `refreshToken` in logs.
**Learning:** Same as above - inner private structs or specific client structs must also be considered for redaction if they contain sensitive data.
**Prevention:** Ensured `CustomStringConvertible` and `CustomDebugStringConvertible` implementations were added to redact sensitive fields within `DeviceRenewClient`.

## 2026-08-24 - PII Leakage via Swift Struct Default Reflection in Profile Structs
**Vulnerability:** The profile structs `UserProfile` and `PublicUser` did not override default reflection, risking exposure of sensitive PII (`phoneHash` and `phoneNumber`) in logs.
**Learning:** Default reflection in Swift struct descriptions can leak sensitive PII just as it can leak authentication tokens. Any struct containing potentially identifying or sensitive data must explicitly handle its string representation.
**Prevention:** Ensured `CustomStringConvertible` and `CustomDebugStringConvertible` implementations were added to redact `phoneHash` and `phoneNumber` within profile-related structs in `AccountApi.swift`.

## 2026-08-25 - Local Storage Encryption Gap for Group Data
**Vulnerability:** Group metadata (`GroupRegistry`) and tombstoned groups (`GroupTombstoneStore`) were stored as plaintext JSON blobs in `UserDefaults`, risking exposure of user associations and group history via physical device extraction or unencrypted backups.
**Learning:** Even seemingly benign metadata like group membership and delete history can expose a user's social graph. Every persistent local store in a secure messaging app must be encrypted at rest, matching the protection level of the 1:1 conversation store and contact list.
**Prevention:** Ensured all JSON blob storage backed by `UserDefaults` utilizes `LocalStoreCipher` for AES-256-GCM encryption, wrapping the data before saving and gracefully migrating legacy plaintext on load.
