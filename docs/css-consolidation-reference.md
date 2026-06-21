# CSS Consolidation Reference

All inline `style=` props removed from the three workflow files and replaced with
`className=` references in `src/assets/style.css`.

**Date:** 2026-05-11  
**Files changed:**
- `src/workflow/components/WorkflowTimeline.tsx`
- `src/workflow/screens/WorkflowReview.tsx`
- `src/workflow/screens/ApproverInbox.tsx`
- `src/assets/style.css` (classes appended at end)

---

## 1 — WorkflowTimeline.tsx

| Old inline style (element) | New CSS class |
|---|---|
| `<p style={{ color:'#9CA3AF', fontSize:13, padding:'16px 0' }}>` | `.wft-empty` |
| `<div style={{ position:'relative', paddingLeft:32 }}>` (container) | `.wft-container` |
| `<div style={{ position:'absolute', left:10, top:8, bottom:8, width:2, background:'#E5E7EB', borderRadius:2 }}>` (vertical line) | `.wft-line` |
| `<div style={{ display:'flex', gap:12, marginBottom:20, position:'relative' }}>` (event row) | `.wft-event-row` |
| `<div style={{ position:'absolute', left:-32, width:20, height:20, borderRadius:'50%', display:'flex', ... }}>` (event dot — static parts) | `.wft-event-dot` |
| `border: \`2px solid ${cfg.iconColor}\`` on event dot | kept inline (dynamic per action) |
| `<i style={{ fontSize:9, color:cfg.iconColor }}>` inside dot | kept inline (dynamic) |
| `<div style={{ flex:1 }}>` (event content) | `.wft-event-content` |
| `<div style={{ display:'flex', alignItems:'center', gap:8, flexWrap:'wrap' }}>` (event header) | `.wft-event-header` |
| `<span style={{ fontWeight:600, fontSize:13, color:'#111827' }}>` (action label) | `.wft-event-label` |
| `<span style={{ fontSize:12, color:'#6B7280' }}>` (actor "by X") | `.wft-event-actor` |
| `<span style={{ fontSize:11, color:'#9CA3AF', background:'#F3F4F6', borderRadius:4, padding:'1px 6px' }}>` (step badge) | `.wft-step-badge` |
| `<div style={{ fontSize:12, color:'#9CA3AF', marginTop:2 }}>` (timestamp) | `.wft-event-time` |
| `<div style={{ marginTop:8, background:'#F8FAFC', borderRadius:'0 4px 4px 0', padding:'7px 10px', ... }}>` (comment box — static parts) | `.wft-comment-box` |
| `borderLeftColor: cfg.iconColor` on comment box | kept inline (dynamic) |
| `<div style={{ fontSize:10, fontWeight:600, color:'#9CA3AF', textTransform:'uppercase', ... }}>` (💬 Comment label) | `.wft-comment-label` |
| `<div style={{ fontSize:13, color:'#374151', lineHeight:1.5, cursor:'default', userSelect:'text' }}>` (comment text) | `.wft-comment-text` |
| `<div style={{ position:'absolute', left:-32, width:20, height:20, borderRadius:'50%', background:'#FEF9C3', border:'2px dashed #D97706', ... }}>` (pending dot) | `.wft-pending-dot` |
| `<span style={{ fontWeight:600, fontSize:13, color:'#92400E' }}>` (Awaiting: label) | `.wft-pending-label` |
| `<span style={{ fontSize:11, background:'#FEF9C3', color:'#92400E', borderRadius:4, padding:'1px 6px' }}>` (pending step badge) | `.wft-pending-step-badge` |
| `<div style={{ position:'absolute', left:-32, ... background:'#FEF3C7', border:'2px dashed #B45309', ... }}>` (clarification dot) | `.wft-clarification-dot` |
| `<span style={{ fontWeight:600, fontSize:13, color:'#92400E' }}>` (Awaiting your response) | `.wft-clarification-label` |
| `<span style={{ fontSize:11, background:'#FEF3C7', color:'#B45309', border:'1px solid #FDE68A', ... display:'flex', alignItems:'center', gap:3 }}>` (Needs your input pill) | `.wft-clarification-badge` |
| `<div style={{ fontSize:12, color:'#B45309', marginTop:3 }}>` (clarification note text) | `.wft-clarification-note` |

---

## 2 — WorkflowReview.tsx

### Layout / screen

