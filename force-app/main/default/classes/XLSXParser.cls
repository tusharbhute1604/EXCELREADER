/**
 * Core Parser engine for XLSX files.
 * Purely functional - performs zero DML. Parses the XML strictly to avoid Heap limit exceptions.
 */
public class XLSXParser {

    private static final String DEFAULT_SHEET_PATH = 'xl/worksheets/sheet1.xml';

    private IXLSXRowHandler rowHandler;
    private XLSX_Reader_Config__mdt config;
    private List<String> sharedStrings;
    private Integer totalsRowNumber;

    public XLSXParser(IXLSXRowHandler handler, XLSX_Reader_Config__mdt config) {
        this.rowHandler = handler;
        this.config = config;
        this.sharedStrings = new List<String>();
    }

    /**
     * Cheap pre-check used to decide Sync vs Async routing: returns the UNCOMPRESSED size of the
     * target worksheet entry without extracting/decompressing it. This is the number the heap-risk
     * analysis actually cares about - ContentVersion.ContentSize is the compressed file size, which
     * for repetitive tabular data can be many times smaller than what Blob.toString() will expand to.
     */
    public static Long peekUncompressedSheetSize(Blob xlsxFile) {
        Compression.ZipReader zip = new Compression.ZipReader(xlsxFile);
        String sheetPath = resolveSheetPath(zip);
        Compression.ZipEntry sheetEntry = zip.getEntry(sheetPath);
        if (sheetEntry == null) {
            throw new XLSXParserException('Worksheet ' + sheetPath + ' not found in the archive.');
        }
        return sheetEntry.getUncompressedSize();
    }

    // Blob.toString() needs roughly the uncompressed size again in heap, and actual XML parsing
    // (XmlStreamReader state, the per-row Map<String,String>, the row handler's own accumulation)
    // adds further overhead on top of that - empirically enough that a flat "2x raw size" budget
    // isn't safe. Cap pre-extraction at 40% of the CURRENT context's heap ceiling (6 MB sync / 12 MB
    // async, via Limits.getLimitHeapSize(), so this adapts automatically) rather than a fixed
    // constant, leaving real headroom for that downstream cost. Without this gate at all, a small,
    // highly-compressed file can still force a large decompression before Max_Row_Threshold__c
    // (checked row-by-row, only after the fact) or the Auto-routing peek (only consulted when
    // Execution_Mode__c = Auto, never for an explicit Sync/Async) get a chance to reject it.
    private static final Integer SAFE_HEAP_PERCENT = 40;

    /**
     * Main entry point to process an XLSX Blob.
     */
    public void process(Blob xlsxFile) {
        Compression.ZipReader zip = new Compression.ZipReader(xlsxFile);

        // 1. Load Shared Strings (if any)
        Compression.ZipEntry sharedStringsEntry = zip.getEntry('xl/sharedStrings.xml');
        if (sharedStringsEntry != null) {
            assertSafeToExtract(sharedStringsEntry.getUncompressedSize(), 'xl/sharedStrings.xml');
            Blob sharedStringsBlob = zip.extract(sharedStringsEntry);
            parseSharedStrings(sharedStringsBlob.toString());
            // Clear Blob from memory
            sharedStringsBlob = null;
        }

        // 2. Resolve which sheet part is actually first, per xl/workbook.xml - not a hardcoded name.
        String sheetPath = resolveSheetPath(zip);
        Compression.ZipEntry sheetEntry = zip.getEntry(sheetPath);
        if (sheetEntry == null) {
            throw new XLSXParserException('Worksheet ' + sheetPath + ' not found in the archive.');
        }
        assertSafeToExtract(sheetEntry.getUncompressedSize(), sheetPath);

        // 3. Resolve the Excel Table totals row (if any) for this sheet, so parseSheet can exclude it.
        this.totalsRowNumber = resolveTotalsRowNumber(zip, sheetPath);

        Blob sheetBlob = zip.extract(sheetEntry);
        String sheetXml = sheetBlob.toString();
        // Clear Blob from memory
        sheetBlob = null;

        // 4. Stream Parse the Sheet XML
        parseSheet(sheetXml);

        // 5. Finalize
        this.rowHandler.finishProcessing();
    }

    @TestVisible
    private static void assertSafeToExtract(Long uncompressedSize, String partPath) {
        Long safeThreshold = (Limits.getLimitHeapSize() * SAFE_HEAP_PERCENT) / 100;
        if (uncompressedSize > safeThreshold) {
            throw new XLSXParserException(partPath + ' would decompress to ' + uncompressedSize + ' bytes, which exceeds the safe heap budget for this execution context (' + safeThreshold + ' bytes). This file cannot be processed in this context.');
        }
    }

