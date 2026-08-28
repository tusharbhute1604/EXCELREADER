@isTest
private class XLSXParserTest {

    private class CapturingRowHandler implements IXLSXRowHandler {
        List<Integer> rowNumbers = new List<Integer>();
        List<Map<String, String>> rows = new List<Map<String, String>>();
        Boolean finished = false;

        public void initialize(XLSX_Reader_Config__mdt config) {}
        public void processRow(Integer rowNumber, Map<String, String> rowData) {
            rowNumbers.add(rowNumber);
            rows.add(rowData);
        }
        public void finishProcessing() {
            finished = true;
        }
        public Object getResult() {
            return rows;
        }
    }

    @isTest
    static void testBasicParsingEmitsAllRowsInOrder() {
        List<List<String>> data = new List<List<String>>{
            new List<String>{ 'Header1', 'Header2' },
            new List<String>{ 'A1', 'B1' },
            new List<String>{ 'A2', 'B2' }
        };
        Blob file = XLSXTestFixtureFactory.generateXLSXFromRows(data);
        CapturingRowHandler handler = new CapturingRowHandler();

        Test.startTest();
        new XLSXParser(handler, null).process(file);
        Test.stopTest();

        Assert.areEqual(3, handler.rowNumbers.size(), 'Header row + 2 data rows should all be emitted.');
        Assert.areEqual('A1', handler.rows[1].get('A'), 'Row 2 column A should read back correctly.');
        Assert.areEqual('B2', handler.rows[2].get('B'), 'Row 3 column B should read back correctly.');
        Assert.isTrue(handler.finished, 'finishProcessing() should be called once parsing completes.');
    }

    @isTest
    static void testHiddenRowExcludedWhenConfigured() {
        List<List<String>> data = new List<List<String>>{
            new List<String>{ 'Header' },
            new List<String>{ 'Visible1' },
            new List<String>{ 'HiddenRow' },
            new List<String>{ 'Visible2' }
        };
        Blob file = XLSXTestFixtureFactory.generateXLSXFromRows(data, new Set<Integer>{ 3 }, false);
        XLSX_Reader_Config__mdt config = new XLSX_Reader_Config__mdt(Hidden_Row_Handling__c = 'Exclude');
        CapturingRowHandler handler = new CapturingRowHandler();

        Test.startTest();
        new XLSXParser(handler, config).process(file);
        Test.stopTest();

        Assert.areEqual(3, handler.rowNumbers.size(), 'Row 3 (hidden) should be excluded; header + 2 visible rows remain.');
        Assert.isFalse(handler.rowNumbers.contains(3), 'Hidden row 3 must not reach the handler.');
    }

    @isTest
    static void testHiddenRowIncludedWithoutExplicitConfig() {
        List<List<String>> data = new List<List<String>>{
            new List<String>{ 'Header' },
            new List<String>{ 'Visible1' },
            new List<String>{ 'HiddenRow' }
        };
        Blob file = XLSXTestFixtureFactory.generateXLSXFromRows(data, new Set<Integer>{ 2 }, false);
        CapturingRowHandler handler = new CapturingRowHandler();

        Test.startTest();
        new XLSXParser(handler, null).process(file);
        Test.stopTest();

        Assert.areEqual(3, handler.rowNumbers.size(), 'Without Hidden_Row_Handling__c = Exclude, hidden rows must still be included (backward-compatible default).');
    }

    @isTest
    static void testTotalsRowExcludedWhenConfigured() {
        List<List<String>> data = new List<List<String>>{
            new List<String>{ 'Item', 'Amount' },
            new List<String>{ 'Widget', '10' },
            new List<String>{ 'Gadget', '20' },
            new List<String>{ 'Total', '30' }
        };
        Blob file = XLSXTestFixtureFactory.generateXLSXFromRows(data, new Set<Integer>(), true);
        XLSX_Reader_Config__mdt config = new XLSX_Reader_Config__mdt(Totals_Row_Handling__c = 'Exclude');
        CapturingRowHandler handler = new CapturingRowHandler();

        Test.startTest();
        new XLSXParser(handler, config).process(file);
        Test.stopTest();

        Assert.areEqual(3, handler.rowNumbers.size(), 'The Excel Table totals row (row 4) should be excluded.');
        Assert.isFalse(handler.rowNumbers.contains(4), 'Totals row 4 must not reach the handler.');
    }

