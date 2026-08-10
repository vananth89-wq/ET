import { View, Text } from '@react-pdf/renderer';
import { styles } from '../utils/pdfStyles';

/**
 * The blue rule-bar + uppercase title + hairline that opens every section.
 * One definition, so four pages cannot drift into three different headings.
 *
 * `sub` is where a chart states its denominator. A bar labelled 38% is read as
 * 38% of the month unless the heading says otherwise — and on this report it
 * never was.
 */
export function SectionHead({ children, sub }: { children: string; sub?: string }) {
  return (
    <>
      <View style={styles.secHead}>
        <View style={styles.secBar} />
        <Text style={styles.secTitle}>{children.toUpperCase()}</Text>
        {sub ? <Text style={styles.secSub}>{sub}</Text> : null}
      </View>
      <View style={styles.secRule} />
    </>
  );
}
