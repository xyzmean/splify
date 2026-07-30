## 2024-05-24 - [React Render Optimization in StatusDashboard]
**Learning:** Wrapping heavy derived state logic, particularly when calculating metrics that mutate external refs (`ratesFor` with `ratesRef`), inside a `useMemo` block prevents rate dropouts to `0` when UI interacts (which caused unnecessary re-renders).
**Action:** Use `useMemo` carefully to avoid ref mutation bugs on intermediate re-renders.

## 2024-05-14 - Initial Exploration
**Learning:** Evaluated the frontend React application for performance bottlenecks. The `StatusDashboard` component performs significant data processing (rates calculations, filtering endpoints, filtering lists) on every render, but these renders are tied to manual refreshes or API actions. Found `RatesRef` correctly used for stable rate tracking. The `SettingsPage` heavily relies on large object/array cloning (`endpoints.map`, `devices.map`) during user input which could be optimised slightly but it's bound by user typing speed, not a render loop.
**Action:** Let's look closely at `App.tsx` and `StatusDashboard.tsx`. In `StatusDashboard.tsx`, there are repeated array scans on `eps` (endpoints). `eps.forEach`, `eps.reduce`, `eps.find`, `eps.filter`. In a large deployment with many endpoints, this is O(n) multiple times.
**Learning:** `useMemo` is not used in any components. In `StatusDashboard.tsx`, on every render, it recalculates `totRx`, `totTx`, `onlineTun`, `enabledLists`, `okLists`, `activeEp`, `rates`, `checks`, etc. While the number of endpoints/lists is small, this is a prime candidate for `useMemo` to prevent recalculations on every render, especially when the `busy` state changes (which triggers re-renders because `StatusDashboard` takes `busy` as a prop and re-renders when a button is clicked and `busy` changes to `true` or `false`).
**Action:** Implement `useMemo` in `StatusDashboard.tsx` for these derived values to optimize rendering performance when `busy` state changes.

## 2024-05-14 - Optimize StatusDashboard computations
**Learning:** React re-evaluates heavy array iterations if they are not properly memoized. The `useMemo` dependency array must include all outer scope variables, and using an internal early return within the component, if checked *before* a hook, violates the Rules of Hooks. Hooks must be declared before any early returns.
**Action:** Always place `useMemo` hooks before conditional early returns. Handle the null states inside the `useMemo` calculation instead. Use the computed properties to avoid redundant subset operations (e.g., using `enabledLists` to compute `okLists` rather than filtering the original `lists` again).

## 2024-08-01 - [StatusDashboard Re-render Optimization]
**Learning:** React re-evaluates heavy array iterations and large list components (`events.map`, `checks.map`) when the parent component's non-data state (like `busy` spinners) changes.
**Action:** Extract list-rendering sections into separate components wrapped in `React.memo` to shield them from parent UI state changes, and ensure derived filtering (like `checks`) is wrapped inside `useMemo` hooks.
