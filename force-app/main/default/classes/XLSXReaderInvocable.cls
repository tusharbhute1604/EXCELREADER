/**
 * Invocable method to allow Salesforce Admins to trigger XLSX processing from Flow.
 */
public with sharing class XLSXReaderInvocable {
    
    public class InvocableRequest {
        @InvocableVariable(label='Content Document Id' description='The ID of the uploaded Excel file' required=true)
        public Id contentDocumentId;
        
        @InvocableVariable(label='Configuration Developer Name' description='The Developer Name of the XLSX_Reader_Config__mdt record' required=true)
        public String configDeveloperName;
        
        @InvocableVariable(label='Related Record Id' description='The ID of the parent record (used for Error Logging)' required=false)
        public Id relatedRecordId;
    }

    @InvocableMethod(label='Process XLSX File' description='Reads an Excel file and processes it based on the Custom Metadata configuration.')
    public static void execute(List<InvocableRequest> requests) {
        List<XLSXProcessorService.ProcessingRequest> serviceRequests = new List<XLSXProcessorService.ProcessingRequest>();
        
        for (InvocableRequest req : requests) {
            XLSXProcessorService.ProcessingRequest svcReq = new XLSXProcessorService.ProcessingRequest();
            svcReq.contentDocumentId = req.contentDocumentId;
            svcReq.configDeveloperName = req.configDeveloperName;
            svcReq.relatedRecordId = req.relatedRecordId;
            serviceRequests.add(svcReq);
        }
        
        XLSXProcessorService.processFiles(serviceRequests);
    }
}
