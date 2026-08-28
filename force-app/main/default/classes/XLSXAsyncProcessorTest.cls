@isTest
private class XLSXAsyncProcessorTest {

    @isTest
    static void testAsyncProcessorCreatesLeadsViaSharedPipeline() {
        List<List<String>> data = new List<List<String>>{
            new List<String>{ 'First Name', 'Last Name', 'Company Name' },
            new List<String>{ 'Async', 'Test', 'Acme' }
        };
        Blob file = XLSXTestFixtureFactory.generateXLSXFromRows(data);

        ContentVersion cv = new ContentVersion(Title = 'AsyncLeads', PathOnClient = 'asyncleads.xlsx', VersionData = file);
        insert cv;
        cv = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id];

        XLSX_Reader_Config__mdt config = [
            SELECT Id, DeveloperName, Row_Handler_Class__c, Result_Handler_Class__c, Error_Handling_Behavior__c,
                   Execution_Mode__c, Max_Row_Threshold__c, Async_Threshold_Bytes__c, Hidden_Row_Handling__c,
                   Totals_Row_Handling__c, Empty_Result_Behaviour__c, Header_Row_Number__c
            FROM XLSX_Reader_Config__mdt
            WHERE DeveloperName = 'Test_Lead_Sync_Upload'
            LIMIT 1
        ];

        XLSXProcessorService.ProcessingRequest req = new XLSXProcessorService.ProcessingRequest();
        req.contentDocumentId = cv.ContentDocumentId;
        req.configDeveloperName = config.DeveloperName;

        Test.startTest();
        System.enqueueJob(new XLSXAsyncProcessor(req, config));
        Test.stopTest(); // Queueable executes synchronously here

        Integer count = [SELECT COUNT() FROM Lead WHERE LastName = 'Test' AND FirstName = 'Async'];
        Assert.areEqual(1, count, 'The Queueable should create the Lead via the same shared pipeline used by the Sync path.');
    }

    @isTest
    static void testAsyncProcessorLogsErrorRatherThanLosingTheJob() {
        XLSXProcessorService.ProcessingRequest req = new XLSXProcessorService.ProcessingRequest();
        req.contentDocumentId = null; // guarantees the "file not found" branch inside execute()

        XLSX_Reader_Config__mdt config = new XLSX_Reader_Config__mdt(
            Row_Handler_Class__c = 'SObjectCreatorRowHandler',
            Result_Handler_Class__c = 'DatabaseInsertResultHandler',
            Error_Handling_Behavior__c = 'Log Error'
        );

        Test.startTest();
        System.enqueueJob(new XLSXAsyncProcessor(req, config));
        Test.stopTest();

        // Error_Message__c is a Long Text Area - not filterable in a SOQL WHERE clause, so filter in Apex.
        List<XLSX_Error_Log__c> logs = [SELECT Error_Message__c FROM XLSX_Error_Log__c];
        Assert.areEqual(1, logs.size(), 'A missing file should be logged to XLSX_Error_Log__c, not silently dropped by the async job.');
        Assert.isTrue(logs[0].Error_Message__c.startsWith('File not found'), 'Log message should describe the failure: ' + logs[0].Error_Message__c);
    }

    @isTest
    static void testFinalizerRecordsFailureWhenThrowExceptionLeavesJobUnhandled() {
        // Error_Handling_Behavior__c = 'Throw Exception' makes logError() deliberately re-throw, so
        // execute()'s own try/catch can't be the thing that records this failure - only the Finalizer,
        // which runs regardless of how the job ends, can.
        XLSXProcessorService.ProcessingRequest req = new XLSXProcessorService.ProcessingRequest();
        req.contentDocumentId = null; // guarantees the "file not found" -> logError -> re-throw cascade

        XLSX_Reader_Config__mdt config = new XLSX_Reader_Config__mdt(
            Row_Handler_Class__c = 'SObjectCreatorRowHandler',
            Result_Handler_Class__c = 'DatabaseInsertResultHandler',
            Error_Handling_Behavior__c = 'Throw Exception'
        );

        Test.startTest();
        System.enqueueJob(new XLSXAsyncProcessor(req, config));
        try {
            // In test context the queued job runs synchronously inside stopTest(), and
            // Error_Handling_Behavior__c = 'Throw Exception' deliberately leaves it unhandled - that
            // exception propagates out of stopTest() itself. The Finalizer still runs regardless
            // (that's its whole contract), which is what this test is actually verifying below.
            Test.stopTest();
            Assert.fail('Expected the unhandled exception to propagate out of stopTest() in test context.');
        } catch (XLSXParserException e) {
            // expected
        }

        List<XLSX_Error_Log__c> logs = [SELECT Error_Message__c FROM XLSX_Error_Log__c];
        Assert.areEqual(1, logs.size(), 'The Finalizer should record the failure even though Error_Handling_Behavior__c = Throw Exception left the job itself unhandled.');
        Assert.isTrue(logs[0].Error_Message__c.contains('File not found'), 'The Finalizer-recorded message should describe the original failure: ' + logs[0].Error_Message__c);
    }
}
