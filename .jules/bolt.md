## 2024-05-24 - [React Render Optimization in StatusDashboard]
**Learning:** Wrapping heavy derived state logic, particularly when calculating metrics that mutate external refs (`ratesFor` with `ratesRef`), inside a `useMemo` block prevents rate dropouts to `0` when UI interacts (which caused unnecessary re-renders).
**Action:** Use `useMemo` carefully to avoid ref mutation bugs on intermediate re-renders.
