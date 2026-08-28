@isTest
private class XLSXReaderInvocableTest {

    @isTest
    static void testInvocableRoutesThroughToTheSharedPipeline() {
        List<List<String>> data = new List<List<String>>{
            new List<String>{ 'First Name', 'Last Name', 'Company Name' },
            new List<String>{ 'Invocable', 'User', 'Acme' }
        };
        Blob file = XLSXTestFixtureFactory.generateXLSXFromRows(data);

        ContentVersion cv = new ContentVersion(Title = 'InvocableLeads', PathOnClient = 'invocable.xlsx', VersionData = file);
        insert cv;
        cv = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id];

        XLSXReaderInvocable.InvocableRequest req = new XLSXReaderInvocable.InvocableRequest();
        req.contentDocumentId = cv.ContentDocumentId;
        req.configDeveloperName = 'Test_Lead_Sync_Upload';

        Test.startTest();
        XLSXReaderInvocable.execute(new List<XLSXReaderInvocable.InvocableRequest>{ req });
        Test.stopTest();

        Integer count = [SELECT COUNT() FROM Lead WHERE LastName = 'User' AND FirstName = 'Invocable'];
        Assert.areEqual(1, count, 'The Invocable entry point should route through to the same pipeline and create the Lead.');
    }
}
