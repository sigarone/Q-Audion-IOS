## 2026-08-21 - [Sensitive Data in UserDefaults]
**Vulnerability:** `TusResumeStateStore` was storing sensitive info (like `recipientUserId` and `pskFingerprintHex`) in plaintext `UserDefaults`.
**Learning:** `UserDefaults` is unencrypted and its contents can be easily extracted from iOS devices. Any component that stores cryptographic metadata, user IDs, or peer IDs must use the Keychain instead, typically with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
**Prevention:** Avoid `UserDefaults` for anything containing account identifiers or key fingerprints. Always wrap such storage logic to use `SecItemAdd`/`SecItemCopyMatching`.
