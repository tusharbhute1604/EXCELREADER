@isTest
private class SObjectCreatorRowHandlerTest {

    @isTest
    static void testHeaderRowDetectionUsesRowNumberNotFirstSeen() {
        XLSX_Reader_Config__mdt config = [SELECT Id, Header_Row_Number__c FROM XLSX_Reader_Config__mdt WHERE DeveloperName = 'Test_Lead_Sync_Upload' LIMIT 1];

        SObjectCreatorRowHandler handler = new SObjectCreatorRowHandler();
        handler.initialize(config);

        handler.processRow(1, new Map<String, String>{ 'A' => 'First Name', 'B' => 'Last Name', 'C' => 'Company Name' });
        handler.processRow(2, new Map<String, String>{ 'A' => 'Jane', 'B' => 'Doe', 'C' => 'Acme Corp' });

        List<SObject> result = (List<SObject>) handler.getResult();
        Assert.areEqual(1, result.size(), 'One Lead should be built from the single data row.');
        Lead builtLead = (Lead) result[0];
        Assert.areEqual('Jane', builtLead.FirstName, 'FirstName should map from column A.');
        Assert.areEqual('Doe', builtLead.LastName, 'LastName should map from column B.');
        Assert.areEqual('Acme Corp', builtLead.Company, 'Company should map from column C.');
    }

    @isTest
    static void testBannerRowAboveHeadersProducesNoRecordsRatherThanMisreadData() {
        XLSX_Reader_Config__mdt config = [SELECT Id, Header_Row_Number__c FROM XLSX_Reader_Config__mdt WHERE DeveloperName = 'Test_Lead_Sync_Upload' LIMIT 1];

        SObjectCreatorRowHandler handler = new SObjectCreatorRowHandler();
        handler.initialize(config);

        // Row 1 is a title/banner row, not the real header row. Because header detection now keys
        // off rowNumber == 1 (not "first row seen"), the actual header row at position 2 is treated
        // as an ordinary data row - so nothing maps, which is honest, rather than silently
        // misinterpreting the banner text as column headers.
        handler.processRow(1, new Map<String, String>{ 'A' => 'Report generated 2026-01-01' });
        handler.processRow(2, new Map<String, String>{ 'A' => 'First Name', 'B' => 'Last Name', 'C' => 'Company Name' });
        handler.processRow(3, new Map<String, String>{ 'A' => 'Jane', 'B' => 'Doe', 'C' => 'Acme' });

        List<SObject> result = (List<SObject>) handler.getResult();
        Assert.areEqual(0, result.size(), 'With a banner row consumed as headers, no subsequent row should produce a record.');
    }

    @isTest
    static void testConfiguredHeaderRowNumberFindsHeadersBelowABannerAndBlankRow() {
        // Header_Row_Number__c = 3 on this fixture: row 1 is a title banner, row 2 is blank,
        // row 3 is the real header row, data starts at row 4. Real-world files commonly look
        // like this - a report title and a spacer row above the actual table.
        XLSX_Reader_Config__mdt config = [SELECT Id, Header_Row_Number__c FROM XLSX_Reader_Config__mdt WHERE DeveloperName = 'Test_Lead_Sync_Upload_Offset_Header' LIMIT 1];

        SObjectCreatorRowHandler handler = new SObjectCreatorRowHandler();
        handler.initialize(config);

        handler.processRow(1, new Map<String, String>{ 'A' => 'Q3 Lead Report' });
        // Row 2 intentionally not sent at all - a genuinely blank row never reaches the handler.
        handler.processRow(3, new Map<String, String>{ 'A' => 'First Name', 'B' => 'Last Name', 'C' => 'Company Name' });
        handler.processRow(4, new Map<String, String>{ 'A' => 'Jane', 'B' => 'Doe', 'C' => 'Acme Corp' });

        List<SObject> result = (List<SObject>) handler.getResult();
        Assert.areEqual(1, result.size(), 'The data row below the configured header row should still produce a Lead.');
        Lead builtLead = (Lead) result[0];
        Assert.areEqual('Jane', builtLead.FirstName, 'FirstName should map from column A using the row-3 headers, not the row-1 banner.');
        Assert.areEqual('Doe', builtLead.LastName, 'LastName should map from column B.');
        Assert.areEqual('Acme Corp', builtLead.Company, 'Company should map from column C.');
    }

