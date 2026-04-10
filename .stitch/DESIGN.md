# Q-Audion Design System

## Brand Identity
- **Product**: Q-Audion — Post-Quantum Encrypted Voice & Video Calling
- **Tagline**: "Quantum-Safe Communication"
- **Mood**: Secure, premium, futuristic yet trustworthy
- **Platform**: iOS (iPhone), dark-first design

## Color Palette

| Role | Name | Hex | Usage |
|------|------|-----|-------|
| Primary | Quantum Blue | #0A84FF | CTAs, active states, links |
| Primary Gradient Start | Cyan | #00E5FF | Shield icon, accent gradients |
| Primary Gradient End | Deep Blue | #0A4FFF | Shield icon, accent gradients |
| Background | Void Black | #000000 | Main background |
| Surface | Carbon | #1C1C1E | Cards, form fields |
| Surface Elevated | Graphite | #2C2C2E | Modals, elevated cards |
| Secure/Genuine | Guardian Green | #30D158 | Confidence green, PQC label |
| Caution | Amber | #FFD60A | PSK badge, yellow alerts |
| Alert/Deepfake | Crimson | #FF3B30 | Red alerts, end call, deepfake |
| Cipher | Signal Orange | #FF9F0A | Cipher waveform, encrypted data |
| Text Primary | Pure White | #FFFFFF | Headings, labels |
| Text Secondary | Silver | #8E8E93 | Captions, descriptions |
| Text Tertiary | Ash | #636366 | Disabled, placeholders |

## Typography
- **Display**: SF Pro Rounded, 28pt, Bold (app title)
- **Title**: SF Pro, 22pt, Bold (screen titles)
- **Headline**: SF Pro, 17pt, Semibold (section headers)
- **Body**: SF Pro, 15pt, Regular (form labels)
- **Caption**: SF Pro, 13pt, Regular (descriptions)
- **Mono**: SF Mono, 11pt, Semibold (badge labels, waveform, technical data)

## Iconography
- **App Icon**: Shield with quantum wave motif, dark background, cyan→blue gradient
- **System**: SF Symbols throughout
- **Key Icons**:
  - shield.checkered — Main brand/security icon
  - lock.fill — Encryption active
  - waveform — Audio visualization
  - exclamationmark.triangle.fill — Deepfake alert
  - key.fill — PSK management
  - person.wave.2.fill — Voice auth
  - video.fill — Video call
  - mic.fill — Audio/mute

## Component Patterns
- **Cards**: `.ultraThinMaterial` with 12-16px corner radius
- **Badges**: Pill shape, 20px corner radius, frosted glass effect
- **Buttons**: 60pt circular for call controls, 50pt for video controls
- **Forms**: iOS native Form/Section style with `Surface` background
- **Toggles**: System green (#30D158) when enabled
- **Sliders**: Quantum Blue fill (#0A84FF)

## Animation
- **Security Badge expand**: Spring(response: 0.35, dampingFraction: 0.8)
- **Deepfake alert**: Pulse shadow + scale icon, easeInOut 0.7s repeat
- **Red dot glow**: Shadow pulse animation on .red confidence level
- **View transitions**: .move(edge:) + .opacity combined

## Screen Inventory
1. Login — Dark gradient, shield logo, form fields
2. Home — Tab view (Calls, Keys, Settings)
3. Audio Call — Security badge + waveform + controls
4. Video Call — Full screen + PiP + badge + 5 controls
5. Settings — 9 sections matching Android layout
6. Key Management — PSK list, QR/NFC exchange