    /**
     * Parses the sharedStrings.xml file.
     * Shared strings are 0-indexed in the order they appear in <si> tags.
     */
    private void parseSharedStrings(String xmlStr) {
        XmlStreamReader reader = new XmlStreamReader(xmlStr);
        String currentText = '';

        while (reader.hasNext()) {
            if (reader.getEventType() == XmlTag.START_ELEMENT) {
                if (reader.getLocalName() == 't') {
                    // Start of a text node inside <si>
                    reader.next();
                    if (reader.getEventType() == XmlTag.CHARACTERS) {
                        currentText += reader.getText();
                    }
                }
            } else if (reader.getEventType() == XmlTag.END_ELEMENT) {
                if (reader.getLocalName() == 'si') {
                    // End of a string item
                    this.sharedStrings.add(currentText);
                    currentText = ''; // reset
                }
            }
            reader.next();
        }
    }

    /**
     * Streams the main sheet.xml using XmlStreamReader.
     */
    private void parseSheet(String xmlStr) {
        XmlStreamReader reader = new XmlStreamReader(xmlStr);

        Integer currentRowNum = null;
        Map<String, String> currentRowData = new Map<String, String>();
        Boolean currentRowHidden = false;

        String currentCellRef = null;
        String currentCellType = null;
        String currentCellValue = '';
        Boolean insideValueTag = false;

        Integer processedRowCount = 0;
        Boolean excludeHidden = this.config != null && this.config.Hidden_Row_Handling__c == 'Exclude';
        Boolean excludeTotals = this.config != null && this.config.Totals_Row_Handling__c == 'Exclude';
        Integer maxRows = (this.config != null && this.config.Max_Row_Threshold__c != null)
            ? this.config.Max_Row_Threshold__c.intValue()
            : null;

        while (reader.hasNext()) {
            if (reader.getEventType() == XmlTag.START_ELEMENT) {
                String localName = reader.getLocalName();

                if (localName == 'row') {
                    currentRowData = new Map<String, String>();
                    String rowNumStr = getAttributeValue(reader, 'r');
                    if (String.isNotBlank(rowNumStr)) {
                        currentRowNum = Integer.valueOf(rowNumStr);
                    }
                    String hiddenAttr = getAttributeValue(reader, 'hidden');
                    currentRowHidden = (hiddenAttr == '1' || hiddenAttr == 'true');
                } else if (localName == 'c') {
                    currentCellRef = getAttributeValue(reader, 'r');
                    currentCellType = getAttributeValue(reader, 't'); // 's' for shared string
                    currentCellValue = '';
                } else if (localName == 'v' || localName == 'is') {
                    insideValueTag = true;
                }
            } else if (reader.getEventType() == XmlTag.CHARACTERS) {
                if (insideValueTag) {
                    currentCellValue += reader.getText();
                }
            } else if (reader.getEventType() == XmlTag.END_ELEMENT) {
                String localName = reader.getLocalName();

                if (localName == 'v' || localName == 'is') {
                    insideValueTag = false;
                } else if (localName == 'c') {
                    // Resolve value
                    String finalValue = currentCellValue;
                    if (currentCellType == 's' && String.isNotBlank(currentCellValue)) {
                        Integer sharedStringIndex = Integer.valueOf(currentCellValue);
                        if (sharedStringIndex < this.sharedStrings.size()) {
                            finalValue = this.sharedStrings[sharedStringIndex];
                        }
                    }

                    String colLetter = extractColumnLetter(currentCellRef);
                    if (colLetter != null) {
                        currentRowData.put(colLetter, finalValue);
                    }
                } else if (localName == 'row') {
                    // Emit the row to the handler
                    if (!currentRowData.isEmpty() && currentRowNum != null) {
                        processedRowCount++;
                        if (maxRows != null && processedRowCount > maxRows) {
                            throw new XLSXParserException('Row count exceeds the configured Max Row Threshold of ' + maxRows + '.');
                        }

                        Boolean isExcludedHidden = excludeHidden && currentRowHidden;
                        Boolean isExcludedTotals = excludeTotals && this.totalsRowNumber != null && currentRowNum == this.totalsRowNumber;

                        if (!isExcludedHidden && !isExcludedTotals) {
                            this.rowHandler.processRow(currentRowNum, currentRowData);
                        }
                    }
                }
            }
            reader.next();
        }
    }

    private String getAttributeValue(XmlStreamReader reader, String attrName) {
        for (Integer i = 0; i < reader.getAttributeCount(); i++) {
            if (reader.getAttributeLocalName(i) == attrName) {
                return reader.getAttributeValueAt(i);
            }
        }
        return null;
    }

