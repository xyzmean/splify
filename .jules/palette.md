## 2026-07-23 - Missing ARIA Labels on Icon-Only Buttons and Custom Switches
**Learning:** Found that custom React `Switch` components and icon-only buttons often lack accessible names. Specifically, the local `Switch` component in `ApiPanel.tsx` didn't accept an `aria-label` prop, unlike the one in `SettingsPage.tsx`. This pattern means screen reader users don't know what these controls toggle.
**Action:** When inspecting interfaces, always look out for custom wrapper components (like `Switch` or `Button`) that are used solely with icons or visual state indicators. Verify they both accept and provide `aria-label` (or similar) attributes to ensure accessibility.
## 2026-07-23 - Adding aria-checked and role='switch' to toggle components
**Learning:** Adding `aria-label` alone to a custom `Switch` element is insufficient if it is built on a standard `<button>` tag. Screen reader users will hear the name but won't know the state (on/off) of the toggle.
**Action:** When creating or fixing custom switch/toggle components, always add `role="switch"` and `aria-checked={on}` so that state changes are announced properly.
