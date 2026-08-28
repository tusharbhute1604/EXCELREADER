@isTest
public class XLSXTestFixtureFactory {

    private static final String ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';

    public static Blob generateSyntheticXLSX(Integer rowCount, Integer columnCount) {
        Compression.ZipWriter zip = new Compression.ZipWriter();
        addBoilerplateEntries(zip, false);

        // We will generate the sheet XML manually.
        String sheetXmlStart = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>';

        // Write to Blob iteratively or string builder?
        // Let's use a List<String> to avoid one giant string concat memory blowup during generation.
        // Wait, for 50k rows, memory might blow up during test generation itself if we are not careful.
        // But for testing the ZipReader limits, we just need a big blob.

        // We can create the sheet in chunks to avoid Apex heap limits during creation.
        List<String> sheetParts = new List<String>();
        sheetParts.add(sheetXmlStart);

        for (Integer r = 1; r <= rowCount; r++) {
            String rowStr = '<row r="' + r + '">';
            for (Integer c = 1; c <= columnCount; c++) {
                // simple numeric cell: <c><v>number</v></c>
                rowStr += '<c><v>' + (r * c) + '</v></c>';
            }
            rowStr += '</row>';
            sheetParts.add(rowStr);
        }

        sheetParts.add('</sheetData></worksheet>');
        String finalSheet = String.join(sheetParts, '');
        zip.addEntry('xl/worksheets/sheet1.xml', Blob.valueOf(finalSheet));

        return zip.getArchive();
    }

    /**
     * Builds a synthetic .xlsx from explicit row data - rows[0] is Excel row 1, rows[1] is row 2,
     * etc. Values that parse as a number are written as numeric cells; everything else is written
     * as an inline string cell (t="inlineStr"), so no sharedStrings.xml coordination is needed.
     * Blank/null values are omitted entirely, matching how real Excel typically emits empty cells.
     */
    public static Blob generateXLSXFromRows(List<List<String>> rows) {
        return generateXLSXFromRows(rows, new Set<Integer>(), false);
    }

    /**
     * As above, plus:
     * - hiddenRowNumbers: Excel row numbers (1-indexed) to mark hidden="1", for testing
     *   Hidden_Row_Handling__c = Exclude.
     * - includeTableWithTotals: when true, wraps the full row range in an Excel Table
     *   (xl/tables/table1.xml) with totalsRowCount="1", so the LAST row in `rows` is the
     *   totals row - for testing Totals_Row_Handling__c = Exclude. The caller is responsible
     *   for that last row actually looking like a totals row (e.g. a label + a sum).
     */
    public static Blob generateXLSXFromRows(List<List<String>> rows, Set<Integer> hiddenRowNumbers, Boolean includeTableWithTotals) {
        Compression.ZipWriter zip = new Compression.ZipWriter();
        addBoilerplateEntries(zip, includeTableWithTotals);

        Integer columnCount = 0;
        for (List<String> row : rows) {
            columnCount = Math.max(columnCount, row.size());
        }

        zip.addEntry('xl/worksheets/sheet1.xml', Blob.valueOf(buildSheetXml(rows, hiddenRowNumbers)));

        if (includeTableWithTotals) {
            String lastCol = ALPHABET.substring(Math.max(columnCount - 1, 0), Math.max(columnCount - 1, 0) + 1);
            String tableRef = 'A1:' + lastCol + rows.size();
            zip.addEntry('xl/worksheets/_rels/sheet1.xml.rels', Blob.valueOf(sheetRelsXml()));
            zip.addEntry('xl/tables/table1.xml', Blob.valueOf(tableXml(tableRef)));
        }

        return zip.getArchive();
    }

    private static String buildSheetXml(List<List<String>> rows, Set<Integer> hiddenRowNumbers) {
        List<String> parts = new List<String>();
        parts.add('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>');

        for (Integer r = 0; r < rows.size(); r++) {
            Integer excelRowNum = r + 1;
            List<String> rowValues = rows[r];
            String hiddenAttr = (hiddenRowNumbers != null && hiddenRowNumbers.contains(excelRowNum)) ? ' hidden="1"' : '';

            String rowXml = '<row r="' + excelRowNum + '"' + hiddenAttr + '>';
            for (Integer c = 0; c < rowValues.size(); c++) {
                String rawValue = rowValues[c];
                if (String.isBlank(rawValue)) continue;

                String cellRef = ALPHABET.substring(c, c + 1) + excelRowNum;
                if (isNumericValue(rawValue)) {
                    rowXml += '<c r="' + cellRef + '"><v>' + rawValue + '</v></c>';
                } else {
                    rowXml += '<c r="' + cellRef + '" t="inlineStr"><is><t>' + escapeXml(rawValue) + '</t></is></c>';
                }
            }
            rowXml += '</row>';
            parts.add(rowXml);
        }
        parts.add('</sheetData></worksheet>');
        return String.join(parts, '');
    }

    private static void addBoilerplateEntries(Compression.ZipWriter zip, Boolean includeTableWithTotals) {
        String tableOverride = includeTableWithTotals
            ? '<Override PartName="/xl/tables/table1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.table+xml"/>'
            : '';

        String contentTypes = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
            '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
            '<Default Extension="xml" ContentType="application/xml"/>' +
            '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>' +
            '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>' +
            tableOverride +
            '</Types>';
        zip.addEntry('[Content_Types].xml', Blob.valueOf(contentTypes));

        String rootRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>' +
            '</Relationships>';
        zip.addEntry('_rels/.rels', Blob.valueOf(rootRels));

        String workbook = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">' +
            '<sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets>' +
            '</workbook>';
        zip.addEntry('xl/workbook.xml', Blob.valueOf(workbook));

        String workbookRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>' +
            '</Relationships>';
        zip.addEntry('xl/_rels/workbook.xml.rels', Blob.valueOf(workbookRels));
    }

    private static String sheetRelsXml() {
        return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/table" Target="../tables/table1.xml"/>' +
            '</Relationships>';
    }

    private static String tableXml(String tableRef) {
        return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<table xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" id="1" name="Table1" displayName="Table1" ref="' + tableRef + '" totalsRowCount="1">' +
            '</table>';
    }

    private static Boolean isNumericValue(String value) {
        if (String.isBlank(value)) return false;
        try {
            Decimal.valueOf(value);
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    private static String escapeXml(String value) {
        if (value == null) return '';
        return value.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('"', '&quot;');
    }
}
