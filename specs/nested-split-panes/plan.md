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
  is the kept-alive attach stack, the shell side one attach.
- `SplitFocusTracker` reports `.agent` / `.shell` via two closures
  (`isAgentView`, `shellView`). Menu commands assume two panes: 8 fixed
  focus items (per-axis), 4 resize items, ⌘W closes the whole split first.
- `openSplit(axis:)` splits the *selected entry's* pane; `closeSplitTerminal`
  closes *the* pane. Concealment (`concealedSplitPaneIDs` + `isSplitPane`)
  is already pane-ID based and works for N panes unchanged.

## Design

### 1. Tree model (`AppModel.swift`)

```swift
/// A leaf is either the agent side (virtual: renders the selected attach
/// stack, owns no server pane) or one split terminal (owns its pane).
enum SplitLeaf: Equatable {
    case agent
    case terminal(SplitPane)  // today's SplitTerminal, renamed
}

indirect enum SplitNode: Equatable {
    case leaf(SplitLeaf)
    case split(axis: SplitAxis, ratio: Double, first: SplitNode, second: SplitNode)
}

@Published var splitTree: SplitNode?  // nil == no split, replaces shellSplitAxis + splitTerminal
@Published var focusedSplitLeaf: SplitLeafID?  // nil == agent side holds the keyboard
```

- `SplitLeafID`: agent marker vs pane ID (`deviceID/paneID`, same key shape
  as the conceal set). Equality by value; no view references in the model.
- `splitRatio` persistence stays root-only (today's `terminal.splitRatio`
  key); deeper nodes keep in-memory ratios. Rationale: the root split is
  the 99% case, and per-node persistence keys have no stable identity
  across sessions (panes are ephemeral).
- `openSplit(axis:)` becomes: resolve the *focused leaf's* herdr pane
  (agent leaf → selected entry's pane; terminal leaf → its pane), then
  `pane.split` in the requested direction and replace that leaf with
  `split(axis, ratio: <current root ratio or 0.5>, first: <old leaf>,
  second: <new terminal>)`. New pane always goes second (right/bottom),
  matching today's behavior. The existing mid-flight guards (in-flight
  dedup, selection-change check, retry loop, conceal-before-publish) move
  with it unchanged, keyed per creation task.
- Closing: `closeSplitLeaf(_:)` closes a terminal leaf's pane via
  `pane.close` (un-splits server-side) and collapses its parent
  (`split → surviving sibling`). Closing the agent leaf collapses the
  *whole tree* (`splitTree = nil`), preserving today's "⌘W on agent closes
  the split" feel. The axis-didSet funnel is replaced by tree-mutation
  helpers — every mutation goes through `updateSplitTree(_:)` so the
  close-pane side effect can't be bypassed.
- `closeSplitTerminal`'s conceal-lifetime discipline (re-cover before
  unpublish, deferred removal post-refresh, reuse guard) applies per leaf
  unchanged.

### 2. Recursive rendering (`ContentView.swift`, `SplitContainer.swift`)

