@isTest
private class AggregateRowHandlerTest {

    @isTest
    static void testSumAggregationAndWriteBack() {
        XLSX_Reader_Config__mdt config = [SELECT Id, DeveloperName, Empty_Result_Behaviour__c, Header_Row_Number__c FROM XLSX_Reader_Config__mdt WHERE DeveloperName = 'Test_Amount_Aggregator' LIMIT 1];
        Lead target = new Lead(FirstName = 'Agg', LastName = 'Target', Company = 'Acme');
        insert target;

        AggregateRowHandler rowHandler = new AggregateRowHandler();
        rowHandler.initialize(config);
        rowHandler.processRow(1, new Map<String, String>{ 'A' => 'Item', 'B' => 'Amount' });
        rowHandler.processRow(2, new Map<String, String>{ 'A' => 'Widget', 'B' => '10' });
        rowHandler.processRow(3, new Map<String, String>{ 'A' => 'Gadget', 'B' => '25' });
        rowHandler.finishProcessing();

        FieldWriteBackResultHandler resultHandler = new FieldWriteBackResultHandler();
        resultHandler.initialize(config, target.Id);

        Test.startTest();
        resultHandler.handleResult(rowHandler.getResult());
        Test.stopTest();

        Lead updated = [SELECT NumberOfEmployees FROM Lead WHERE Id = :target.Id];
        Assert.areEqual(35, updated.NumberOfEmployees, 'SUM of 10 + 25 should be written back to the target field.');
    }

    @isTest
    static void testEmptyFileSmartDefaultsZeroForSum() {
        XLSX_Reader_Config__mdt config = [SELECT Id, DeveloperName, Empty_Result_Behaviour__c, Header_Row_Number__c FROM XLSX_Reader_Config__mdt WHERE DeveloperName = 'Test_Amount_Aggregator' LIMIT 1];
        Lead target = new Lead(FirstName = 'Agg', LastName = 'Empty', Company = 'Acme');
        insert target;

        AggregateRowHandler rowHandler = new AggregateRowHandler();
        rowHandler.initialize(config);
        rowHandler.processRow(1, new Map<String, String>{ 'A' => 'Item', 'B' => 'Amount' });
        // No data rows at all.

        FieldWriteBackResultHandler resultHandler = new FieldWriteBackResultHandler();
        resultHandler.initialize(config, target.Id);

        Test.startTest();
        resultHandler.handleResult(rowHandler.getResult());
        Test.stopTest();

        Lead updated = [SELECT NumberOfEmployees FROM Lead WHERE Id = :target.Id];
        Assert.areEqual(0, updated.NumberOfEmployees, 'With no explicit Empty_Result_Behaviour__c override, SUM of no rows should default to 0 per the design intent.');
    }

    @isTest
    static void testConfiguredHeaderRowNumberAggregatesBelowABannerRow() {
        // Header_Row_Number__c = 3 on this fixture, same offset shape as the SObjectCreatorRowHandler
        // equivalent test: title row, blank row, real headers, then data.
        XLSX_Reader_Config__mdt config = [SELECT Id, DeveloperName, Empty_Result_Behaviour__c, Header_Row_Number__c FROM XLSX_Reader_Config__mdt WHERE DeveloperName = 'Test_Amount_Aggregator_Offset_Header' LIMIT 1];
        Lead target = new Lead(FirstName = 'Agg', LastName = 'Offset', Company = 'Acme');
        insert target;

        AggregateRowHandler rowHandler = new AggregateRowHandler();
        rowHandler.initialize(config);
        rowHandler.processRow(1, new Map<String, String>{ 'A' => 'Q3 Expense Report' });
        rowHandler.processRow(3, new Map<String, String>{ 'A' => 'Item', 'B' => 'Amount' });
        rowHandler.processRow(4, new Map<String, String>{ 'A' => 'Widget', 'B' => '10' });
        rowHandler.processRow(5, new Map<String, String>{ 'A' => 'Gadget', 'B' => '25' });
        rowHandler.finishProcessing();

        FieldWriteBackResultHandler resultHandler = new FieldWriteBackResultHandler();
        resultHandler.initialize(config, target.Id);

        Test.startTest();
        resultHandler.handleResult(rowHandler.getResult());
        Test.stopTest();

        Lead updated = [SELECT NumberOfEmployees FROM Lead WHERE Id = :target.Id];
        Assert.areEqual(35, updated.NumberOfEmployees, 'SUM should still find and total the Amount column using the row-3 headers, ignoring the row-1 banner.');
    }

    @isTest
    static void testMismatchedRowHandlerResultThrowsInsteadOfSilentlyNoOp() {
        XLSX_Reader_Config__mdt config = [SELECT Id, DeveloperName FROM XLSX_Reader_Config__mdt WHERE DeveloperName = 'Test_Amount_Aggregator' LIMIT 1];

        FieldWriteBackResultHandler resultHandler = new FieldWriteBackResultHandler();
        resultHandler.initialize(config, UserInfo.getUserId());

        Test.startTest();
        try {
            // A List<SObject> (the SObjectCreatorRowHandler shape) is not what this handler expects.
            resultHandler.handleResult(new List<SObject>());
            Assert.fail('Expected an exception when handed a result shape this handler does not understand.');
        } catch (XLSXParserException e) {
            Assert.isTrue(e.getMessage().contains('AggregateRowHandler'), 'Error should explain the expected pairing: ' + e.getMessage());
        }
        Test.stopTest();
    }
}
