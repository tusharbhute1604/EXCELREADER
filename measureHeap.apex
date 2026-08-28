// measureHeap.apex
Integer NUM_ROWS = 25000;
Integer NUM_COLS = 10;

System.debug('--- START HEAP MEASUREMENT ---');
System.debug('Initial Heap: ' + Limits.getHeapSize());

// Generate the synthetic XLSX blob
Blob xlsxBlob = XLSXTestFixtureFactory.generateSyntheticXLSX(NUM_ROWS, NUM_COLS);
System.debug('Generated XLSX Blob size: ' + xlsxBlob.size() + ' bytes');
System.debug('Heap after blob generation: ' + Limits.getHeapSize());

// Initialize ZipReader
Compression.ZipReader reader = new Compression.ZipReader(xlsxBlob);
System.debug('Heap after ZipReader initialization: ' + Limits.getHeapSize());

// Verify entry
Compression.ZipEntry entry = reader.getEntry('xl/worksheets/sheet1.xml');
System.debug('Sheet1 Uncompressed Size: ' + entry.getUncompressedSize() + ' bytes');

// Extract
Blob sheetXmlBlob = reader.extract(entry);
System.debug('Heap after extraction to Blob: ' + Limits.getHeapSize());

// Peak Heap simulation (Blob to String)
String sheetXmlString = sheetXmlBlob.toString();
System.debug('Heap after Blob.toString(): ' + Limits.getHeapSize());

// Clear references
sheetXmlString = null;
sheetXmlBlob = null;
reader = null;
xlsxBlob = null;

System.debug('--- END HEAP MEASUREMENT ---');