| Old inline style (element) | New CSS class |
|---|---|
| `<div style={{ height:'calc(100vh - 60px)', margin:'-28px -32px', background:'#F8FAFC', display:'flex', flexDirection:'column', overflow:'hidden' }}>` | `.wfr-root` |
| `<div style={{ position:'sticky', top:0, zIndex:40, boxShadow:'0 2px 8px ...' }}>` (sticky header) | `.wfr-sticky-header` |
| `<div style={{ display:'flex', alignItems:'center', justifyContent:'space-between', padding:'10px 32px', background:'#18345B' }}>` (nav bar) | `.wfr-nav-bar` |
| `<button style={{ display:'flex', alignItems:'center', gap:8, background:'none', border:'none', color:'#93C5FD', fontWeight:600, fontSize:13, cursor:'pointer' }}>` (Back button) | `.wfr-back-btn` |
| `<div style={{ textAlign:'center' }}>` (nav center) | `.wfr-nav-center` |
| `<div style={{ fontWeight:800, fontSize:15, color:'#fff' }}>` (report title) | `.wfr-nav-title` |
| `<div style={{ fontSize:11, color:'#93C5FD' }}>` (submitted by line) | `.wfr-nav-subtitle` |
| `<div style={{ display:'flex', alignItems:'center', gap:10 }}>` (right side of nav) | `.wfr-nav-actions` |
| `<span style={{ fontSize:15, fontWeight:800, color:'#fff' }}>` (total in nav) | `.wfr-nav-total` |
| `<div style={{ margin:'16px 32px 0', padding:'12px 16px', borderRadius:8, background:'#F0FDF4', ... }}>` (success banner) | `.wfr-success-banner` |
| `<div style={{ flex:1, overflowY:'auto', minHeight:0 }}>` (scrollable area) | `.wfr-scroll-area` |
| `<div style={{ maxWidth:960, margin:'0 auto', padding:'20px 32px', width:'100%', boxSizing:'border-box' }}>` (content container) | `.wfr-content` |
| `<div style={{ textAlign:'center', padding:'80px 0', color:'#9CA3AF' }}>` (loading) | `.wfr-loading` |
| `<i style={{ fontSize:32, marginBottom:16, display:'block' }}>` (loading spinner) | `.wfr-loading-icon` |
| `<div style={{ padding:'24px', borderRadius:10, background:'#FEF2F2', ... }}>` (error box) | `.wfr-error` |
| `<i style={{ fontSize:28, marginBottom:8, display:'block' }}>` (error icon) | `.wfr-error-icon` |
| `<div style={{ flexShrink:0, boxShadow:'0 -2px 8px ...' }}>` (bottom bar wrapper) | `.wfr-action-bar-wrapper` |
| `<div style={{ flexShrink:0, padding:'12px 32px', background:'#FFFBEB', borderTop:'1px solid #FDE68A', ... }}>` (read-only notice) | `.wfr-readonly-notice` |

### Summary card & Section component

| Old inline style | New CSS class |
|---|---|
| `<div style={{ background:'#fff', borderRadius:12, border:'1px solid #E5E7EB', marginBottom:20, overflow:'hidden' }}>` (card) | `.wfr-card` |
| `<div style={{ display:'flex', alignItems:'center', gap:8, padding:'10px 16px', borderBottom:'1px solid #E5E7EB', background:'#FAFAFA' }}>` (card header) | `.wfr-card-header` |
| `<i style={{ fontSize:13, color:'#6B7280' }}>` (header icon) | `.wfr-card-header-icon` |
| `<span style={{ fontSize:11, fontWeight:700, color:'#374151', textTransform:'uppercase', letterSpacing:'0.05em' }}>` (header label) | `.wfr-card-header-label` |
| `<span style={{ fontSize:11, background:'#E5E7EB', color:'#6B7280', borderRadius:10, padding:'1px 8px', fontWeight:700 }}>` (count pill) | `.wfr-card-header-count` |
| `<div style={{ display:'grid', gridTemplateColumns:'repeat(5, 1fr)' }}>` (summary grid) | `.wfr-summary-grid` |
| `<div style={{ padding:'12px 16px', borderRight:'0.5px solid #E5E7EB' }}>` (summary cell) | `.wfr-summary-item` |
| `borderRight: 'none'` on last cell | `.wfr-summary-item--last` |
| `<div style={{ fontSize:10, fontWeight:700, color:'#9CA3AF', textTransform:'uppercase', ... }}>` (cell label) | `.wfr-summary-label` |
| `<div style={{ fontSize:13, fontWeight:600, color:'#111827' }}>` (cell value) | `.wfr-summary-value` |
| `<div style={{ fontSize:15, fontWeight:800, color:'#18345B' }}>` (highlighted cell value) | `.wfr-summary-value--highlight` |
| `<div style={{ marginBottom:20, background:'#fff', borderRadius:12, border:'1px solid #E5E7EB' }}>` (Section wrapper) | `.wfr-section` |
| Section header div (same as card header) | `.wfr-section-header` |
| `<th style={{ padding:'10px 14px', textAlign:'left', fontWeight:600, color:'#6B7280', fontSize:11, ... }}>` | `.wfr-th` |
| `<div style={{ display:'flex', alignItems:'center', gap:6, marginTop:8, fontSize:11, color:'#92400E' }}>` (edit hint) | `.wfr-edit-hint` |
| `<span style={{ display:'inline-block', width:12, height:12, borderRadius:2, background:'#FFFBEB', border:'1px solid #FDE68A' }}>` (swatch) | `.wfr-edit-hint-swatch` |

