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
  working: { bg: '#F4F8FF', border: '#DAE6FA', ink: '#1E40AF', dot: '#2563EB', label: 'Working'      },
  // Purple, matching getEntryBadge() in MyTimesheet — the app has always drawn
  // HOL purple. The calendar here briefly used green, which also collided with
  // the green page 2 gives non-project attendance.
  holiday: { bg: '#F1ECFD', border: '#DDD0F8', ink: '#5B21B6', dot: '#7C3AED', label: 'Holiday'      },
  // Amber = OVER, and nothing else. It used to mean "leave" here and "short of
  // plan" on page 3 while red meant over — one colour with two opposite senses
  // and one sense with two colours. Nothing on the report is red now: recording
  // more than planned is worth noticing, it is not an error.
  leave:   { bg: '#EEF2F7', border: '#DDE3EB', ink: '#475569', dot: '#64748B', label: 'Leave'        },
  over:    { bg: '#FEF6DC', border: '#F6E2A0', ink: '#92400E', dot: '#F59E0B', label: 'Over planned' },
  missing: { bg: '#FFF8EC', border: '#FAE2BE', ink: '#C2410C', dot: '#F97316', label: 'Missing'      },
  weekend: { bg: '#F7F8FA', border: '#EDEFF2', ink: '#9CA3AF', dot: '',        label: 'Weekend'      },
  // A working day still ahead of us is NOT missing and NOT a weekend. Mig 729
  // forbids recording most types in advance, so colouring it as a gap would be
  // scolding someone for obeying the rules.
  future:  { bg: '#FFFFFF', border: '#EFF1F4', ink: '#C4C9D0', dot: '',        label: 'Not yet due'  },
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
  dayTag:     { fontSize: 7, fontFamily: 'Helvetica-Bold', color: '#5B21B6',
                backgroundColor: '#F1ECFD', paddingHorizontal: 6, paddingVertical: 2,
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
  legend:    { flexDirection: 'row', flexWrap: 'wrap', alignItems: 'center', marginTop: 9 },
  legendPill:{ flexDirection: 'row', alignItems: 'center', marginRight: 9, marginBottom: 4,
               paddingVertical: 3.5, paddingHorizontal: 9, borderRadius: 10,
               borderWidth: 1, borderStyle: 'solid' },
  legendTx:  { fontSize: 8, fontFamily: 'Helvetica-Bold', letterSpacing: 0.2 },

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
});