    /**
     * Extracts 'A' from 'A1' or 'AB' from 'AB12'.
     */
    private String extractColumnLetter(String cellRef) {
        if (String.isBlank(cellRef)) return null;

        String letters = '';
        for (Integer i = 0; i < cellRef.length(); i++) {
            String c = cellRef.substring(i, i + 1);
            if (c.isAlpha()) {
                letters += c;
            } else {
                break; // stop at first digit
            }
        }
        return letters;
    }

    /**
     * Extracts 11 from 'D11'.
     */
    private static Integer extractRowNumber(String cellRef) {
        if (String.isBlank(cellRef)) return null;

        Integer i = 0;
        while (i < cellRef.length() && cellRef.substring(i, i + 1).isAlpha()) {
            i++;
        }
        String digits = cellRef.substring(i);
        return String.isNotBlank(digits) ? Integer.valueOf(digits) : null;
    }

    // ==================================================================================
    // Sheet & table resolution (xl/workbook.xml, .rels files, xl/tables/*.xml)
    // ==================================================================================

    /**
     * Resolves the zip entry path of the FIRST sheet listed in xl/workbook.xml, via its
     * relationship in xl/_rels/workbook.xml.rels. Falls back to the conventional
     * xl/worksheets/sheet1.xml if resolution fails at any step (missing parts, unexpected
     * shape) but that entry still exists - a safety net for simple files, not a silent
     * substitute for real resolution.
     */
    private static String resolveSheetPath(Compression.ZipReader zip) {
        try {
            Compression.ZipEntry workbookEntry = zip.getEntry('xl/workbook.xml');
            if (workbookEntry == null) {
                return fallbackSheetPath(zip);
            }

            String firstSheetRelId = findFirstSheetRelId(zip.extract(workbookEntry).toString());
            if (String.isBlank(firstSheetRelId)) {
                return fallbackSheetPath(zip);
            }

            Compression.ZipEntry relsEntry = zip.getEntry(getRelsPathFor('xl/workbook.xml'));
            if (relsEntry == null) {
                return fallbackSheetPath(zip);
            }

            String target = findRelationshipTargetById(zip.extract(relsEntry).toString(), firstSheetRelId);
            if (String.isBlank(target)) {
                return fallbackSheetPath(zip);
            }

            String resolvedPath = resolveRelativePath('xl', target);
            if (zip.getEntry(resolvedPath) == null) {
                return fallbackSheetPath(zip);
            }
            return resolvedPath;
        } catch (Exception e) {
            return fallbackSheetPath(zip);
        }
    }

    private static String fallbackSheetPath(Compression.ZipReader zip) {
        if (zip.getEntry(DEFAULT_SHEET_PATH) != null) {
            return DEFAULT_SHEET_PATH;
        }
        throw new XLSXParserException('Unable to resolve the first worksheet from xl/workbook.xml, and no ' + DEFAULT_SHEET_PATH + ' fallback was found in the archive.');
    }

    /**
     * Parses xl/workbook.xml for the r:id of the first <sheet> element. Matches on attribute
     * LOCAL name 'id' (not full "r:id") so it doesn't matter which namespace prefix the file uses.
     */
    private static String findFirstSheetRelId(String workbookXml) {
        XmlStreamReader reader = new XmlStreamReader(workbookXml);
        while (reader.hasNext()) {
            if (reader.getEventType() == XmlTag.START_ELEMENT && reader.getLocalName() == 'sheet') {
                for (Integer i = 0; i < reader.getAttributeCount(); i++) {
                    if (reader.getAttributeLocalName(i) == 'id') {
                        return reader.getAttributeValueAt(i);
                    }
                }
                return null;
            }
            reader.next();
        }
        return null;
    }

    /**
     * Determines the row number of the Excel Table totals row for this sheet, if one exists.
     * Scope: handles the common case of a single table per sheet. Returns null (no totals row)
     * whenever there's no table, no totals row on the table, or the table metadata can't be read -
     * this is a normal, non-error outcome for the majority of sheets that have no Excel Table at all.
     */
    private static Integer resolveTotalsRowNumber(Compression.ZipReader zip, String sheetPath) {
        try {
            String sheetRelsPath = getRelsPathFor(sheetPath);
            Compression.ZipEntry sheetRelsEntry = zip.getEntry(sheetRelsPath);
            if (sheetRelsEntry == null) {
                return null;
            }

            String tableTarget = findRelationshipTargetByTypeSuffix(zip.extract(sheetRelsEntry).toString(), '/table');
            if (String.isBlank(tableTarget)) {
                return null;
            }

            String sheetDir = sheetPath.contains('/') ? sheetPath.substring(0, sheetPath.lastIndexOf('/')) : '';
            String tablePath = resolveRelativePath(sheetDir, tableTarget);
            Compression.ZipEntry tableEntry = zip.getEntry(tablePath);
            if (tableEntry == null) {
                return null;
            }

            return extractTotalsRowNumber(zip.extract(tableEntry).toString());
        } catch (Exception e) {
            return null;
        }
    }

