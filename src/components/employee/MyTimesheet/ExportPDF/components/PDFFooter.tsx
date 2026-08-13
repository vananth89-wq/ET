import { View, Text } from '@react-pdf/renderer';
import { styles } from '../utils/pdfStyles';
import { fmtStamp } from '../utils/dataTransforms';

/**
 * Fixed to the bottom of every page. `render` gives react-pdf the page numbers
 * after pagination, which is the only way to know the total.
 *
 * `generatedAt` is optional so the two reports can differ without a flag day:
 * pass it and the right-hand side carries the generation stamp, which is what
 * an auditor comparing two copies of the same month actually needs — the header
 * band carries it too, but the band is not where anyone looks for provenance.
 */
export function PDFFooter({ documentId, generatedAt }: { documentId: string; generatedAt?: string }) {
  return (
    <View style={styles.footer} fixed>
      <Text style={styles.footerTxt}>Prowess · Document {documentId}</Text>
      <Text
        style={styles.footerTxt}
        render={({ pageNumber, totalPages }: { pageNumber: number; totalPages: number }) =>
          generatedAt
            ? `Generated ${fmtStamp(generatedAt)} · Page ${pageNumber} of ${totalPages}`
            : `Page ${pageNumber} of ${totalPages}`}
      />
    </View>
  );
}
