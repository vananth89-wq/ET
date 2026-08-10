import { View, Text } from '@react-pdf/renderer';
import { styles } from '../utils/pdfStyles';

/**
 * Fixed to the bottom of every page. `render` gives react-pdf the page numbers
 * after pagination, which is the only way to know the total.
 */
export function PDFFooter({ documentId }: { documentId: string }) {
  return (
    <View style={styles.footer} fixed>
      <Text style={styles.footerTxt}>Prowess · Document {documentId}</Text>
      <Text
        style={styles.footerTxt}
        render={({ pageNumber, totalPages }: { pageNumber: number; totalPages: number }) => `Page ${pageNumber} of ${totalPages}`}
      />
    </View>
  );
}
