# Sidebar click semantics (phase-1) — implementation plan

Epic: `backlog/epics/herdrm-sidebar-interaction-semantics.md` §phase-1
(laplace hub). Branch: `feat/sidebar-click-semantics`.

## Goal

Split the sidebar row-click meaning in two. Clicking a **split member**
row focuses its split column without touching any attach; clicking a
**free pane** row keeps today's take-over-on-click. Members become
visible in the sidebar again (display only — no status badges; those are
phase-2).

## Non-goals

- Member status badges / liveness display (phase-2).
- Selection / ⌘K palette / auto-select audit (phase-3). `SearchView`,
  auto-selection (`AppModel.swift:2126`), drag targets, and snapshot
  focus keep their `isSplitPane` guards — they are attach paths, not
  display paths, and must never double-attach.
- Tab＞panes tree sidebar (phase-4, optional).
- iOS (`HerdrMobile`). macOS only, same as the split work.

## Current state (what must change)

All in `Sources/HerdrM` (`AppModel.swift`, `SidebarView.swift`):

- Concealment hides members from display: `visibleAgents`
  (`AppModel.swift:963`, `entries.removeAll(where: { isSplitPane... })`)
  and `visibleTerminals` (`AppModel.swift:1001`, same shape). This is
  what phase-1 partially reverts — display only.
- Both row types click through `selectAgent`: `AgentRowView`
  (`SidebarView.swift:430`, + accessibility `456`) and
  `TerminalRowView` (`SidebarView.swift:309`, + accessibility `335`).
  `selectAgent` (`AppModel.swift:1177`) assigns `selectedPane`, whose
  `didSet` mounts the attach via `noteSelectedAttachSession`
  (`AppModel.swift:139`) — that function already guards members, so a
  member click today would move selection *without* mounting anything:
  all cost, no benefit. Member clicks must not reach `selectedPane`.
- Column focus already exists: `focusSplitLeaf(_:)`
  (`AppModel.swift:1662`) puts the keyboard on a leaf view via
  `SplitLeafViewRegistry`, and `SplitLeafID.pane(deviceID:paneID)`
  (`AppModel.swift:178`) builds directly from a member's IDs. No new
  focus machinery needed.
- Focus truth already exists: `SplitFocusTracker` reports into
  `focusedSplitLeaf`; the split draws the active pane undimmed. The
  sidebar needs to read the same source for member-row highlight.

## Design

1. **Show members again, marked.** New `sidebarAgents` /
   `sidebarTerminals` display lists include members (shared builders
   with the filtered `visibleAgents` / `visibleTerminals`, which keep
   feeding auto-select, drag targets, search — attach paths stay
   guarded). Member rows carry a split marker icon and no status
   visuals (glyph, needs-input, unread, status VoiceOver all
   suppressed — badges are phase-2); member drags never start and
   members are not drop targets. All other `isSplitPane` call sites
   stay: `noteSelectedAttachSession`, search, auto-select, drag
   targets, snapshot/restore fixups.
2. **Route clicks by ownership.** `selectSidebarEntry`: if
   `isSplitPane(...)` → focus the member column and mount no attach;
   else → today's `selectAgent` path plus an explicit agent-leaf focus
   handoff. Both paths clear shells / file manager first. Exception:
   while the tree is suspended (selection on a foreign tab) a bare focus
   is a no-op, so a member click first reselects the owner —
   `selectedPane` *does* change there, mounting the owner's attach
   exactly as if the owner row had been clicked — then focuses the
   member, with an async re-assert guarded on the selection. Focus
   claims are verified (`focusSplitLeaf` returns Bool); a failed focus
   never updates `focusedSplitLeaf`.
3. **Single highlight = keyboard position.** A member row highlights
   from `focusedSplitLeaf == .pane(...)` (gated on the split showing
   and no shell/file-manager overlay); a free row highlights from
   `selectedPane` only while the split is hidden or the agent leaf
   holds focus. Never two lit rows. (This is the "I clicked — now
   what" feedback agreed in discussion: focus move must be visible
   at both ends.)
4. **Column-side feedback for free.** Focus lands via the real first
   responder, so the existing active-pane undimming confirms arrival.
   If `focusSplitLeaf` no-ops (suspended tree, view not ready), the
   tracker reports nothing and selection stays put — a failed focus
   changes nothing, same contract as `focusNeighbor`.

## Steps

1. AppModel: `sidebarAgents` / `sidebarTerminals` display lists that
   include members (the filtered `visibleAgents` / `visibleTerminals`
   keep feeding auto-select, drag targets, search — attach paths stay
   guarded); add the click router `selectSidebarEntry` + highlight
   helper `isMemberFocused`.
2. SidebarView: member marker; route `onClick` + accessibility
   through the router; member highlight from `focusedSplitLeaf`.
3. Build (`make build`), click through: member click focuses column
   with no new attach (`attachSessions` unchanged); free click
   takeovers as today; no double-attach (pool attach survives).
4. Review-loop before PR, same as the split PRs.

## Load-bearing constraint (from PR #5, do not regress)

A second `--takeover` attach of an already pool-attached pane kicks
the pool's attach, whose `onExit` closes the pane the user just
opened (`AppModel.swift:211-214`). Every new code path that touches
a member pane must be focus-only. When in doubt, grep `isSplitPane`
call sites and ask which side of the display/attach line each is on.