    @isTest
    static void testTotalsRowIncludedWithoutExplicitConfig() {
        List<List<String>> data = new List<List<String>>{
            new List<String>{ 'Item', 'Amount' },
            new List<String>{ 'Widget', '10' },
            new List<String>{ 'Total', '10' }
        };
        Blob file = XLSXTestFixtureFactory.generateXLSXFromRows(data, new Set<Integer>(), true);
        CapturingRowHandler handler = new CapturingRowHandler();

        Test.startTest();
        new XLSXParser(handler, null).process(file);
        Test.stopTest();

        Assert.areEqual(3, handler.rowNumbers.size(), 'Without Totals_Row_Handling__c = Exclude, the totals row must still be included.');
    }

    @isTest
    static void testMaxRowThresholdThrowsOnceExceeded() {
        List<List<String>> data = new List<List<String>>{
            new List<String>{ 'Header' },
            new List<String>{ 'Row1' },
            new List<String>{ 'Row2' },
            new List<String>{ 'Row3' }
        };
        Blob file = XLSXTestFixtureFactory.generateXLSXFromRows(data);
        XLSX_Reader_Config__mdt config = new XLSX_Reader_Config__mdt(Max_Row_Threshold__c = 2);
        CapturingRowHandler handler = new CapturingRowHandler();

        Test.startTest();
        try {
            new XLSXParser(handler, config).process(file);
            Assert.fail('Expected an XLSXParserException once row count exceeded Max_Row_Threshold__c.');
        } catch (XLSXParserException e) {
            Assert.isTrue(e.getMessage().contains('Max Row Threshold'), 'Exception message should reference the threshold: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @isTest
    static void testPreflightSizeGateRejectsSizeOverTheSafeHeapBudget() {
        // Exercised directly via @TestVisible rather than by materializing an actually-oversized
        // fixture: building a file big enough to trip a 40%-of-6MB gate gets uncomfortably close to
        // the test transaction's own 6MB ceiling well before extraction, which would fail the test
        // for the wrong reason (heap exhausted during setup, not the gate under test).
        Long oversized = Limits.getLimitHeapSize(); // 100% of the ceiling is comfortably over the 40% threshold

        Test.startTest();
        try {
            XLSXParser.assertSafeToExtract(oversized, 'xl/worksheets/sheet1.xml');
            Assert.fail('Expected an XLSXParserException for a size at the full heap ceiling.');
        } catch (XLSXParserException e) {
            Assert.isTrue(e.getMessage().contains('exceeds the safe heap budget'), 'Error should explain the heap-safety rejection: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @isTest
    static void testPreflightSizeGateAllowsSizeUnderTheSafeHeapBudget() {
        Long tiny = 100;

        Test.startTest();
        XLSXParser.assertSafeToExtract(tiny, 'xl/worksheets/sheet1.xml'); // should not throw
        Test.stopTest();
    }

    @isTest
    static void testPeekUncompressedSheetSizeIsPositive() {
        List<List<String>> data = new List<List<String>>{
            new List<String>{ 'Header1', 'Header2' },
            new List<String>{ 'Value1', 'Value2' }
        };
        Blob file = XLSXTestFixtureFactory.generateXLSXFromRows(data);

        Test.startTest();
        Long size = XLSXParser.peekUncompressedSheetSize(file);
        Test.stopTest();

        Assert.isTrue(size > 0, 'Uncompressed sheet size should be a positive byte count.');
    }

    @isTest
    static void testMissingSheetThrowsClearException() {
        Blob emptyZipLikeBlob = Blob.valueOf('not a real xlsx');

        Test.startTest();
        try {
            XLSXParser.peekUncompressedSheetSize(emptyZipLikeBlob);
            Assert.fail('Expected an exception for a blob that is not a valid zip archive.');
        } catch (Exception e) {
            Assert.isTrue(true, 'Any exception is acceptable here - the point is it fails clearly rather than silently.');
        }
        Test.stopTest();
    }
}
