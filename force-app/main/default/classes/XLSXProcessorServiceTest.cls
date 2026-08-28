@isTest
private class XLSXProcessorServiceTest {

    @isTest
    static void testSyncPipelineCreatesLeadsAndExcludesHiddenRow() {
        List<List<String>> data = new List<List<String>>{
            new List<String>{ 'First Name', 'Last Name', 'Company Name' },
            new List<String>{ 'Jane', 'Doe', 'Acme' },
            new List<String>{ 'Should', 'NotAppear', 'HiddenCo' },
            new List<String>{ 'John', 'Smith', 'Globex' }
        };
        Blob file = XLSXTestFixtureFactory.generateXLSXFromRows(data, new Set<Integer>{ 3 }, false);

        ContentVersion cv = new ContentVersion(Title = 'Leads', PathOnClient = 'leads.xlsx', VersionData = file);
        insert cv;
        cv = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id];

        XLSXProcessorService.ProcessingRequest req = new XLSXProcessorService.ProcessingRequest();
        req.contentDocumentId = cv.ContentDocumentId;
        req.configDeveloperName = 'Test_Lead_Sync_Upload';

        Test.startTest();
        XLSXProcessorService.processFiles(new List<XLSXProcessorService.ProcessingRequest>{ req });
        Test.stopTest();

        List<Lead> created = [SELECT FirstName, LastName, Company FROM Lead WHERE LastName IN ('Doe', 'Smith', 'NotAppear')];
        Set<String> lastNames = new Set<String>();
        for (Lead l : created) {
            lastNames.add(l.LastName);
        }
        Assert.areEqual(2, created.size(), 'Only the 2 visible rows should create Leads - Test_Lead_Sync_Upload excludes hidden rows.');
        Assert.isTrue(lastNames.contains('Doe') && lastNames.contains('Smith'), 'Both visible Leads should have been created.');
        Assert.isFalse(lastNames.contains('NotAppear'), 'The hidden row must not have created a Lead.');
    }

    @isTest
    static void testMisconfiguredRowHandlerThrowsInsteadOfSilentSuccess() {
        XLSX_Reader_Config__mdt config = new XLSX_Reader_Config__mdt(
            Row_Handler_Class__c = null,
            Result_Handler_Class__c = 'DatabaseInsertResultHandler'
        );
        XLSXProcessorService.ProcessingRequest req = new XLSXProcessorService.ProcessingRequest();
        Blob file = XLSXTestFixtureFactory.generateXLSXFromRows(new List<List<String>>{ new List<String>{ 'Header' } });

        Test.startTest();
        try {
            XLSXProcessorService.runPipeline(config, req, file);
            Assert.fail('An unconfigured Row_Handler_Class__c must never silently succeed.');
        } catch (XLSXParserException e) {
            Assert.isTrue(e.getMessage().contains('Row_Handler_Class__c'), 'Error should name the missing configuration: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @isTest
    static void testSingleClassForBothRolesThrowsClearInterfaceMismatch() {
        // The exact original Blocker 1 scenario: one class name used for both roles, but the class
        // only implements one of the two interfaces.
        XLSX_Reader_Config__mdt config = new XLSX_Reader_Config__mdt(
            Row_Handler_Class__c = 'DatabaseInsertResultHandler', // implements IXLSXResultHandler only
            Result_Handler_Class__c = 'DatabaseInsertResultHandler'
        );
        XLSXProcessorService.ProcessingRequest req = new XLSXProcessorService.ProcessingRequest();
        Blob file = XLSXTestFixtureFactory.generateXLSXFromRows(new List<List<String>>{ new List<String>{ 'Header' } });

        Test.startTest();
        try {
            XLSXProcessorService.runPipeline(config, req, file);
            Assert.fail('DatabaseInsertResultHandler does not implement IXLSXRowHandler and must fail loudly when used as one.');
        } catch (XLSXParserException e) {
            Assert.isTrue(e.getMessage().contains('IXLSXRowHandler'), 'Error should explain the interface mismatch: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @isTest
    static void testDatabaseInsertResultHandlerAllowsPartialSuccess() {
        List<SObject> records = new List<SObject>();
        for (Integer i = 0; i < 5; i++) {
            records.add(new Lead(FirstName = 'Bulk', LastName = 'Test' + i, Company = 'Acme'));
        }
        records.add(new Lead(FirstName = 'Bad')); // missing required LastName/Company

        DatabaseInsertResultHandler handler = new DatabaseInsertResultHandler();
        handler.initialize(new XLSX_Reader_Config__mdt(), null);

        Test.startTest();
        try {
            handler.handleResult(records);
            Assert.fail('Expected an exception summarizing the one failed record.');
        } catch (XLSXParserException e) {
            Assert.isTrue(e.getMessage().contains('1 of 6'), 'Error should summarize the failure count: ' + e.getMessage());
        }
        Test.stopTest();

        Integer insertedCount = [SELECT COUNT() FROM Lead WHERE Company = 'Acme' AND FirstName = 'Bulk'];
        Assert.areEqual(5, insertedCount, 'The 5 valid records should still be inserted despite one bad record in the same batch (partial success, not all-or-nothing).');
    }

    @isTest
    static void testDatabaseInsertResultHandlerChunksAcrossMultipleBatches() {
        List<SObject> records = new List<SObject>();
        for (Integer i = 0; i < 250; i++) {
            records.add(new Lead(FirstName = 'Chunked', LastName = 'Test' + i, Company = 'Acme'));
        }

        DatabaseInsertResultHandler handler = new DatabaseInsertResultHandler();
        handler.initialize(new XLSX_Reader_Config__mdt(), null);

        Test.startTest();
        handler.handleResult(records);
        Test.stopTest();

        Integer insertedCount = [SELECT COUNT() FROM Lead WHERE Company = 'Acme' AND FirstName = 'Chunked'];
        Assert.areEqual(250, insertedCount, 'All 250 records should insert successfully across multiple 200-record chunks.');
    }

    @isTest
    static void testInsertIsBlockedForUserWithoutLeadAccess() {
        List<Profile> minimalProfiles = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1];
        if (minimalProfiles.isEmpty()) {
            return; // This standard profile isn't present in every org configuration - nothing to assert against.
        }

        User lowPrivUser = new User(
            FirstName = 'Low',
            LastName = 'Priv',
            Email = 'lowpriv' + Datetime.now().getTime() + '@example.com',
            Username = 'lowpriv' + Datetime.now().getTime() + '@example.com.test',
            Alias = 'lowp',
            TimeZoneSidKey = 'America/Los_Angeles',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            ProfileId = minimalProfiles[0].Id
        );
        insert lowPrivUser;

        DatabaseInsertResultHandler handler = new DatabaseInsertResultHandler();
        handler.initialize(new XLSX_Reader_Config__mdt(), null);
        List<SObject> records = new List<SObject>{ new Lead(FirstName = 'NoAccess', LastName = 'User', Company = 'Acme') };

        Test.startTest();
        System.runAs(lowPrivUser) {
            try {
                handler.handleResult(records);
                Assert.fail('A user with no create access on Lead should not be able to insert via AccessLevel.USER_MODE.');
            } catch (Exception e) {
                Assert.isTrue(true, 'USER_MODE correctly blocked the insert for a user without Lead create access.');
            }
        }
        Test.stopTest();

        Integer count = [SELECT COUNT() FROM Lead WHERE LastName = 'User' AND FirstName = 'NoAccess'];
        Assert.areEqual(0, count, 'No Lead should have been created on behalf of the low-privilege user.');
    }
}
