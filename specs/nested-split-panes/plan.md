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

## Load-bearing server behavior (verified live against the socket)

- **Any attach-client disconnect reaps the bare terminal pane.** Killing the
  `herdr terminal attach` client with SIGHUP (what `host.terminate()` sends)
  *and* with SIGKILL both delete the server pane — there is no graceful vs
  abrupt distinction. Consequence: **a live pane's view must never unmount**,
  on split *or* collapse, at any depth. Every dismantle is a kill. This
  single fact rules out all rendering strategies that move or rebuild live
  attaches (including naive recursive containers and first-child-collapse
  promotion), and it is the reason §2 below mounts every attach exactly
  once and only ever changes frames.
- **Scrollback is retained server-side and re-synced on attach** (verified:
  `pane read --source recent` returns full history; a fresh attach draws a
  full screen including history lines). This matters for the surviving
  re-attach paths (takeover recovery, reconnect overlay): visible content is
  preserved; only lines older than the resync window can drop.

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
  away. Every consumer — sidebar, drag targets, auto-selection fallback,
  placeholder counts, ⌘K search, snapshot focus auto-selection — reads the
  same predicate, so no bypass can open.
- `openSplit(axis:)` targets the *focused leaf's* herdr pane (agent leaf →
  selected entry's pane; terminal leaf → its pane, resolved via
  `terminalEntries(for:)` for cwd) and replaces that leaf with
  `split(axis, ratio: 0.5, first: <old leaf>, second: <new terminal>)`.
  The new pane always goes second (right/bottom), matching today.
- Same-device guard: a tree lives in exactly one tab on one device. When a
  tree exists and the focused leaf is `.agent`, splitting requires
  `selectedAttachedEntry` to be on the tree's device (the device of any
  terminal leaf — resolved by walking the tree); otherwise the command
  no-ops. Without this, switching devices with a tree open and pressing ⌘D
  would nest a foreign device's pane into the tree, breaking structure
  agreement and closing panes across devices on collapse. (Terminal-leaf
  splits always use the pane's own device and cannot cross.)
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
  must never strand server panes), then prunes the subtree. Closing the
  agent leaf collapses the whole tree (`splitTree = nil`), preserving
  today's "⌘W on agent closes the split" feel. All mutations go through
  `updateSplitTree(_:)` so the close-pane side effect can't be bypassed
  (replaces the axis-didSet funnel).
- Focus restoration: closing a leaf sets `focusedSplitLeaf` to the nearest
  surviving leaf and performs an explicit `makeFirstResponder` on its view
  resolved through the registry (today's analogue is
  `focusRemainingTerminal`; there is no remount to self-focus, by design).
- The close-path reuse guard compares against tree membership (pane ID
  still in tree), not a single stored pane.

### 2. Rendering: flat pool + tree-driven geometry (NOT nested containers)

A naive recursion (each split node a `SplitContainer` holding child views)
fails the load-bearing invariant: collapsing a first-child leaf promotes
the survivor's cell one level up, remounting its attach — and remounting
kills the pane (§0). Nesting by moving views is equally fatal on the split
path. So the tree never owns views:

- **Pool**: every split attach is mounted exactly once in a flat
  `ForEach(liveSplitPanes, id: \.paneID)` pool (the kept-alive
  `attachSessions` pattern generalized), plus the agent stack mounted once
  as today. Each pooled terminal reuses the `attachChild` rendering
  treatment verbatim (solid backdrop inside the opacity compositing group
  for Ghostty glyph AA, padding, clipping to its rect) — or the depth-1
  "pixel-identical" gate will fail on rendering artifacts, not geometry.
  Pool membership ⟺ pane lifetime: views are added on open and
  removed only with their pane's close/death. **A live pane's view is never
  removed, moved, or rebuilt — on split, collapse, or resize, at any
  depth.** This is the whole identity strategy, and it has no exceptions.
- **Geometry**: a pure function `layout(tree, size) -> [SplitLeafID: CGRect]`
  partitions the container rect recursively (axis + ratio per node). Each
  pooled view is positioned by its leaf's rect (`.frame` + `.position`) and
  dimmed unless focused. The function is UI-framework-free and unit-testable.
- **Dividers**: an overlay layer renders one draggable divider per split
  node from the same layout pass (drag math reused from `SplitContainer`;
  writes go through `updateSplitTree`). `SplitContainer` is retired once
  the canvas lands (verify no other consumers first) — a two-child generic
  cannot express N-pane geometry, and keeping it alongside invites mixing
  the two strategies.
- Because geometry (not structure) carries nesting, same-direction re-split
  of the focused pane is safe: the focused attach keeps its pool position
  and only shrinks, the new pane mounts fresh — and, crucially, the new
  pane's `makeNSView` auto-focuses it (inherited machinery, as today), so
  focusedSplitLeaf follows focus onto the new leaf and repeated ⌘D drills
  deeper instead of piling onto one cell (the rapid-⌘D test depends on this
  handoff). No MVP limitation remains — any binary guillotine layout is
  reachable.
- Focus dimming generalizes today's `inactivePaneOpacity`: focused leaf
  full opacity, all others dimmed.

### 3. Focus tracking (`TerminalView.swift`)

- `SplitFocusTracker` reports a `SplitLeafID` through a single
  `(NSView) -> SplitLeafID?` resolver consuming the `SplitLeafViewRegistry`
  (reverse lookup: is the responder or an ancestor a registered leaf view?)
  — one source of truth for leaf→view. Exception: the agent side keeps the
  `AttachViewRegistry.liveViews` check (a leaf registry keyed ID→view fits
  terminal leaves with one view each, not `.agent` with its
  selection-dependent stack — the staleness warning at
  `SplitContainer.swift:96-101` still applies). No side enum, no per-side
  stored refs, same no-cache discipline (reports every change, never
  dedupes).