### ActionBar component

| Old inline style | New CSS class |
|---|---|
| `<div style={{ display:'flex', flexDirection:'column', gap:10, padding:'14px 32px', background:'#fff', borderTop:'2px solid #E5E7EB' }}>` | `.wfr-action-bar` |
| `<div style={{ fontSize:11, fontWeight:700, color:'#9CA3AF', textTransform:'uppercase', letterSpacing:'0.05em', marginBottom:5 }}>` (note label) | `.wfr-action-note-label` |
| `<textarea style={{ width:'100%', padding:'8px 10px', borderRadius:6, fontSize:13, resize:'none', ..., background:'#FAFAFA' }}>` (border stays inline) | `.wfr-action-textarea` |
| `border: \`1px solid ${error ? '#FECACA' : '#D1D5DB'}\`` | kept inline (dynamic) |
| `<div style={{ display:'flex', gap:8, height:38 }}>` (button row) | `.wfr-btn-row` |
| Approve button static styles (width, borderRadius, color, fontWeight etc.) | `.wfr-btn-approve` |
| `background: loading ? '#9CA3AF' : '#16A34A'` on Approve | kept inline (dynamic) |
| Reject button static styles | `.wfr-btn-reject` |
| `<div style={{ position:'relative', width:'10%', flexShrink:0 }}>` (More wrapper) | `.wfr-btn-more-wrapper` |
| More button static styles | `.wfr-btn-more` |
| `background: showMore ? '#F3F4F6' : '#FAFAFA'` on More | kept inline (dynamic) |
| `<div style={{ position:'absolute', bottom:'calc(100% + 6px)', ... }}>` (dropdown) | `.wfr-more-dropdown` |
| More item button base | `.wfr-more-item` |
| `<div style={{ width:4, alignSelf:'stretch', background:..., borderRadius:'10px 0 0 10px' }}>` (accent bar) | `.wfr-more-item-accent` |
| `<div style={{ display:'flex', alignItems:'center', gap:12, padding:'12px 14px', flex:1 }}>` | `.wfr-more-item-body` |
| `<div style={{ width:32, height:32, borderRadius:8, display:'flex', alignItems:'center', justifyContent:'center', flexShrink:0 }}>` | `.wfr-more-item-icon` |
| `<div style={{ fontSize:13, fontWeight:600 }}>` (item title) | `.wfr-more-item-title` |
| `<div style={{ fontSize:11, marginTop:1 }}>` (item sub) | `.wfr-more-item-sub` |
| `<div style={{ display:'flex', gap:8 }}>` (secondary row) | `.wfr-secondary-btn-row` |
| Confirm button static styles | `.wfr-secondary-confirm-btn` |
| `background` on confirm (depends on mode) | kept inline (dynamic) |
| Cancel button | `.wfr-secondary-cancel-btn` |
| `<p style={{ fontSize:12, color:'#DC2626', margin:0 }}>` (error) | `.wfr-action-error` |
| `<label style={{ fontSize:11, fontWeight:600, color:'#6B7280', textTransform:'uppercase', display:'block', marginBottom:4 }}>` | `.wfr-reassign-label` |
| Reassign target chip div | `.wfr-reassign-chip` |
| Chip name, title, remove button | `.wfr-reassign-chip-name` / `.wfr-reassign-chip-title` / `.wfr-reassign-chip-remove` |
| Search wrapper `position:relative, maxWidth:340` | `.wfr-search-wrapper` |
| Search input | `.wfr-search-input` |
| Search results dropdown | `.wfr-search-dropdown` |
| Each result button | `.wfr-search-result-btn` |
| Result name / title | `.wfr-search-result-name` / `.wfr-search-result-title` |

