# Nested split panes — implementation plan

## Goal

Let the ⌘D split nest: any visible pane (agent side or an already-split
terminal) can be split again, in either direction, with no artificial depth
cap. One tab, a tree of sibling herdr panes — the herdr TUI and herdrm keep
rendering the same structure, as established by the single-split work
(`feat(split)` on `main`: `pane.split` + ephemeral `pane.close` + pane-ID
concealment).

## Non-goals

- Mirroring server-initiated layouts. herdrm owns the tree; splits made in
  the herdr TUI are out of scope (they render as ordinary panes today and
  keep doing so).
- Drag-reorder of panes, pane zoom, persisted multi-pane layouts. The tree
  is session state, rebuilt by hand each time like today.
- iOS (`HerdrMobile`). macOS only, same as the current split.
- Same-direction re-split of an already-split cell (see §4): columns beyond
  two are built by splitting siblings, which covers realistic tiling; the
  residual gap is accepted MVP scope, not an oversight.

## Current state (what must change)

All in `Sources/HerdrM` (`AppModel.swift`, `ContentView.swift`,
`HerdrMApp.swift`, `TerminalView.swift`, `SplitContainer.swift`):

- `shellSplitAxis: SplitAxis?` + `splitTerminal: SplitTerminal?` model exactly
  one split. `SplitSide` is `.agent` / `.shell` — two cases, no room for a
  third pane.
- `SplitContainer<First, Second>` renders two fixed children; the agent side
  is the kept-alive attach stack, the shell side one attach. The root
  container is *always present* (`axis: nil` with no split) precisely so the
  nil→split transition never moves the agent attach — identity survives an
  `AnyLayout` axis flip, not a branch swap (`SplitContainer.swift:8-13`).
- `SplitFocusTracker` reports `.agent` / `.shell` via two closures
  (`isAgentView`, `shellView`). Menu commands assume two panes: 8 fixed
  focus items (per-axis), 4 resize items, ⌘W closes the whole split first.
- `openSplit(axis:)` splits the *selected entry's* pane; `closeSplitTerminal`
  closes *the* pane. Concealment (`concealedSplitPaneIDs` + `isSplitPane`)
  is pane-ID based but single-pane: the persistent half matches only
  `splitTerminal`, and set keys expire at each open-cycle end.

## Design

### 1. Tree model (`AppModel.swift`)

```swift
/// A leaf is either the agent side (virtual: renders the selected attach
/// stack, owns no server pane) or one split terminal (owns its pane).
enum SplitLeaf: Equatable {
    case agent
    case terminal(SplitPane)  // today's SplitTerminal, renamed
}

/// Stable identity for focus, tasks, and concealment. Agent marker vs
/// device-scoped pane ID (pane IDs can collide across devices — same key
/// shape as the conceal set).
enum SplitLeafID: Hashable {
    case agent
    case pane(deviceID: UUID, paneID: String)
}

indirect enum SplitNode: Equatable {
    case leaf(SplitLeaf)
    case split(axis: SplitAxis, ratio: Double, first: SplitNode, second: SplitNode)
}

@Published var splitTree: SplitNode?  // nil == no split
@Published var focusedSplitLeaf: SplitLeafID  // default .agent
```

- `splitRatio` persistence stays root-only (today's `terminal.splitRatio`
  key); deeper nodes keep in-memory ratios. The root split is the 99% case,
  and ephemeral panes have no stable cross-session identity.
- `isSplitPane` is rewritten to walk the tree's terminal leaves (plus the
  transient creation set, unchanged). Single-`splitTerminal` matching goes
  away. This covers sidebar, drag targets, auto-selection fallback,
  placeholder counts, ⌘K search, *and* snapshot focus auto-selection —
  every consumer reads the same predicate, so no new bypass can open.
- `openSplit(axis:)` targets the *focused leaf's* herdr pane (agent leaf →
  selected entry's pane; terminal leaf → its pane, resolved via
  `terminalEntries(for:)` for cwd) and replaces that leaf with
  `split(axis, ratio: 0.5, first: <old leaf>, second: <new terminal>)`.
  The new pane always goes second (right/bottom), matching today.