- New `SplitTreeView`: renders a `SplitNode` recursively. A `split` node
  renders today's `SplitContainer` geometry (divider drag writes the node's
  ratio back through `updateSplitTree`); a `leaf(.agent)` renders the
  existing kept-alive attach stack verbatim; a `leaf(.terminal)` renders
  one `AttachTerminalView` keyed by pane ID (today's pattern).
- `SplitContainer` itself is untouched (still two generic children); the
  recursion lives in the new view, which nests containers. Identity rules
  from the single-split work hold per node: stable `.id`s, no conditional
  branch swaps around live attaches.
- Focus dimming generalizes: the focused leaf renders at full opacity,
  all others dimmed (today's `inactivePaneOpacity`).

### 3. Focus tracking (`TerminalView.swift`)

- `SplitFocusTracker` reports a leaf ID instead of a side: replace
  `isAgentView`/`shellView` with a single `(NSView) -> SplitLeafID?`
  resolver supplied by the view layer (agent registry hit → `.agent`;
  walk up to the nearest pane container view carrying its leaf ID →
  that leaf). No side enum, no per-side stored refs.
- `focusedSplitLeaf` drives focus commands and dimming. Tracker keeps its
  no-cache discipline (reports every change, never dedupes).

### 4. Menu commands (`HerdrMApp.swift`)

- Split Vertically / Horizontally (⌘D / ⇧⌘D): split the *focused leaf*,
  enabled whenever a tree *or* a selected entry exists (tree nil + entry
  selected → today's open path).
- Focus arrows (⌘⌥ arrows): move keyboard focus to the *neighbor leaf* in
  that direction, computed from tree geometry. Always enabled while a tree
  exists; no per-axis fixed items (the 8-item workaround goes away — items
  no longer encode the axis, so the stale-shortcut class it worked around
  can't recur).
- Resize (⌘⌃ arrows): grow/shrink the focused leaf's parent divider.
  Same enablement as focus.
- ⌘W: close the focused leaf (terminal → close pane + collapse; agent →
  collapse whole tree). With no tree, falls through to today's
  split → shell → window chain.
- Disabled-state staleness (the ⌘D lesson): commands that depend on
  `focusedSplitLeaf` must not rely on `.disabled()` revalidation for
  correctness of the *shortcut path* — actions no-op safely on nil focus,
  same guard style as `focusSplitSide`/`resizeSplit` today.

### 5. Server mapping

- Every terminal leaf is a `pane.split` child of whatever leaf was focused
  at creation (agent pane or another split terminal). `pane.close` on a
  child un-splits; the sibling (agent pane included) is untouched —
  verified semantics of the existing single split.
- No new RPCs. `focus: false` on creation everywhere, as today.
- Divider ratios stay local (not propagated to the server). The two views
  agree on structure, not proportions — same position as the current
  split; full ratio sync is a separate, explicitly deferred decision.

## Migration steps

1. `AppModel`: add `SplitLeaf`/`SplitNode`/`focusedSplitLeaf` + tree
   helpers (`updateSplitTree`, `closeSplitLeaf`); reimplement
   `openSplit`/`closeSplitTerminal` on the tree for the depth-1 case.
   Keep `shellSplitAxis`/`splitTerminal` as computed shims during
   migration, remove at the end.
2. `SplitTreeView` + recursive rendering in `DetailView`; depth-1 tree
   must render pixel-identical to today before proceeding.
3. Focus tracker → leaf IDs; menu rewritten (split/focus/resize/⌘W).
4. Depth-N enablement: split-focused-leaf path, collapse logic,
   concealment already N-safe (verify with 3-pane manual test).
5. Delete shims (`shellSplitAxis`, `splitTerminal`, `SplitSide`,
   `activeSplitSide`); full build + manual pass; squash.

Each step keeps `make build` green and depth-1 behavior unchanged, so the
work can land incrementally if preferred.

## Test plan (manual; no harness exists for AppKit focus paths)

- [ ] Depth 1 unchanged: ⌘D/⇧⌘D, ⌘W, focus arrows, resize, takeover,
      sidebar invisibility — same as today.
- [ ] Split a split terminal (⌘D with focus right): three panes, herdr TUI
      shows the nested layout; closing the middle pane collapses correctly.
- [ ] Mixed directions (vertical split inside a horizontal one and reverse).
- [ ] ⌘W on each pane closes that pane; ⌘W on the agent collapses all.
- [ ] Rapid ⌘D⌘D / close-mid-open: no orphaned server panes
      (`herdr pane list` before/after).
- [ ] Remote device: all of the above against an SSH device.

## Risks

- Focus-tracking generalization is the fiddliest part (KVO on
  firstResponder + view-walk per keystroke-adjacent change); the current
  two-side tracker was already subtle. Mitigation: leaf-ID resolution is a
  pure function of the view hierarchy, covered by the same manual pass.
- Menu shortcut staleness (the ⌘D lesson) recurs if new commands gate on
  `.disabled()` — noted as a hard rule in §4.
- Scope creep into ratio sync / server-layout mirroring — explicitly out;
  structure-only agreement is the contract.
