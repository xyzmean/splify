## 2026-07-23 - Adding ARIA attributes to interactive UI elements
**Learning:** The custom `Switch` component and some icon-only buttons lacked proper ARIA attributes, reducing screen reader accessibility. Internationalization requires adding keys explicitly to the dictionary when setting `aria-label` attributes using the `t` function.
**Action:** Ensure custom toggles have `role="switch"` and `aria-checked`, and always use `t()` with updated dictionary entries for `aria-label`s.