    /**
     * Reads the root <table ref="A1:D11" totalsRowCount="1"> element and, when a totals row is
     * present, returns the row number of the LAST row in the ref range (where the totals row lives).
     */
    private static Integer extractTotalsRowNumber(String tableXml) {
        XmlStreamReader reader = new XmlStreamReader(tableXml);
        while (reader.hasNext()) {
            if (reader.getEventType() == XmlTag.START_ELEMENT && reader.getLocalName() == 'table') {
                String ref = null;
                String totalsRowCount = null;
                for (Integer i = 0; i < reader.getAttributeCount(); i++) {
                    String attrName = reader.getAttributeLocalName(i);
                    if (attrName == 'ref') {
                        ref = reader.getAttributeValueAt(i);
                    } else if (attrName == 'totalsRowCount') {
                        totalsRowCount = reader.getAttributeValueAt(i);
                    }
                }
                if (totalsRowCount == '1' && String.isNotBlank(ref) && ref.contains(':')) {
                    List<String> parts = ref.split(':');
                    return extractRowNumber(parts[1]);
                }
                return null;
            }
            reader.next();
        }
        return null;
    }

    // ==================================================================================
    // Generic .rels parsing helpers
    // ==================================================================================

    private class RelEntry {
        String relId;
        String relType;
        String target;
    }

    private static List<RelEntry> parseRelationships(String relsXml) {
        List<RelEntry> entries = new List<RelEntry>();
        XmlStreamReader reader = new XmlStreamReader(relsXml);
        while (reader.hasNext()) {
            if (reader.getEventType() == XmlTag.START_ELEMENT && reader.getLocalName() == 'Relationship') {
                RelEntry entry = new RelEntry();
                for (Integer i = 0; i < reader.getAttributeCount(); i++) {
                    String attrName = reader.getAttributeLocalName(i);
                    if (attrName == 'Id') {
                        entry.relId = reader.getAttributeValueAt(i);
                    } else if (attrName == 'Type') {
                        entry.relType = reader.getAttributeValueAt(i);
                    } else if (attrName == 'Target') {
                        entry.target = reader.getAttributeValueAt(i);
                    }
                }
                entries.add(entry);
            }
            reader.next();
        }
        return entries;
    }

    private static String findRelationshipTargetById(String relsXml, String relId) {
        for (RelEntry entry : parseRelationships(relsXml)) {
            if (entry.relId == relId) {
                return entry.target;
            }
        }
        return null;
    }

    private static String findRelationshipTargetByTypeSuffix(String relsXml, String typeSuffix) {
        for (RelEntry entry : parseRelationships(relsXml)) {
            if (entry.relType != null && entry.relType.endsWith(typeSuffix)) {
                return entry.target;
            }
        }
        return null;
    }

    // ==================================================================================
    // Zip path helpers
    // ==================================================================================

    /**
     * The OOXML convention for a part's relationships file: a sibling _rels/<filename>.rels
     * inside the part's own directory. E.g. xl/workbook.xml -> xl/_rels/workbook.xml.rels.
     */
    private static String getRelsPathFor(String partPath) {
        Integer lastSlash = partPath.lastIndexOf('/');
        String dir = lastSlash >= 0 ? partPath.substring(0, lastSlash) : '';
        String fileName = lastSlash >= 0 ? partPath.substring(lastSlash + 1) : partPath;
        return (String.isNotBlank(dir) ? dir + '/' : '') + '_rels/' + fileName + '.rels';
    }

    /**
     * Resolves a relationship Target (which may contain '..' segments) against a base directory
     * into a flat zip entry path. E.g. base 'xl/worksheets', target '../tables/table1.xml' -> 'xl/tables/table1.xml'.
     */
    private static String resolveRelativePath(String baseDir, String target) {
        List<String> resultParts = new List<String>();
        for (String part : baseDir.split('/')) {
            if (String.isNotBlank(part)) {
                resultParts.add(part);
            }
        }
        for (String part : target.split('/')) {
            if (part == '..') {
                if (!resultParts.isEmpty()) {
                    resultParts.remove(resultParts.size() - 1);
                }
            } else if (part == '.' || String.isBlank(part)) {
                // skip
            } else {
                resultParts.add(part);
            }
        }
        return String.join(resultParts, '/');
    }
}
