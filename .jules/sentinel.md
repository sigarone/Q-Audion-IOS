## 2024-05-30 - Store user ID securely
**Vulnerability:** User ID and Device ID are stored in plaintext `UserDefaults`.
**Learning:** Based on memory constraints for `Q-Audion`, sensitive authentication credentials (like access tokens, refresh tokens, user IDs, and device IDs) must always be stored in the iOS Keychain and never in plaintext `UserDefaults`.
**Prevention:** Store user IDs and device IDs securely using TokenVault, which writes to the iOS Keychain, instead of `UserDefaults`.