---

## 3 — ApproverInbox.tsx

### Main layout

| Old inline style | New CSS class |
|---|---|
| Root container (`height:calc(100vh - 60px), margin:'-28px -32px'` etc.) | `.wfi-root` |
| Header bar | `.wfi-header` |
| `<h1 style={{ fontSize:18, fontWeight:800, color:'#18345B', margin:0 }}>` | `.wfi-header-title` |
| `<p style={{ fontSize:12, color:'#6B7280', margin:0 }}>` | `.wfi-header-subtitle` |
| Refresh button | `.wfi-refresh-btn` |
| Tab bar | `.wfi-tab-bar` |
| Tab button styles | kept inline (active/inactive are dynamic) |
| KPI cards row | `.wfi-kpi-bar` |
| Split pane | `.wfi-split-pane` |
| Left 320px panel | `.wfi-list-panel` |
| Right flex panel | `.wfi-detail-panel` |
| Empty state container | `.wfi-empty-state` |
| Empty icon circle | `.wfi-empty-icon-wrap` |
| Amber variant | `.wfi-empty-icon-wrap--amber` |
| Empty title / subtitle | `.wfi-empty-title` / `.wfi-empty-subtitle` |
| Global error toast | `.wfi-error-toast` |
| Toast close button | `.wfi-error-toast-close` |
| Loading state | `.wfi-loading` |

### Shared helpers (SectionTitle, MetaItem)

| Old inline style | New CSS class |
|---|---|
| `<div style={{ display:'flex', alignItems:'center', gap:8, marginBottom:10 }}>` | `.wfi-section-title` |
| `<span style={{ fontSize:12, fontWeight:700, color:'#374151', textTransform:'uppercase', ... }}>` | `.wfi-section-title-text` |
| Count pill on SectionTitle | `.wfi-section-count` |
| MetaItem label div | `.wfi-meta-label` |
| MetaItem value div | `.wfi-meta-value` |

### Detail panel scroll area & headers

| Old inline style | New CSS class |
|---|---|
| `display:'flex', flexDirection:'column', flex:1, overflow:'hidden'` (wrapper) | `.wfi-detail-wrapper` |
| `flex:1, overflowY:'auto', minHeight:0, padding:'20px 24px'` (scroll area) | `.wfi-panel-scroll` |
| Detail header margin wrapper | `.wfi-detail-header` |
| Header flex row | `.wfi-detail-header-row` |
| Title+subtitle group | `.wfi-detail-title-group` |
| `<h2 style={{ fontSize:18, fontWeight:800, color:'#18345B', margin:0, lineHeight:1.3 }}>` | `.wfi-detail-title` |
| `<div style={{ fontSize:12, color:'#6B7280', marginTop:4 }}>` | `.wfi-detail-subtitle` |
| Open Full View button | `.wfi-full-view-btn` |
| Badge/amount row | `.wfi-badge-row` |
| Amount badge `<span>` | `.wfi-amount-badge` |
| `<div style={{ borderTop:'1px solid #F3F4F6', marginBottom:16 }}>` | `.wfi-separator` |
| Meta row | `.wfi-meta-row` |

### PanelActionBar (To Approve action bar)

