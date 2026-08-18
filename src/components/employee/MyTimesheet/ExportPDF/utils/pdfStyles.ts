import { StyleSheet } from '@react-pdf/renderer';

/**
 * One StyleSheet for the whole document. react-pdf supports a subset of CSS —
 * flexbox, borders, padding — but no grid, no shorthand `border`, and no cascade.
 * Anything shared lives here so four pages cannot drift apart.
 */

export const colors = {
  blue:     '#1E40AF',
  blueMid:  '#2563EB',
  blueLt:   '#DBEAFE',
  green:    '#065F46',
  greenMid: '#10B981',
  greenLt:  '#D1FAE5',
  purple:   '#7C3AED',
  purpleLt: '#EDE9FE',
  amber:    '#F59E0B',
  amberLt:  '#FEF3C7',
  red:      '#DC2626',
  redLt:    '#FEE2E2',
  ink:      '#111827',
  ink2:     '#374151',
  ink3:     '#6B7280',
  ink4:     '#9CA3AF',
  border:   '#E5E7EB',
  surface:  '#F9FAFB',
  white:    '#FFFFFF',
  rule:     '#E8EAEE',
  headRule: '#DCE7F8',
} as const;

/**
 * The six states a calendar day can be in, each a background / border / ink
 * triple plus a dot. Named once here because the grid, the legend and any
 * future consumer must agree — a legend that disagrees with the grid is worse
 * than no legend.
 *
 * "over" is what the mockup calls Overtime. This system has no overtime concept,
 * no calculation and no approval path for one, so the word is not used: the
 * state is "more recorded than planned", which is exactly what the calendar
 * cell already shows on screen.
 */
export const dayState = {
  // Matched EXACTLY to the approval screens (workflow/timesheet/TimesheetReview
  // .tsx -> CELL_STYLE). One vocabulary, one palette: the approver reviewing a
  // month and the employee who filed it must not see two colour languages.
  //
  // A day is judged against ITS OWN planned hours, never a literal 8 -- a 4h
  // day with 6h recorded is over, not short.
  onPlan:    { bg: '#EFF8E4', border: '#D7EBC2', ink: '#3F6212', dot: '#65A30D', bw: 1, label: 'On plan'      },
  underPlan: { bg: '#FEF7E8', border: '#FBE3B4', ink: '#B45309', dot: '#F0A020', bw: 1, label: 'Under plan'   },
  // OVER is red, and it covers weekend and worked-holiday hours too: on a day
  // with no plan, every hour recorded is beyond the schedule.
  over:      { bg: '#FDEEEF', border: '#FBD5D8', ink: '#B91C1C', dot: '#DC2626', bw: 1, label: 'Over planned' },
  // MISSING is the only state separated on LIGHTNESS rather than hue: white,
  // ringed in charcoal. It is the state a reader must FIND rather than compare,
  // and lightness is the one channel neither colour blindness nor a mono
  // printer takes away. It used to be amber, which sat 1.8 dE from over-plan
  // red under deuteranopia -- the two states that must never be confused were
  // the two closest on the page.
  missing:   { bg: '#FFFFFF', border: '#48505F', ink: '#48505F', dot: '#48505F', bw: 2, label: 'Missing'      },
  // Leave takes the violet, holiday the blue. Holiday is company-wide and
  // predictable; leave belongs to the person and is what a reader acts on.
  leave:     { bg: '#F4EFFE', border: '#E4D9FC', ink: '#5B21B6', dot: '#7C3AED', bw: 1, label: 'Leave'        },
  holiday:   { bg: '#EEF3FD', border: '#DCE6FA', ink: '#1F3B73', dot: '#2B54CE', bw: 1, label: 'Holiday'      },
  weekend:   { bg: '#F4F6F9', border: '#EDF0F5', ink: '#8A93A0', dot: '',        bw: 1, label: 'Weekend'      },
  // A working day still ahead of us is NOT missing and NOT a weekend. Mig 729
  // forbids recording most types in advance, so colouring it as a gap would be
  // scolding someone for obeying the rules.
  future:    { bg: '#FCFDFE', border: '#F1F4F8', ink: '#B0B9C6', dot: '',        bw: 1, label: 'Not yet due'  },
  // NOT a calendar state any more -- classify() never returns it, so it never
  // reaches the legend. It survives only as the project accent on page 2
  // (accentFor), which is a per-ENTRY vocabulary rather than a per-day one.
  working:   { bg: '#F4F8FF', border: '#DAE6FA', ink: '#1E40AF', dot: '#2563EB', bw: 1, label: 'Working'      },
} as const;
export type DayStateKey = keyof typeof dayState;

/** Bars are coloured by rank so the same project keeps the same colour across
 *  the project table and the activity chart. */
export const rankColors = ['#2563EB', '#7C3AED', '#0F766E', '#10B981', '#F59E0B', '#F97316', '#9CA3AF'];

