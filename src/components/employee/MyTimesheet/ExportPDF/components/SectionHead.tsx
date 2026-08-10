import { View, Text } from '@react-pdf/renderer';
import { styles } from '../utils/pdfStyles';

/**
 * The blue rule-bar + uppercase title + hairline that opens every section.
 * One definition, so four pages cannot drift into three different headings.
 */
export function SectionHead({ children }: { children: string }) {
  return (
    <>
      <View style={styles.secHead}>
        <View style={styles.secBar} />
        <Text style={styles.secTitle}>{children.toUpperCase()}</Text>
      </View>
      <View style={styles.secRule} />
    </>
  );
}