| Old inline style | New CSS class |
|---|---|
| `borderTop:'2px solid #E5E7EB', padding:'14px 20px', background:'#FAFAFA', flexShrink:0` | `.wfi-panel-action-bar` |
| `<textarea style={{ ... }}>` static parts | `.wfi-action-textarea` |
| `border` on textarea (depends on error) | kept inline |
| `<p style={{ fontSize:12, color:'#DC2626', margin:'0 0 8px' }}>` (error) | `.wfi-action-error` |
| Idle button row `height:34, gap:3` | `.wfi-action-btn-row` |
| Approve button static parts | `.wfi-action-approve-btn` |
| Approve background (depends on loading) | kept inline |
| Reject button static parts | `.wfi-action-reject-btn` |
| More wrapper | `.wfi-action-more-wrapper` |
| More button | `.wfi-action-more-btn` |
| More dropdown | `.wfi-more-dropdown` |
| More item buttons | `.wfi-more-item` |
| Item icon box | `.wfi-more-item-icon` |
| Item title / sub | `.wfi-more-item-title` / `.wfi-more-item-sub` |
| Secondary mode button row | `.wfi-secondary-btn-row` |
| Confirm button (static) | `.wfi-secondary-confirm-btn` |
| Confirm background (depends on mode) | kept inline |
| Cancel button | `.wfi-secondary-cancel-btn` |
| Reassign target chip | `.wfi-reassign-chip` |
| Chip name / title / remove | `.wfi-reassign-chip-name` / `.wfi-reassign-chip-title` / `.wfi-reassign-chip-remove` |
| Search wrapper / input / dropdown / result buttons | `.wfi-search-wrapper` / `.wfi-search-input` / `.wfi-search-dropdown` / `.wfi-search-result-btn` |
| Result name / title | `.wfi-search-result-name` / `.wfi-search-result-title` |

### SentBackActionBar

| Old inline style | New CSS class |
|---|---|
| Respond button row | `.wfi-respond-btn-row` |
| Respond & Resume button (static parts) | `.wfi-respond-btn` |
| Background (depends on loading) | kept inline |
| Update button | `.wfi-update-btn` |
| Withdraw button | `.wfi-withdraw-btn` |
| Confirm-withdraw row | `.wfi-withdraw-confirm-row` |
| "Cancel request?" label | `.wfi-withdraw-confirm-label` |
| Yes / No confirm buttons | `.wfi-withdraw-confirm-yes` / `.wfi-withdraw-confirm-no` |

### SentBackDetailPanel

| Old inline style | New CSS class |
|---|---|
| Clarification callout box | `.wfi-clarification-callout` |
| Callout header | `.wfi-clarification-callout-header` |
| Callout time | `.wfi-clarification-callout-time` |
| Callout body | `.wfi-clarification-callout-body` |
| Inline edit mode bar | `.wfi-edit-mode-bar` |
| Edit mode textarea | `.wfi-edit-mode-textarea` |
| Edit button row | `.wfi-edit-btn-row` |
| Update & Resubmit button (static parts) | `.wfi-edit-submit-btn` |
| Cancel button | `.wfi-edit-cancel-btn` |

### DetailPanel (note callout, ExpenseEnrichment helpers)

| Old inline style | New CSS class |
|---|---|
| Approver note callout wrapper | `.wfi-note-callout` |
| Note callout meta line | `.wfi-note-callout-meta` |
| Note callout time span | `.wfi-note-callout-time` |
| Note callout text | `.wfi-note-callout-text` |
| Large-report warning banner | `.wfi-large-report-banner` |
| Warning text | `.wfi-large-report-text` |
| "Full View" link button | `.wfi-large-report-link` |
| Loading placeholder inside ExpenseEnrichment | `.wfi-inline-loading` |
| Editing badge (ProfileEnrichment edit mode) | `.wfi-editing-badge` |

---

## What was intentionally left as inline style

These were kept inline because they have **at least one dynamic value** determined
at runtime by component state or props:

- **Event dot `border` colour** — depends on `cfg.iconColor` (one of 8 action types)
- **Comment box `borderLeftColor`** — same `cfg.iconColor`
- **Approve / Reject background when loading** — ternary on `loading` state
- **More button background** — ternary on `showMore` state
- **ActionBar / PanelActionBar textarea `border`** — ternary on `error` state
- **Secondary-confirm button background** — ternary on `mode` ('reassign' / 'return_init' / 'return_prev')
- **Tab button colour, underline, font-weight** — ternary on `isActive` + `tab` identity
- **KpiCard all styles** — almost entirely driven by `active` flag and passed `color`/`bg`/`border` props
- **TaskCard background & borderLeft** — driven by `selected` prop
- **SentBackCard background & borderLeft** — driven by `selected` prop
- **SLA badge colours** — driven by `slaStatus` value from server
- **Table row `borderBottom`** — ternary on whether it's the last row
- **Note-editable textarea border** — focus state toggled via `onFocus` handler
- **Edit submit button background** — ternary on `resubmitting` state
- **Inline `<table>` cell styles in ExpenseEnrichment** — compact component, data-driven widths

> **Rule applied:** if the style object contains even one JS-expression value, the
> entire `style=` prop was left in place to avoid splitting a cohesive block across
> two files. Only 100 % static objects were migrated to class names.