- Mid-flight guards, adapted per leaf (not reused verbatim):
  - In-flight tasks are keyed per leaf
    (`splitOpenTasks: [SplitLeafID: Task<Void, Never>]`): repeat ⌘D on a
    leaf hits its own dedup slot, and closing leaf A never cancels leaf
    B's in-flight open. The guarded-defer nil-out discipline from the
    single-split work applies per slot.
  - The post-split check changes invariant from "selected entry unchanged"
    to "focused leaf still wanted": splitting the agent leaf still requires
    `selectedAttachedEntry?.id == entryID` (it needs the selected pane to
    split); splitting a terminal leaf requires the tree to still contain
    that pane (selection may legitimately have moved — focus and selection
    diverge by design here). Either failure closes the created pane,
    refreshes, and (only when the tab never appeared) surfaces
    `actionError`, as today.
  - Conceal-before-publish, bounded refresh retry, and cancel paths behave
    per creation exactly as today.
- Closing (`closeSplitLeaf(_:)`): closes *every* terminal descendant
  post-order (each `pane.close` + per-leaf conceal discipline — collapsing
  must never strand server panes), then collapses the parent
  (`split → surviving sibling`). Closing the agent leaf collapses the whole
  tree (`splitTree = nil`), preserving today's "⌘W on agent closes the
  split" feel. All mutations go through `updateSplitTree(_:)` so the
  close-pane side effect can't be bypassed (replaces the axis-didSet funnel).
- Focus restoration: closing an inner leaf sets `focusedSplitLeaf` to the
  surviving sibling. The view layer resolves leaf IDs to views through a
  weak `SplitLeafViewRegistry` (populated in `onViewReady`, parallel to
  `AttachViewRegistry`); dimming stays compositional from the tree and
  needs no registry.
- The close-path reuse guard compares against tree membership (pane ID
  still in tree), not a single stored pane.

### 2. Recursive rendering (`ContentView.swift`, `SplitContainer.swift`)

Core identity rule (generalizes the root trick — a recursive case switch
between *different view types* would itself reset identity and relaunch
attaches, so the recursion must not work that way):

- Every pane owns a `LeafCell` that **permanently** renders one
  `SplitContainer`: the pane's own attach lives in `first()` forever
  (agent cell: the kept-alive attach stack, verbatim as today; terminal
  cell: its `AttachTerminalView` keyed by pane ID), and splitting flips
  that cell's `axis` nil→value while mounting the new subtree in
  `second()` (empty when unsplit — `SplitContainer` already skips
  divider+second on nil axis). Axis flips go through the existing
  `AnyLayout` mechanism, exactly like today's nil→split transition.
- Consequence: an attach never changes structural position, at any depth.
  Splits only ever *add* a `second()` sibling and flip one axis. No
  conditional branch swaps around live attaches, at any level.
