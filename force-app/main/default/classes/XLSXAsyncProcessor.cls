/**
 * Async Processor for XLSX Parsing.
 * Invoked by XLSXProcessorService when the file size exceeds the Sync threshold.
 */
public with sharing class XLSXAsyncProcessor implements Queueable {

    private XLSXProcessorService.ProcessingRequest request;
    private XLSX_Reader_Config__mdt config;

    public XLSXAsyncProcessor(XLSXProcessorService.ProcessingRequest request, XLSX_Reader_Config__mdt config) {
        this.request = request;
        this.config = config;
    }

    public void execute(QueueableContext context) {
        // Error_Handling_Behavior__c = 'Throw Exception' makes logError() below deliberately re-throw
        // (see XLSXProcessorService.logError) so the job shows as Failed in Setup - but an uncaught
        // exception on its own leaves nothing in XLSX_Error_Log__c. The Finalizer runs in its own
        // transaction regardless of how this job ends, so it's the one guaranteed place left to
        // record that failure for that specific config combination.
        System.attachFinalizer(new AsyncFailureFinalizer(this.request, this.config));

        try {
            // Queueable execute() starts a fresh call stack - WITH USER_MODE so this async job can
            // never read file data the original requesting user couldn't see.
            List<ContentVersion> cvs = [
                SELECT VersionData, PathOnClient
                FROM ContentVersion
                WHERE ContentDocumentId = :this.request.contentDocumentId AND IsLatest = true
                WITH USER_MODE
            ];

            if (cvs.isEmpty()) {
                XLSXProcessorService.logError(this.config, this.request, 'File not found for Document Id: ' + this.request.contentDocumentId, null);
                return;
            }

            XLSXProcessorService.runPipeline(this.config, this.request, cvs[0].VersionData);
        } catch (Exception e) {
            XLSXProcessorService.logError(this.config, this.request, e.getMessage(), e.getStackTraceString());
        }
    }

    private class AsyncFailureFinalizer implements Finalizer {
        private XLSXProcessorService.ProcessingRequest request;
        private XLSX_Reader_Config__mdt config;

        AsyncFailureFinalizer(XLSXProcessorService.ProcessingRequest request, XLSX_Reader_Config__mdt config) {
            this.request = request;
            this.config = config;
        }

        public void execute(FinalizerContext ctx) {
            if (ctx.getResult() != ParentJobResult.UNHANDLED_EXCEPTION) {
                return;
            }

            // Write directly rather than calling XLSXProcessorService.logError() again - with
            // Error_Handling_Behavior__c = 'Throw Exception' that would just re-throw a second time
            // and the failure would still end up unrecorded. Intentionally system-mode, same
            // rationale as logError(): a failure logger that only works when the acting user has
            // create access defeats its own purpose.
            Exception ex = ctx.getException();
            XLSX_Error_Log__c log = new XLSX_Error_Log__c();
            log.Error_Message__c = ex != null ? ex.getMessage() : 'XLSXAsyncProcessor failed with an unhandled exception.';
            log.Stack_Trace__c = ex != null ? ex.getStackTraceString() : null;
            log.Related_Record_Id__c = this.request != null ? this.request.relatedRecordId : null;
            insert log;
        }
    }
}
