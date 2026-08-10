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
} as const;

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