- `SplitSide`/`activeSplitSide` are removed; where a two-way name is still
  needed during migration, prefer first/second-neutral spelling.
- `SplitLeafViewRegistry`: weak ID→view map populated in `onViewReady`,
  parallel to `AttachViewRegistry`. Serves focus moves, focus restoration,
  and the tracker resolver.

### 4. Menu commands (`HerdrMApp.swift`)

- Split Vertically / Horizontally (⌘D / ⇧⌘D): **always nest under the
  focused pane** in the pressed direction. Uniform rule, no special cases:
  with the pool strategy every nesting is identity-safe. Split orientation
  is fixed at creation — there is no re-aim (by shortcut or otherwise): to
  change orientation, close the split pane and re-split (cheap, because
  panes are ephemeral). This intentionally replaces today's depth-1 repeat
  behavior, where the opposite-direction press flipped the axis.
- Focus arrows (⌘⌥ arrows): move keyboard focus to the *neighbor leaf* in
  that direction, computed from tree geometry. Always enabled while a tree
  exists; the 8-item per-axis workaround goes away — items no longer encode
  the axis, so the stale-shortcut class it worked around can't recur.
- Resize (⌘⌃ arrows): grow/shrink the focused leaf's parent divider.
  Same enablement as focus.
- ⌘W: close the focused leaf (terminal → close pane + prune + focus nearest
  survivor; agent → collapse whole tree). With no tree, falls through to
  today's split → shell → window chain.
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
  agree on split structure, unconditionally. Full ratio/direction sync is
  a separate, explicitly deferred decision.

## Migration steps

1. `AppModel`: add `SplitLeaf`/`SplitLeafID`/`SplitNode` + tree helpers
   (`updateSplitTree`, `closeSplitLeaf`, per-leaf tasks, tree-walking
   `isSplitPane`, leaf registry); reimplement `openSplit`/close paths on
   the tree for the depth-1 case. Keep `shellSplitAxis`/`splitTerminal` as
   computed shims during migration, remove at the end.
2. `SplitCanvasView` (pool + `layout()` + divider overlay) in `DetailView`;
   depth-1 tree must render pixel-identical to today before proceeding —
   *including* attach survival (no process kill, no `--takeover` relaunch,
   scrollback intact, no focus steal; verify herdr-side that sibling shells
   keep running).
3. Focus tracker → leaf IDs (+ registry); menu rewritten
   (split/focus/resize/⌘W) with the §4 always-nest semantics.
4. Depth-N enablement: split-focused-leaf path, prune-with-descendant-close,
   focus restoration; 3-pane manual test including mixed directions.
5. Delete shims (`shellSplitAxis`, `splitTerminal`, `SplitSide`,
   `activeSplitSide`) and retire `SplitContainer` if unused; full build +
   manual pass; squash.

Each step keeps `make build` green and depth-1 behavior unchanged, so the
work can land incrementally if preferred.

## Test plan (manual; no harness exists for AppKit focus paths)

- [ ] Depth 1 unchanged (modulo the documented ⌘D-repeat change): ⌘D/⇧⌘D,
      ⌘W, focus arrows, resize, takeover, sidebar invisibility — same as
      today. Sibling attaches provably undisturbed (no relaunch, shell
      keeps running server-side, scrollback intact).
- [ ] Split a split terminal (⌘D with focus right): three panes, herdr TUI
      shows the nested layout; closing the middle pane prunes correctly,
      survivor keeps running with scrollback intact (no relaunch — assert
      explicitly, this is the load-bearing invariant), keyboard on the
      survivor.
- [ ] Mixed directions (vertical split inside a horizontal one and reverse),
      including same-direction nesting (three columns via two vertical
      splits).
- [ ] ⌘W on each pane closes that pane (+focuses nearest survivor); ⌘W on
      the agent collapses all and closes every descendant pane server-side.
- [ ] Repeat-press semantics: ⌘D always nests under focus (each new pane
      auto-focuses, so repeats drill deeper); no shortcut re-aims —
      orientation is fixed at split time, close + re-split to change it.
- [ ] Divider drag adjusts ratios without disturbing attaches; clicking a
      mouse-reporting pane adjacent to a divider still reaches the TUI
      (overlay hit-strip tradeoff, same as today).
- [ ] Rapid ⌘D⌘D / close-mid-open (including across two leaves): no orphaned
      server panes (`herdr pane list` before/after), no killed survivors
      (`herdr pane get` on every surviving paneID).
- [ ] Remote device: all of the above against an SSH device.

## Risks

- The pool strategy trades view-hierarchy complexity for layout code: the
  `layout()` function and divider overlay are new custom code (mitigation:
  pure and unit-testable; divider math ports from `SplitContainer`).
- Focus-tracking generalization is the fiddliest part (KVO on
  firstResponder + view-walk per change + new leaf registry); the current
  two-side tracker was already subtle. Mitigation: leaf-ID resolution is a
  pure function of the view hierarchy, covered by the same manual pass.
- Menu shortcut staleness (the ⌘D lesson) recurs if new commands gate on
  `.disabled()` — noted as a hard rule in §4.
- The load-bearing invariant (§0/§2: never unmount a live pane) constrains
  all future split UI work the way the root-container trick constrained the
  single split. When in doubt, re-read `SplitContainer.swift:8-13` and §0.
- Scope creep into ratio sync / server-layout mirroring — explicitly out;
  structure-only agreement is the contract.
