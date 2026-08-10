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
  holiday: { bg: '#E9F9EF', border: '#BDEACE', ink: '#047857', dot: '#10B981', label: 'Holiday'      },
  leave:   { bg: '#FEF6DC', border: '#F6E2A0', ink: '#92400E', dot: '#F59E0B', label: 'Leave'        },
  over:    { bg: '#FEF0F0', border: '#F8D2D2', ink: '#B91C1C', dot: '#DC2626', label: 'Over planned' },
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
  dayTag:     { fontSize: 7, fontFamily: 'Helvetica-Bold', color: colors.purple,
                backgroundColor: colors.purpleLt, paddingHorizontal: 6, paddingVertical: 2,
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
  cardNoteWrap: { borderTopWidth: 1, borderTopColor: '#F3F4F6', borderTopStyle: 'solid',
                  marginTop: 6, paddingTop: 5 },
  cardNote:   { fontSize: 8, color: colors.ink3 },

  dayTotal:   { flexDirection: 'row', justifyContent: 'flex-end', alignItems: 'center',
                backgroundColor: colors.surface, borderRadius: 5,
                paddingVertical: 6, paddingHorizontal: 11 },
  dayTotalLbl:{ fontSize: 7, color: colors.ink3, fontFamily: 'Helvetica-Bold', letterSpacing: 0.6,
                marginRight: 10 },
  dayTotalVal:{ fontSize: 10, fontFamily: 'Helvetica-Bold', color: colors.ink },

  monthTotal: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center',
                marginTop: 16, paddingVertical: 9, paddingHorizontal: 12,
                backgroundColor: colors.blueLt, borderRadius: 5 },
  monthTotalLbl: { fontSize: 9, fontFamily: 'Helvetica-Bold', color: colors.blue },
  monthTotalVal: { fontSize: 11, fontFamily: 'Helvetica-Bold', color: colors.blue },

  // ── section heading: blue rule-bar, uppercase title, hairline under ──
  secHead:   { flexDirection: 'row', alignItems: 'center', marginBottom: 6 },
  secBar:    { width: 3, height: 11, backgroundColor: colors.blueMid, borderRadius: 1.5, marginRight: 7 },
  secTitle:  { fontSize: 9, fontFamily: 'Helvetica-Bold', color: colors.blue, letterSpacing: 1.1 },
  secRule:   { borderBottomWidth: 1, borderBottomColor: colors.headRule, borderBottomStyle: 'solid',
               marginBottom: 11 },
  secWrap:   { marginBottom: 13 },

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
  kpiPad:    { paddingVertical: 9, paddingHorizontal: 11 },
  kpiLblB:   { fontSize: 6.5, color: colors.ink4, fontFamily: 'Helvetica-Bold', letterSpacing: 0.8 },
  kpiValB:   { fontSize: 18, fontFamily: 'Helvetica-Bold', marginTop: 4 },
  kpiUnit:   { fontSize: 9, fontFamily: 'Helvetica-Bold' },
  kpiSubB:   { fontSize: 7, color: colors.ink4, marginTop: 4 },

  // ── boxed calendar ──────────────────────────────────────────────────
  calHeadB:  { flexDirection: 'row', marginBottom: 4 },
  calHeadC:  { width: '14.285%', textAlign: 'center', fontSize: 6.5, color: colors.ink4,
               fontFamily: 'Helvetica-Bold', letterSpacing: 0.8 },
  calRowB:   { flexDirection: 'row', marginBottom: 2.5 },
  calSlot:   { width: '14.285%', paddingHorizontal: 1.5 },
  calBox:    { borderWidth: 1, borderStyle: 'solid', borderRadius: 5, height: 34,
               paddingTop: 5, paddingBottom: 4, alignItems: 'center', justifyContent: 'flex-start' },
  calDayB:   { fontSize: 9, fontFamily: 'Helvetica-Bold' },
  calHrsB:   { fontSize: 6.5, marginTop: 2 },
  calDot:    { width: 3, height: 3, borderRadius: 1.5, marginTop: 3 },
  legend:    { flexDirection: 'row', flexWrap: 'wrap', alignItems: 'center', marginTop: 8 },
  legendIt:  { flexDirection: 'row', alignItems: 'center', marginRight: 14 },
  legendSw:  { width: 9, height: 9, borderRadius: 2.5, borderWidth: 1, borderStyle: 'solid', marginRight: 5 },
  legendTx:  { fontSize: 7, color: colors.ink3 },

  // ── weekly cards with a vertical bar ────────────────────────────────
  wkGrid:    { flexDirection: 'row', marginHorizontal: -4 },
  wkSlot:    { paddingHorizontal: 4 },
  wkBox:     { borderWidth: 1, borderColor: colors.rule, borderStyle: 'solid', borderRadius: 7,
               backgroundColor: '#FBFBFC', paddingTop: 11, paddingBottom: 11, paddingHorizontal: 8,
               alignItems: 'center' },
  wkLbl:     { fontSize: 6.5, color: colors.ink4, fontFamily: 'Helvetica-Bold', letterSpacing: 0.7,
               textAlign: 'center', marginBottom: 8 },
  wkBarWrap: { height: 62, justifyContent: 'flex-end', marginBottom: 8 },
  wkBar:     { width: 26, borderTopLeftRadius: 3, borderTopRightRadius: 3 },
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
               paddingTop: 10, paddingHorizontal: 10 },
  ltTotalL:  { fontSize: 8.5, color: colors.ink3, marginRight: 12 },
  ltTotalV:  { fontSize: 12, fontFamily: 'Helvetica-Bold', color: colors.ink },
  track:     { height: 7, backgroundColor: '#E6E8EC', borderRadius: 3.5 },
  fill:      { height: 7, borderRadius: 3.5 },

  // ── activity bars ───────────────────────────────────────────────────
  actRow:    { flexDirection: 'row', alignItems: 'center', marginBottom: 9 },
  actLbl:    { width: '21%', fontSize: 9, color: colors.ink2 },
  actTrack:  { width: '100%', height: 9, backgroundColor: '#E6E8EC', borderRadius: 4.5 },
  actFill:   { height: 9, borderRadius: 4.5 },
  actHrs:    { width: '9%', fontSize: 9.5, fontFamily: 'Helvetica-Bold', color: colors.ink,
               textAlign: 'right' },
  actPct:    { width: '8%', fontSize: 8, color: colors.ink4, textAlign: 'right' },

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
    borderRadius: 6, backgroundColor: colors.white, overflow: 'hidden', marginTop: 14,
  },
  stampAccent: { width: 4 },
  stampBody:   { flexDirection: 'row', flex: 1, paddingVertical: 9, paddingHorizontal: 12, alignItems: 'center' },
  stampCol:    { paddingRight: 14 },
  stampDiv:    { width: 1, alignSelf: 'stretch', backgroundColor: colors.border, marginRight: 14 },
  stampLbl:    { fontSize: 6.5, color: colors.ink4, fontFamily: 'Helvetica-Bold', letterSpacing: 0.4 },
  stampVal:    { fontSize: 8, color: colors.ink2, marginTop: 2 },
  stampMark:   { fontSize: 9, fontFamily: 'Helvetica-Bold' },

  // ── footer ──────────────────────────────────────────────────────────
  footer: {
    position: 'absolute', bottom: 18, left: 34, right: 34,
    flexDirection: 'row', justifyContent: 'space-between',
    borderTopWidth: 0.5, borderTopColor: colors.border, borderTopStyle: 'solid', paddingTop: 6,
  },
  footerTxt: { fontSize: 6.5, color: colors.ink4 },
  endLine:   { textAlign: 'center', fontSize: 8, color: colors.ink4, marginTop: 16 },
});