- New `SplitTreeView` maps the model tree to nested `LeafCell`s 1:1.
  `SplitContainer` itself is untouched. Focus dimming: the focused leaf
  renders full opacity, all others dimmed (today's `inactivePaneOpacity`).

### 3. Focus tracking (`TerminalView.swift`)

- `SplitFocusTracker` reports a `SplitLeafID` instead of a side: replace
  `isAgentView`/`shellView` with a single `(NSView) -> SplitLeafID?`
  resolver supplied by the view layer (attach-registry hit → `.agent`;
  otherwise walk up to the nearest pane container view carrying its leaf
  ID). No side enum, no per-side stored refs, same no-cache discipline
  (reports every change, never dedupes).
- `SplitSide`/`activeSplitSide` are removed; where a two-way name is still
  needed during migration, prefer first/second-neutral spelling — the old
  `.agent`/`.shell` cases become actively misleading at nested levels.

### 4. Menu commands (`HerdrMApp.swift`)

- Split Vertically / Horizontally (⌘D / ⇧⌘D) operate on the *focused pane's
  cell*: unsplit cell → split it in the pressed direction (nest); cell
  already split with a *different* axis → re-aim it (flip — attach-safe,
  and exactly today's depth-1 repeat behavior); cell already split with
  the *same* axis → no-op. Rationale: same-direction re-split of the
  focused pane would have to move its live attach down a level (identity
  break, §2), so it is deliberately unavailable; further columns are built
  by splitting siblings. Enabled whenever a tree or a selected entry exists.
- Focus arrows (⌘⌥ arrows): move keyboard focus to the *neighbor leaf* in
  that direction, computed from tree geometry. Always enabled while a tree
  exists; the 8-item per-axis workaround goes away — items no longer encode
  the axis, so the stale-shortcut class it worked around can't recur.
- Resize (⌘⌃ arrows): grow/shrink the focused leaf's parent divider.
  Same enablement as focus.
- ⌘W: close the focused leaf (terminal → close pane + collapse + focus the
  surviving sibling; agent → collapse whole tree). With no tree, falls
  through to today's split → shell → window chain.
- Disabled-state staleness (the ⌘D lesson) is a hard rule, restated: no
  command may rely on `.disabled()` revalidation for shortcut-path
  correctness — actions no-op safely on unexpected focus, same guard style
  as `focusSplitSide`/`resizeSplit` today.

### 5. Server mapping

- Every terminal leaf is a `pane.split` child of whatever leaf was focused
  at creation (agent pane or another split terminal). `pane.close` on a
  child un-splits; siblings (agent pane included) are untouched — the
  verified semantics of the existing single split.
- No new RPCs. `focus: false` on creation everywhere, as today.
- Divider ratios stay local (not propagated to the server). The two views
  agree on structure, not proportions — same position as the current
  split; full ratio sync is a separate, explicitly deferred decision.

## Migration steps

1. `AppModel`: add `SplitLeaf`/`SplitLeafID`/`SplitNode` + tree helpers
   (`updateSplitTree`, `closeSplitLeaf`, per-leaf tasks, tree-walking
   `isSplitPane`, leaf registry); reimplement `openSplit`/close paths on
   the tree for the depth-1 case. Keep `shellSplitAxis`/`splitTerminal` as
   computed shims during migration, remove at the end.
2. `LeafCell` + `SplitTreeView` in `DetailView`; depth-1 tree must render
   pixel-identical to today before proceeding — *including* attach
   survival (no `--takeover` relaunch, scrollback intact, no focus steal;
   verify via herdr-side: sibling attaches undisturbed).
3. Focus tracker → leaf IDs (+ registry); menu rewritten
   (split/focus/resize/⌘W) with the §4 repeat semantics.
4. Depth-N enablement: split-focused-leaf path, collapse-all-descendants,
   focus restoration; 3-pane manual test including mixed directions.
5. Delete shims (`shellSplitAxis`, `splitTerminal`, `SplitSide`,
   `activeSplitSide`); full build + manual pass; squash.

Each step keeps `make build` green and depth-1 behavior unchanged, so the
work can land incrementally if preferred.

## Test plan (manual; no harness exists for AppKit focus paths)

- [ ] Depth 1 unchanged: ⌘D/⇧⌘D, ⌘W, focus arrows, resize, takeover,
      sidebar invisibility — same as today. Sibling attaches provably
      undisturbed (no relaunch, scrollback intact).
- [ ] Split a split terminal (⌘D with focus right): three panes, herdr TUI
      shows the nested layout; closing the middle pane collapses correctly
      and focuses the survivor.
- [ ] Mixed directions (vertical split inside a horizontal one and reverse).
- [ ] ⌘W on each pane closes that pane (+focuses survivor); ⌘W on the agent
      collapses all and closes every descendant pane server-side.
- [ ] Repeat-press semantics: ⌘D on unsplit cell nests; opposite direction
      re-aims; same direction on split cell no-ops.
- [ ] Rapid ⌘D⌘D / close-mid-open (including across two leaves): no orphaned
      server panes (`herdr pane list` before/after).
- [ ] Remote device: all of the above against an SSH device.

## Risks

- Focus-tracking generalization is the fiddliest part (KVO on
  firstResponder + view-walk per change + new leaf registry); the current
  two-side tracker was already subtle. Mitigation: leaf-ID resolution is a
  pure function of the view hierarchy, covered by the same manual pass.
- Menu shortcut staleness (the ⌘D lesson) recurs if new commands gate on
  `.disabled()` — noted as a hard rule in §4.
- The per-pane-cell identity strategy (§2) is load-bearing for the whole
  refactor: any deviation (moving an attach between structural positions)
  relaunches processes. When in doubt, re-read `SplitContainer.swift:8-13`.
- Scope creep into ratio sync / server-layout mirroring / same-direction
  re-split — explicitly out; structure-only agreement is the contract.