    @isTest
    static void testExcelSerialDateConvertedForDateField() {
        XLSX_Reader_Config__mdt config = [SELECT Id, Header_Row_Number__c FROM XLSX_Reader_Config__mdt WHERE DeveloperName = 'Test_Opportunity_Date_Upload' LIMIT 1];

        SObjectCreatorRowHandler handler = new SObjectCreatorRowHandler();
        handler.initialize(config);

        Decimal serial = 44927; // arbitrary Excel serial - the conversion math itself is covered by XLSXDateConverterTest
        handler.processRow(1, new Map<String, String>{ 'A' => 'Opportunity Name', 'B' => 'Stage', 'C' => 'Close Date' });
        handler.processRow(2, new Map<String, String>{ 'A' => 'Test Opp', 'B' => 'Prospecting', 'C' => String.valueOf(serial) });

        List<SObject> result = (List<SObject>) handler.getResult();
        Assert.areEqual(1, result.size(), 'One Opportunity should be built.');
        Opportunity opp = (Opportunity) result[0];
        Assert.areEqual(XLSXDateConverter.convertToDate(serial), opp.CloseDate, 'The raw Excel serial must be routed through XLSXDateConverter, not left as a bare numeric string.');
    }

    @isTest
    static void testUnconvertibleValueIsRecordedAsWarningNotSilentlyDropped() {
        XLSX_Reader_Config__mdt config = [SELECT Id, Header_Row_Number__c FROM XLSX_Reader_Config__mdt WHERE DeveloperName = 'Test_Lead_Sync_Upload' LIMIT 1];

        SObjectCreatorRowHandler handler = new SObjectCreatorRowHandler();
        handler.initialize(config);

        handler.processRow(1, new Map<String, String>{ 'A' => 'First Name', 'B' => 'Last Name', 'C' => 'Company Name', 'D' => 'Employee Count' });
        // NumberOfEmployees is an Integer field - a genuinely non-numeric string still can't be
        // parsed as a Decimal at all (see convertValue()'s isNumeric() guard) and must surface as a
        // warning, not vanish into an empty catch. A well-formed numeric string in this same column
        // is covered separately by testNumericFieldsPopulatedFromValidValuesIncludingDecimals below.
        handler.processRow(2, new Map<String, String>{ 'A' => 'Jane', 'B' => 'Doe', 'C' => 'Acme', 'D' => 'not-a-number' });

        List<SObject> result = (List<SObject>) handler.getResult();
        Assert.areEqual(1, result.size(), 'The record should still be created using the fields that DID map cleanly.');
        Assert.isFalse(handler.getWarnings().isEmpty(), 'An unconvertible field value must produce a visible warning.');
        Assert.isTrue(handler.getWarnings()[0].contains('Employee Count') || handler.getWarnings()[0].contains('NumberOfEmployees'), 'The warning should identify which field failed: ' + handler.getWarnings()[0]);
    }

    @isTest
    static void testNumericFieldsPopulatedFromValidValuesIncludingDecimals() {
        // Regression coverage for a real bug: SObject.put() does not implicitly coerce a String into
        // a Currency/Percent/Double/Integer field - it throws "Illegal assignment from String to
        // Decimal" (or "...to Integer") even for a perfectly well-formed numeric string. Employee
        // Count (Integer) and Annual Revenue (Currency, i.e. Decimal-backed) exercise both of the
        // two Apex types convertValue() now has to produce.
        XLSX_Reader_Config__mdt config = [SELECT Id, Header_Row_Number__c FROM XLSX_Reader_Config__mdt WHERE DeveloperName = 'Test_Lead_Sync_Upload' LIMIT 1];

        SObjectCreatorRowHandler handler = new SObjectCreatorRowHandler();
        handler.initialize(config);

        handler.processRow(1, new Map<String, String>{ 'A' => 'First Name', 'B' => 'Last Name', 'C' => 'Company Name', 'D' => 'Employee Count', 'E' => 'Annual Revenue' });
        handler.processRow(2, new Map<String, String>{ 'A' => 'Jane', 'B' => 'Doe', 'C' => 'Acme', 'D' => '250', 'E' => '125000.50' });

        List<SObject> result = (List<SObject>) handler.getResult();
        Assert.areEqual(1, result.size(), 'One Lead should be built.');
        Lead builtLead = (Lead) result[0];
        Assert.areEqual(250, builtLead.NumberOfEmployees, 'A well-formed integer string must populate an Integer field, not fail like any other numeric field currently does.');
        Assert.areEqual(125000.50, builtLead.AnnualRevenue, 'A well-formed decimal string must populate a Currency field with its full decimal precision, not fail or get truncated.');
        Assert.isTrue(handler.getWarnings().isEmpty(), 'Well-formed numeric values must not produce any warnings: ' + handler.getWarnings());
    }
}
