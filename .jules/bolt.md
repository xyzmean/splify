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

## 2024-05-14 - React Code Splitting for Tab Route Components
**Learning:** In a single-page app containing multiple discrete tools/tabs (like `StatusDashboard`, `WgPanel`, `ApiPanel`), importing all components synchronously bloats the initial bundle. For resource-constrained devices like routers (OpenWrt), reducing initial payload is a measurable win. Code-splitting using `React.lazy` on background tabs successfully breaks these chunks out (e.g. 10KB+ for WgPanel and ApiPanel each).
**Action:** Use `React.lazy` and `Suspense` for conditional sub-views (like tabs or heavy modals) that aren't visible on the initial render to lower the initial parse/execute time and main bundle size.
## 2024-08-06 - Stop Polling in Background Tabs
**Learning:** `useSplifyData` previously executed continuous 1-second UBUS RPC polling via `pullLive` even when users switched away from the "Status" tab to "AmneziaWG" or "Remote control". In a low-power OpenWrt router environment, this wastes scarce CPU/RAM resources on invisible data, leading to unnecessary React re-renders and network traffic.
**Action:** Always pause data-fetching polling loops when the component displaying the data is not actively visible. Added an `active` boolean flag to `useSplifyData` that early-returns out of the `useEffect` timer if false.