export const styles = StyleSheet.create({
  // ── page ────────────────────────────────────────────────────────────
  page: {
    paddingTop: 0, paddingBottom: 46, paddingHorizontal: 0,
    fontSize: 9, color: colors.ink2, fontFamily: 'Helvetica',
    backgroundColor: colors.white,
  },
  body: { paddingHorizontal: 34 },

  // ── header band ─────────────────────────────────────────────────────
  headerBand: { backgroundColor: colors.blue, paddingHorizontal: 34, paddingVertical: 18, marginBottom: 18 },
  headerTop:  { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'flex-start' },
  headerTitle:{ color: colors.white, fontSize: 17, fontFamily: 'Helvetica-Bold', letterSpacing: -0.3 },
  headerSub:  { color: '#BFDBFE', fontSize: 10, marginTop: 3 },
  headerMeta: { color: '#93C5FD', fontSize: 7.5, marginTop: 9 },
  chip:       { paddingHorizontal: 9, paddingVertical: 4, borderRadius: 9, fontSize: 7.5, fontFamily: 'Helvetica-Bold' },
  // Right column, under the status chip. alignSelf keeps the white chip the
  // width of the logo instead of stretching a slab across the band, and putting
  // it here costs no vertical space at all: the space beside the title was
  // already empty, whereas above the title it pushed the whole band taller.
  headerRight:{ alignItems: 'flex-end' },
  logoChip:   { alignSelf: 'flex-end', backgroundColor: colors.white, borderRadius: 4,
                paddingVertical: 4, paddingHorizontal: 7 },
  // 16pt. The band's height is set by the three lines of text on the left
  // (~47pt), so the right column has room well past this before it binds.
  logoImg:    { height: 16 },
  // The status chip sits UNDER the logo, so it carries the gap. When there is
  // no logo it is the only thing in the column and must not be pushed down.
  chipBelow:  { marginTop: 8 },

  // ── section furniture ───────────────────────────────────────────────
  section:      { marginBottom: 16 },
  sectionTitle: { fontSize: 10, fontFamily: 'Helvetica-Bold', color: colors.ink, marginBottom: 7 },
  sectionRule:  { borderBottomWidth: 1, borderBottomColor: colors.border, borderBottomStyle: 'solid', marginBottom: 8 },
  muted:        { color: colors.ink3 },
  tiny:         { fontSize: 7.5, color: colors.ink4 },

  // ── page 2: day groups and entry cards ──────────────────────────────
  // The mockup repeats the PROJECT / ACTIVITY / HOURS micro-labels inside every
  // card. On a web page that is free; on A4 it is three extra label rows per
  // entry, and a 31-day month would run to twice the pages. They appear ONCE
  // per day here instead, directly under the date, which keeps the mockup's
  // reading order without paying for it on every row.
  dayHead:    { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center',
                marginTop: 13, marginBottom: 5 },
  dayName:    { fontSize: 10, fontFamily: 'Helvetica-Bold', color: colors.ink },
  // The holiday-name chip. Blue, because HOLIDAY is blue everywhere now.
  dayTag:     { fontSize: 7, fontFamily: 'Helvetica-Bold', color: '#1F3B73',
                backgroundColor: '#EEF3FD', paddingHorizontal: 6, paddingVertical: 2,
                borderRadius: 7, marginLeft: 7 },
  dayChip:    { fontSize: 7.5, fontFamily: 'Helvetica-Bold', paddingHorizontal: 8,
                paddingVertical: 3, borderRadius: 8 },

  colLbls:    { flexDirection: 'row', paddingHorizontal: 10, paddingBottom: 3 },
  colLbl:     { fontSize: 6.5, color: colors.ink4, fontFamily: 'Helvetica-Bold', letterSpacing: 0.6 },

  card:       { flexDirection: 'row', borderWidth: 1, borderColor: colors.border,
                borderStyle: 'solid', borderRadius: 5, marginBottom: 4,
                backgroundColor: colors.white },
  cardAccent: { width: 3, borderTopLeftRadius: 4, borderBottomLeftRadius: 4 },
  cardBody:   { flexGrow: 1, paddingVertical: 7, paddingHorizontal: 9 },
  cardRow:    { flexDirection: 'row', alignItems: 'flex-start' },
  cardProj:   { fontSize: 9.5, fontFamily: 'Helvetica-Bold', color: colors.ink },
  cardAct:    { fontSize: 9, color: colors.ink2, marginBottom: 1 },
  cardActNil: { fontSize: 9, color: colors.ink4 },
  cardHrs:    { fontSize: 9.5, fontFamily: 'Helvetica-Bold', color: colors.ink, textAlign: 'right' },
  // The activities column is a two-column list of its own: name left, hours
  // right-aligned, a hairline between each. The question this block gets asked
  // is "do these add up?", which is arithmetic, and arithmetic needs a column.
  // No rule between activities. The card is already a bordered box with a
  // coloured edge, and the hours column already aligns — a line across the
  // middle of that is a third fence round one field. The hairline was added to
  // separate them, then darkened because it was invisible; deleting it is the
  // only fix that removes something instead of adding a mark to cover a mark.
  actLine:    { flexDirection: 'row', alignItems: 'flex-start', paddingVertical: 3.5 },
  actName:    { width: '68%', fontSize: 9, color: colors.ink2, paddingRight: 6 },
  actMins:    { width: '32%', fontSize: 8.5, fontFamily: 'Helvetica-Bold', color: colors.ink3,
                textAlign: 'right' },
  actMinsNil: { width: '32%', fontSize: 8.5, color: colors.ink4, textAlign: 'right' },

  cardNoteWrap: { borderTopWidth: 1, borderTopColor: '#F3F4F6', borderTopStyle: 'solid',
                  marginTop: 6, paddingTop: 5 },
  cardNote:   { fontSize: 8, color: colors.ink3 },

  // Pale blue, with the strong #DBEAFE reserved for the MONTH total. On a page
  // with six day groups, giving both the same fill would leave the month total
  // indistinguishable from the six above it.
  dayTotal:   { flexDirection: 'row', justifyContent: 'flex-end', alignItems: 'center',
                backgroundColor: '#F2F6FF', borderRadius: 5,
                borderTopWidth: 1, borderTopColor: '#DCE6FA', borderTopStyle: 'solid',
                paddingVertical: 6, paddingHorizontal: 11 },
  dayTotalLbl:{ fontSize: 7, color: colors.blue, fontFamily: 'Helvetica-Bold', letterSpacing: 0.6,
                marginRight: 10 },
  dayTotalVal:{ fontSize: 10, fontFamily: 'Helvetica-Bold', color: colors.blue },

  monthTotal: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center',
                marginTop: 16, paddingVertical: 9, paddingHorizontal: 12,
                backgroundColor: colors.blueLt, borderRadius: 5 },
  monthTotalLbl: { fontSize: 9, fontFamily: 'Helvetica-Bold', color: colors.blue },
  monthTotalVal: { fontSize: 11, fontFamily: 'Helvetica-Bold', color: colors.blue },

  // ── section heading: blue rule-bar, uppercase title, hairline under ──
  secHead:   { flexDirection: 'row', alignItems: 'center', marginBottom: 6 },
  secBar:    { width: 3, height: 11, backgroundColor: colors.blueMid, borderRadius: 1.5, marginRight: 7 },
  secTitle:  { fontSize: 9, fontFamily: 'Helvetica-Bold', color: colors.blue, letterSpacing: 1.1 },
  // Where a chart says what its 100% actually is. Without it a bar labelled
  // 38% reads as 38% of the month, which it is not.
  secSub:    { fontSize: 7.5, color: colors.ink4, marginLeft: 9 },
  secRule:   { borderBottomWidth: 1, borderBottomColor: colors.headRule, borderBottomStyle: 'solid',
               marginBottom: 11 },
  secWrap:   { marginBottom: 11 },
  // The summary page only. 11pt between two charts is the same gap as the one
  // INSIDE a chart, so nothing tells the eye where a section ends — but raising
  // secWrap itself moved every section on every page and cost the document two
  // pages, most of them on the info grid and the calendar, which are not
  // charts and were never crowded.
  secGap:    { marginBottom: 24 },

  // ── boxed info grid ─────────────────────────────────────────────────
  infoBox:   { borderWidth: 1, borderColor: colors.rule, borderStyle: 'solid', borderRadius: 7 },
  infoRow:   { flexDirection: 'row' },
  infoCellB: { width: '50%', paddingVertical: 9, paddingHorizontal: 12 },
  infoLblB:  { fontSize: 6.5, color: colors.ink4, fontFamily: 'Helvetica-Bold', letterSpacing: 0.8,
               marginBottom: 3 },
  infoValB:  { fontSize: 10, color: colors.ink, fontFamily: 'Helvetica-Bold' },

  // ── KPI cards with a coloured top rail ──────────────────────────────
  kpiGrid:   { flexDirection: 'row', flexWrap: 'wrap', marginHorizontal: -3.5 },
  kpiSlot:   { width: '25%', paddingHorizontal: 3.5, marginBottom: 7 },
  kpiBox:    { borderWidth: 1, borderColor: colors.rule, borderStyle: 'solid', borderRadius: 7,
               backgroundColor: colors.white, overflow: 'hidden' },
  kpiRail:   { height: 3 },
  kpiPad:    { paddingVertical: 8, paddingHorizontal: 11 },
  kpiHead:   { flexDirection: 'row', alignItems: 'center' },
  kpiLblB:   { fontSize: 6.5, color: colors.ink4, fontFamily: 'Helvetica-Bold', letterSpacing: 0.8,
               marginLeft: 5 },
  kpiValB:   { fontSize: 18, fontFamily: 'Helvetica-Bold', marginTop: 4 },
  kpiUnit:   { fontSize: 9, fontFamily: 'Helvetica-Bold' },
  kpiSubB:   { fontSize: 7, color: colors.ink4, marginTop: 4 },

  // ── boxed calendar ──────────────────────────────────────────────────
  calHeadB:  { flexDirection: 'row', marginBottom: 4 },
  calHeadC:  { width: '12.2%', textAlign: 'center', fontSize: 6.5, color: colors.ink4,
               fontFamily: 'Helvetica-Bold', letterSpacing: 0.8 },
  calRowB:   { flexDirection: 'row', marginBottom: 2, alignItems: 'stretch' },
  calSlot:   { width: '12.2%', paddingHorizontal: 1.5 },
  calBox:    { borderWidth: 1, borderStyle: 'solid', borderRadius: 5, height: 33,
               paddingTop: 3.5, paddingBottom: 2.5, alignItems: 'center', justifyContent: 'flex-start' },
  calDayB:   { fontSize: 9, fontFamily: 'Helvetica-Bold' },
  calHrsB:   { fontSize: 6.5, marginTop: 1.5 },
  calDot:    { width: 3, height: 3, borderRadius: 1.5, marginTop: 2.5 },
  // The over-plan delta replaces the dot rather than joining it. On a 36pt cell
  // there is room for one mark, and "+2h" says everything the dot did and more.
  calDelta:  { fontSize: 6, fontFamily: 'Helvetica-Bold', marginTop: 1.5 },

  // Eighth column: what the row adds up to. Puts the shape of the month on
  // page 1 without a second chart of the same data.
  calWkHead: { width: '14.6%', textAlign: 'right', fontSize: 6.5, color: colors.ink4,
               fontFamily: 'Helvetica-Bold', letterSpacing: 0.8, paddingRight: 2 },
  calWkSlot: { width: '14.6%', paddingLeft: 6, paddingRight: 2, justifyContent: 'center' },
  calWkVal:  { fontSize: 8, fontFamily: 'Helvetica-Bold', textAlign: 'right' },
  calWkSub:  { fontSize: 6, textAlign: 'right', marginTop: 1 },
  // The legend IS the swatch: each pill is painted in the state it names, in the
  // same fill and border the grid uses. A grey chip beside a coloured square
  // asks the reader to match two things; this one is the thing.
  // TIGHTENED for the EIGHTH state. Splitting on-plan from under-plan added a
  // pill, the row gained a line, and page 1 -- which has been at its ceiling
  // since the KPI tiles landed -- pushed the last pill onto a page of its own.
  // Page 1 has no spare height, so the pills give up the width instead.
  legend:    { flexDirection: 'row', flexWrap: 'wrap', alignItems: 'center', marginTop: 8 },
  legendPill:{ flexDirection: 'row', alignItems: 'center', marginRight: 6, marginBottom: 3.5,
               paddingVertical: 3, paddingHorizontal: 7, borderRadius: 9,
               borderWidth: 1, borderStyle: 'solid' },
  legendTx:  { fontSize: 7.5, fontFamily: 'Helvetica-Bold', letterSpacing: 0.15 },

  // ── weekly cards with a vertical bar ────────────────────────────────
  wkGrid:    { flexDirection: 'row', marginHorizontal: -4 },
  wkSlot:    { paddingHorizontal: 4 },
  wkBox:     { borderWidth: 1, borderColor: colors.rule, borderStyle: 'solid', borderRadius: 7,
               backgroundColor: '#FBFBFC', paddingTop: 11, paddingBottom: 11, paddingHorizontal: 8,
               alignItems: 'center' },
  wkLbl:     { fontSize: 6.5, color: colors.ink4, fontFamily: 'Helvetica-Bold', letterSpacing: 0.7,
               textAlign: 'center', marginBottom: 8 },
  wkBarWrap: { width: 26, height: 62, justifyContent: 'flex-end', marginBottom: 8 },
  wkBar:     { width: 26, borderTopLeftRadius: 3, borderTopRightRadius: 3 },
  // The week's PLANNED hours, behind the bar. Without it "32.0" is a number
  // with nothing to be measured against, and the colour has to carry the whole
  // story on its own.
  wkGhost:   { position: 'absolute', bottom: 0, left: 0, width: 26,
               backgroundColor: '#E6E8EC', borderTopLeftRadius: 3, borderTopRightRadius: 3 },
  wkVal:     { fontSize: 16, fontFamily: 'Helvetica-Bold' },
  wkSub:     { fontSize: 6.5, color: colors.ink4, marginTop: 3, textAlign: 'center' },

  // ── light table (project summary) ───────────────────────────────────
  ltHead:    { flexDirection: 'row', backgroundColor: '#F7F8FA', paddingVertical: 7,
               paddingHorizontal: 10, borderTopLeftRadius: 5, borderTopRightRadius: 5 },
  ltHeadC:   { fontSize: 6.5, color: colors.ink3, fontFamily: 'Helvetica-Bold', letterSpacing: 0.8 },
  ltRow:     { flexDirection: 'row', alignItems: 'center', paddingVertical: 9, paddingHorizontal: 10,
               borderBottomWidth: 1, borderBottomColor: '#F1F2F5', borderBottomStyle: 'solid' },
  ltName:    { fontSize: 9.5, fontFamily: 'Helvetica-Bold', color: colors.ink },
  ltTxt:     { fontSize: 8.5, color: colors.ink2 },
  ltHrs:     { fontSize: 9.5, fontFamily: 'Helvetica-Bold', color: colors.blueMid },
  ltPct:     { fontSize: 8.5, color: colors.ink3, textAlign: 'right' },
  ltTotal:   { flexDirection: 'row', justifyContent: 'flex-end', alignItems: 'center',
               paddingTop: 7, paddingHorizontal: 10 },
  ltTotalL:  { fontSize: 8.5, color: colors.ink3, marginRight: 12 },
  ltTotalV:  { fontSize: 12, fontFamily: 'Helvetica-Bold', color: colors.ink },
  track:     { height: 7, backgroundColor: '#E6E8EC', borderRadius: 3.5 },
  fill:      { height: 7, borderRadius: 3.5 },

  // ── activity bars: label above, bar the full width ──────────────────
  // Two facts a row over eight-plus rows is a chart, and now looks like one. A
  // name pinned to 21% of the width squeezed the track and wrapped long names;
  // at full width the difference between 30% and 4% is visible rather than
  // inferred.
  actStack:  { paddingTop: 6, paddingBottom: 8,
               borderBottomWidth: 1, borderBottomColor: '#F1F2F5', borderBottomStyle: 'solid' },
  actTop:    { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'flex-end',
               marginBottom: 4 },
  actName2:  { fontSize: 9.5, fontFamily: 'Helvetica-Bold', color: colors.ink },
  actVals:   { fontSize: 9, fontFamily: 'Helvetica-Bold', color: colors.ink },
  actPct2:   { fontSize: 8, color: colors.ink4 },
  actTrack:  { width: '100%', height: 8, backgroundColor: '#E6E8EC', borderRadius: 4 },
  actFill:   { height: 8, borderRadius: 4 },
  // The hours the chart does NOT cover, named rather than left to vanish.
  restTxt:   { fontSize: 9, color: colors.ink4 },
  // Days active, on the same line as the name. The claim that four facts a
  // row need a table was wrong: three of them fit above the bar and the
  // fourth IS the bar.
  actMeta:   { fontSize: 8, color: colors.ink4 },

  // ── Page 3: a project card with its activities nested inside ──────────
  // A bordered box per project, because the whole point of the nesting is that
  // you can see where one project's hours stop and the next one's start. A rule
  // between them would not do that — the activity lines already have rules.
  pCard:     { borderWidth: 1, borderColor: colors.border, borderRadius: 5,
               marginBottom: 7 },
  pCardHead: { flexDirection: 'row', alignItems: 'center',
               paddingVertical: 5, paddingHorizontal: 8,
               backgroundColor: '#FAFBFC',
               borderBottomWidth: 1, borderBottomColor: colors.border },
  pDot:      { width: 6, height: 6, borderRadius: 2, marginRight: 6 },
  pName:     { flex: 1, fontSize: 9.5, fontFamily: 'Helvetica-Bold', color: colors.ink },
  pDays:     { fontSize: 7.5, color: colors.ink4, marginRight: 10 },
  pHrs:      { fontSize: 9.5, fontFamily: 'Helvetica-Bold', color: colors.ink, marginRight: 8 },
  pPct:      { fontSize: 8, color: colors.ink3, width: 26, textAlign: 'right' },

  pActs:     { paddingHorizontal: 8, paddingTop: 2, paddingBottom: 6 },
  pActRow:   { paddingTop: 5 },
  pActTop:   { flexDirection: 'row', alignItems: 'baseline' },
  pActNo:    { fontSize: 7.5, color: colors.ink4, width: 12 },
  pActName:  { flex: 1, fontSize: 8.5, color: colors.ink2 },
  // The remainder row is a caveat, not a finding. Grey, so it never reads as
  // something a person typed into the app.
  pActNameQ: { flex: 1, fontSize: 8.5, color: colors.ink4 },
  pActHrs:   { fontSize: 8.5, fontFamily: 'Helvetica-Bold', color: colors.ink },
  pActHrsQ:  { fontSize: 8.5, color: colors.ink3 },
  // The indent lives on a WRAPPER, not on the track. width:'100%' resolves
  // against the parent's content box and marginLeft is applied afterwards, so
  // putting both on one View made every bar overrun the card border by exactly
  // the indent — visible only once rasterised, which is the whole argument for
  // rendering these before shipping them.
  pActBar:   { paddingLeft: 12, marginTop: 3 },
  // Slimmer than the project bars above it: a hierarchy you can see without
  // reading. width '100%' and never flex — a track inside a COLUMN parent
  // solved on the wrong axis once already and rendered as a hairline.
  pActTrack: { width: '100%', height: 3, backgroundColor: '#EDEFF2', borderRadius: 2 },
  pActFill:  { height: 3, borderRadius: 2 },

  // ── Page 3: non-project attendance, named ─────────────────────────────
  npWrap:    { marginTop: 4, paddingTop: 7, borderTopWidth: 1, borderTopColor: colors.border },
  npHead:    { fontSize: 7, letterSpacing: 0.7, color: colors.ink4,
               fontFamily: 'Helvetica-Bold', marginBottom: 4 },
  npRow:     { flexDirection: 'row', alignItems: 'center', paddingVertical: 2.5 },
  npDot:     { width: 5, height: 5, borderRadius: 2.5, marginRight: 7 },
  npName:    { flex: 1, fontSize: 8.5, color: colors.ink3 },
  npHrs:     { fontSize: 8.5, color: colors.ink2, fontFamily: 'Helvetica-Bold' },

  // ── Marking rows that post-date the approval ──────────────────────────
  // Amber, the same alert colour used everywhere else, and the label carries
  // the meaning. Colour alone could be mistaken for the over-plan day chip at
  // the top of the group; "ADDED" cannot.
  chgTag:    { fontSize: 6.5, fontFamily: 'Helvetica-Bold', letterSpacing: 0.4,
               color: '#92400E', backgroundColor: '#FEF6DC',
               borderWidth: 0.5, borderColor: '#F6E2A0',
               borderRadius: 3, paddingVertical: 1.5, paddingHorizontal: 4,
               marginTop: 3, alignSelf: 'flex-start' },
  // A wash rather than a fill: enough to find when scanning a page of cards,
  // not enough to fight the text sitting on it.
  cardChg:   { backgroundColor: '#FFFCF4', borderColor: '#F6E2A0' },
  // NOT `legend` — that name is taken by the calendar's legend pills on page 1,
  // and an object literal keeps the LAST value, so reusing it would have
  // silently restyled them from three sections away.
  chgLegend: { flexDirection: 'row', alignItems: 'center', marginBottom: 7 },
  chgLegTxt: { fontSize: 7.5, color: colors.ink3 },

  // ── Page 3: weekly progress, one row per week ─────────────────────────
  // Mirrors the on-screen panel rather than inventing a second vocabulary for
  // the same four facts. The tall bar cards it replaced showed only the weeks
  // that had hours in them, so a month's empty weeks — the ones a reviewer is
  // looking for — were the ones it left out.
  // 3pt not 4: six rows at 4 cost the approval block its place on this page and
  // sent it to a sheet of its own carrying one strip and a footer.
  wkRow:     { flexDirection: 'row', alignItems: 'center', paddingVertical: 3,
               borderTopWidth: 1, borderTopColor: '#F1F2F5' },
  wkRow1:    { flexDirection: 'row', alignItems: 'center', paddingVertical: 3 },
  wkName:    { width: 74, fontSize: 8.5, fontFamily: 'Helvetica-Bold', color: colors.ink2 },
  wkHol:     { fontSize: 7, color: '#7C3AED' },
  wkTrack:   { flex: 1, height: 5, backgroundColor: '#F1F2F5', borderRadius: 3,
               flexDirection: 'row', overflow: 'hidden', marginHorizontal: 10 },
  wkFill:    { height: 5 },
  wkHrs:     { width: 62, textAlign: 'right', fontSize: 8.5,
               fontFamily: 'Helvetica-Bold', color: colors.ink2 },
  wkPlan:    { fontSize: 8, color: colors.ink4, fontFamily: 'Helvetica' },
  wkTag:     { fontSize: 7, fontFamily: 'Helvetica-Bold', paddingVertical: 1.5,
               paddingHorizontal: 5, borderRadius: 3, overflow: 'hidden' },
  wkTagWrap: { width: 66, alignItems: 'flex-end', marginLeft: 8 },
  wkDates:   { width: 60, textAlign: 'right', fontSize: 7.5, color: colors.ink4, marginLeft: 6 },
  wkDefer:   { fontSize: 8, color: colors.ink4, marginHorizontal: 10 },

  // ── Page 3: the month donut ───────────────────────────────────────────
  dnWrap:    { flexDirection: 'row', alignItems: 'center' },
  dnLeg:     { flex: 1, marginLeft: 14, flexDirection: 'row', flexWrap: 'wrap' },
  dnCol:     { width: '50%', paddingRight: 14 },
  dnRow:     { flexDirection: 'row', alignItems: 'center', paddingVertical: 2 },
  dnDot:     { width: 6, height: 6, borderRadius: 2, marginRight: 7 },
  dnName:    { flex: 1, fontSize: 8.5, color: colors.ink2 },
  dnNameQ:   { flex: 1, fontSize: 8.5, color: colors.ink3 },
  dnHrs:     { fontSize: 8.5, fontFamily: 'Helvetica-Bold', color: colors.ink, marginRight: 8 },
  dnPct:     { width: 24, textAlign: 'right', fontSize: 8, color: colors.ink4 },


  docLine:   { textAlign: 'center', fontSize: 7, color: colors.ink4, marginTop: 5 },

  // ── info grid ───────────────────────────────────────────────────────
  infoGrid: { flexDirection: 'row', flexWrap: 'wrap' },
  infoCell: { width: '50%', paddingVertical: 5, paddingRight: 12 },
  infoLbl:  { fontSize: 7, color: colors.ink4, fontFamily: 'Helvetica-Bold', letterSpacing: 0.5, marginBottom: 2 },
  infoVal:  { fontSize: 9.5, color: colors.ink },

  // ── KPI cards ───────────────────────────────────────────────────────
  kpiRow:   { flexDirection: 'row', flexWrap: 'wrap', marginHorizontal: -3 },
  kpiCard:  {
    width: '25%', paddingHorizontal: 3, marginBottom: 6,
  },
  kpiInner: {
    borderWidth: 1, borderColor: colors.border, borderStyle: 'solid', borderRadius: 5,
    backgroundColor: colors.surface, paddingVertical: 8, paddingHorizontal: 9,
  },
  kpiLbl:   { fontSize: 6.5, color: colors.ink4, fontFamily: 'Helvetica-Bold', letterSpacing: 0.4, marginBottom: 3 },
  kpiVal:   { fontSize: 13, fontFamily: 'Helvetica-Bold', color: colors.ink },
  kpiSub:   { fontSize: 6.5, color: colors.ink4, marginTop: 2 },

  // ── calendar grid ───────────────────────────────────────────────────
  calHead:  { flexDirection: 'row', marginBottom: 3 },
  calHeadCell: { width: '14.28%', textAlign: 'center', fontSize: 6.5, color: colors.ink4, fontFamily: 'Helvetica-Bold' },
  calRow:   { flexDirection: 'row' },
  calCell:  {
    width: '14.28%', height: 34, borderWidth: 0.5, borderColor: colors.border, borderStyle: 'solid',
    padding: 3, justifyContent: 'space-between',
  },
  calDay:   { fontSize: 7, fontFamily: 'Helvetica-Bold' },
  calHrs:   { fontSize: 6.5, textAlign: 'right' },

  // ── tables ──────────────────────────────────────────────────────────
  th: {
    flexDirection: 'row', backgroundColor: colors.blue, paddingVertical: 5, paddingHorizontal: 4,
  },
  thCell: { color: colors.white, fontSize: 7, fontFamily: 'Helvetica-Bold', letterSpacing: 0.3 },
  tr: {
    flexDirection: 'row', paddingVertical: 4, paddingHorizontal: 4,
    borderBottomWidth: 0.5, borderBottomColor: colors.border, borderBottomStyle: 'solid',
  },
  trAlt:  { backgroundColor: colors.surface },
  trMute: { backgroundColor: '#FCFCFD' },
  td:     { fontSize: 7.5, color: colors.ink2 },
  tdMute: { fontSize: 7.5, color: colors.ink4 },
  totalRow: {
    flexDirection: 'row', paddingVertical: 6, paddingHorizontal: 4,
    borderTopWidth: 1, borderTopColor: colors.ink3, borderTopStyle: 'solid',
    backgroundColor: colors.blueLt,
  },
  totalCell: { fontSize: 8, fontFamily: 'Helvetica-Bold', color: colors.blue },

  // ── bar chart ───────────────────────────────────────────────────────
  barRow:   { flexDirection: 'row', alignItems: 'center', marginBottom: 5 },
  barLbl:   { width: '28%', fontSize: 8, color: colors.ink2 },
  barTrack: { flex: 1, height: 9, backgroundColor: colors.surface, borderRadius: 4, marginHorizontal: 6 },
  barFill:  { height: 9, backgroundColor: colors.blueMid, borderRadius: 4 },
  barVal:   { width: '17%', fontSize: 7.5, textAlign: 'right', color: colors.ink3 },

  // ── approval stamp ──────────────────────────────────────────────────
  stamp: {
    flexDirection: 'row', borderWidth: 1, borderColor: colors.border, borderStyle: 'solid',
    borderRadius: 6, backgroundColor: colors.white, overflow: 'hidden', marginTop: 10,
  },
  stampAccent: { width: 4 },
  stampBody:   { flexDirection: 'row', flex: 1, paddingVertical: 7, paddingHorizontal: 12, alignItems: 'center' },
  stampCol:    { paddingRight: 12 },
  stampDiv:    { width: 1, alignSelf: 'stretch', backgroundColor: colors.border, marginRight: 12 },
  stampLbl:    { fontSize: 6.5, color: colors.ink4, fontFamily: 'Helvetica-Bold', letterSpacing: 0.4 },
  stampVal:    { fontSize: 8, color: colors.ink2, marginTop: 2 },
  stampMark:   { fontSize: 9, fontFamily: 'Helvetica-Bold' },
  // Five columns only fit if the labels stop competing for the same points.
  stampLbl2:   { fontSize: 6, color: colors.ink4, fontFamily: 'Helvetica-Bold', letterSpacing: 0.3 },
  stampVal2:   { fontSize: 7.5, color: colors.ink2, marginTop: 2 },
  stampMark2:  { fontSize: 8.5, fontFamily: 'Helvetica-Bold' },

  // ── footer ──────────────────────────────────────────────────────────
  footer: {
    position: 'absolute', bottom: 18, left: 34, right: 34,
    flexDirection: 'row', justifyContent: 'space-between',
    borderTopWidth: 0.5, borderTopColor: colors.border, borderTopStyle: 'solid', paddingTop: 6,
  },
  footerTxt: { fontSize: 6.5, color: colors.ink4 },
  endLine:   { textAlign: 'center', fontSize: 8, color: colors.ink4, marginTop: 10 },

  // ── summary matrix (page 2 of the Summary report) ───────────────────
  // Deliberately borderless. The Detail report earns its boxes — each card is
  // a discrete entry — but a 31-row grid with rules between every cell reads
  // as a spreadsheet someone pasted into a report. Alignment and one hairline
  // per row do the same work; see Page2Summary.
  mxHero:     { flexDirection: 'row', alignItems: 'center', borderWidth: 1,
                borderColor: '#E7EBF1', borderStyle: 'solid', borderRadius: 6,
                paddingVertical: 8, marginBottom: 12 },
  mxHeroCell: { paddingHorizontal: 14, borderRightWidth: 1, borderRightColor: '#EEF1F5',
                borderRightStyle: 'solid' },
  mxHeroLbl:  { fontSize: 5.8, fontFamily: 'Helvetica-Bold', color: '#94A0B0', letterSpacing: 0.9 },
  mxHeroVal:  { fontSize: 14, fontFamily: 'Helvetica-Bold', color: colors.ink, marginTop: 2 },
  mxHeroBar:  { flexGrow: 1, paddingHorizontal: 14 },
  mxHeroCap:  { fontSize: 6.2, color: '#94A0B0', marginTop: 5 },

  mxTrack:     { height: 5, backgroundColor: '#EEF1F5', borderRadius: 2.5 },
  mxTrackFill: { height: 5, borderRadius: 2.5 },

  mxHead:     { flexDirection: 'row', alignItems: 'flex-end', paddingBottom: 4,
                borderBottomWidth: 1.2, borderBottomColor: '#0F172A', borderBottomStyle: 'solid' },
  mxHeadDay:  { fontSize: 5.8, fontFamily: 'Helvetica-Bold', color: '#94A0B0', letterSpacing: 0.9 },
  mxHeadCol:  { fontSize: 6.8, fontFamily: 'Helvetica-Bold', color: '#475569', textAlign: 'right' },
  mxHeadMeta: { fontSize: 5.8, fontFamily: 'Helvetica-Bold', color: '#94A0B0', letterSpacing: 0.9,
                textAlign: 'right' },
  mxDot:      { width: 4, height: 4, borderRadius: 2, marginBottom: 2.5 },

  mxRow:      { flexDirection: 'row', alignItems: 'center',
                borderBottomWidth: 0.5, borderBottomColor: '#F2F4F7', borderBottomStyle: 'solid' },
  mxDow:      { fontSize: 6.6, marginRight: 3 },
  mxDayNum:   { fontSize: 7.4 },
  mxTag:      { fontSize: 5.4, fontFamily: 'Helvetica-Bold', marginLeft: 5,
                paddingHorizontal: 3, paddingVertical: 1, borderRadius: 2 },
  mxCell:     { fontSize: 7.4, textAlign: 'right', paddingRight: 6 },
  mxTotal:    { fontSize: 7.4, fontFamily: 'Helvetica-Bold', textAlign: 'right', paddingRight: 6 },

  mxBand:     { flexDirection: 'row', alignItems: 'center',
                borderBottomWidth: 0.5, borderBottomColor: '#EDF0F4', borderBottomStyle: 'solid' },
  mxBandLead: { fontSize: 5.8, fontFamily: 'Helvetica-Bold', letterSpacing: 0.9 },
  mxBandTxt:  { fontSize: 5.8, textAlign: 'center', letterSpacing: 1.4 },

  mxWeek:     { flexDirection: 'row', alignItems: 'center', backgroundColor: '#F4F7FE',
                borderTopWidth: 0.7, borderTopColor: '#C9D8F6', borderTopStyle: 'solid',
                borderBottomWidth: 0.7, borderBottomColor: '#C9D8F6', borderBottomStyle: 'solid' },
  mxWeekLbl:  { fontSize: 7.4, fontFamily: 'Helvetica-Bold', color: colors.blueMid },
  mxWeekRange:{ fontSize: 6, color: '#8FA6DC' },
  mxWeekTot:  { fontSize: 7.4, fontFamily: 'Helvetica-Bold', color: colors.blue,
                textAlign: 'right', paddingRight: 6 },

  mxMonth:     { flexDirection: 'row', alignItems: 'center', backgroundColor: '#101F49' },
  mxMonthLbl:  { fontSize: 6.6, fontFamily: 'Helvetica-Bold', color: '#9FB4E8', letterSpacing: 1.1 },
  mxMonthCell: { fontSize: 7.6, fontFamily: 'Helvetica-Bold', color: colors.white,
                 textAlign: 'right', paddingRight: 6 },
  mxMonthTot:  { fontSize: 9, fontFamily: 'Helvetica-Bold', color: colors.white,
                 textAlign: 'right', paddingRight: 6 },

  mxPips:     { flexDirection: 'row', marginRight: 5 },
  mxPip:      { width: 2.2, height: 6, borderRadius: 0.8, marginRight: 0.9 },
  mxCmpVal:   { fontSize: 7.4, fontFamily: 'Helvetica-Bold', textAlign: 'right' },

  mxKey:      { flexDirection: 'row', marginTop: 9 },
  mxKeyItem:  { flexDirection: 'row', alignItems: 'center', marginRight: 12 },
  mxKeyDot:   { width: 3.6, height: 3.6, borderRadius: 1.8, marginRight: 3.5 },
  mxKeyTxt:   { fontSize: 5.8, color: '#98A2AE' },
});

/**
 * Green / amber / red, and nothing else.
 *
 * A separate map from `dayState` on purpose. dayState answers "what KIND of day
 * is this" — holiday, leave, weekend — for the calendar; this answers "did the
 * hours meet the target". The calendar deliberately has nothing red on it,
 * because on that page over-recording is worth noticing rather than an error.
 * On the summary table the same fact is one of three verdicts in a single
 * column, and needs its own third colour.
 */
export const matrixTone = {
  met:   '#3F6212',
  short: '#B45309',
  over:  '#B91C1C',
} as const;
