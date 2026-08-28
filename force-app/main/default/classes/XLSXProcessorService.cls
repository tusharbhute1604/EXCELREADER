/**
 * Main orchestration service for XLSX Processing.
 * Responsible for retrieving configuration, deciding on Sync/Async execution based on file size,
 * querying the file Blob, and wiring up the Row Handlers and Result Handlers.
 */
public with sharing class XLSXProcessorService {

    public class ProcessingRequest {
        public Id contentDocumentId;
        public String configDeveloperName;
        public Id relatedRecordId; // For error logging and result handler write-back
    }

    /**
     * Entry point from the Flow Invocable or direct Apex calls.
     */
    public static void processFiles(List<ProcessingRequest> requests) {
        if (requests == null || requests.isEmpty()) return;

        // 1. Gather all ContentDocumentIds and Config Names
        Set<Id> docIds = new Set<Id>();
        Set<String> configNames = new Set<String>();
        for (ProcessingRequest req : requests) {
            docIds.add(req.contentDocumentId);
            configNames.add(req.configDeveloperName);
        }

        // 2. Query Configurations
        Map<String, XLSX_Reader_Config__mdt> configs = new Map<String, XLSX_Reader_Config__mdt>();
        for (XLSX_Reader_Config__mdt config : [
            SELECT DeveloperName, Execution_Mode__c, Max_Row_Threshold__c,
                   Async_Threshold_Bytes__c, Row_Handler_Class__c, Result_Handler_Class__c, Error_Handling_Behavior__c,
                   Empty_Result_Behaviour__c, Hidden_Row_Handling__c, Totals_Row_Handling__c, Header_Row_Number__c
            FROM XLSX_Reader_Config__mdt
            WHERE DeveloperName IN :configNames
        ]) {
            configs.put(config.DeveloperName, config);
        }

        // 3. Query ContentVersions (the actual files). WITH USER_MODE so a Flow user can never pull
        // back file data they don't have access to, even though this class runs with sharing.
        Map<Id, ContentVersion> versionsByDocId = new Map<Id, ContentVersion>();
        for (ContentVersion cv : [
            SELECT ContentDocumentId, ContentSize, VersionData, PathOnClient
            FROM ContentVersion
            WHERE ContentDocumentId IN :docIds AND IsLatest = true
            WITH USER_MODE
        ]) {
            versionsByDocId.put(cv.ContentDocumentId, cv);
        }

        // 4. Route Execution (Sync vs Async). Every request is independently try/caught so one bad
        // file or a hit against the async enqueue limit can't take down the rest of the batch.
        for (ProcessingRequest req : requests) {
            ContentVersion cv = versionsByDocId.get(req.contentDocumentId);
            XLSX_Reader_Config__mdt config = configs.get(req.configDeveloperName);

            if (cv == null || config == null) continue;

            try {
                if (!cv.PathOnClient.toLowerCase().endsWith('.xlsx')) {
                    throw new XLSXParserException('Invalid file type. Only .xlsx is supported: ' + cv.PathOnClient);
                }

                Boolean useAsync = false;
                if (config.Execution_Mode__c == 'Async') {
                    useAsync = true;
                } else if (config.Execution_Mode__c == 'Auto') {
                    // Route on the UNCOMPRESSED sheet size, not ContentSize (compressed) - compressed
                    // size can look tiny for a highly-repetitive file that still spikes heap on Blob.toString().
                    Long uncompressedSize = XLSXParser.peekUncompressedSheetSize(cv.VersionData);
                    Long threshold = config.Async_Threshold_Bytes__c != null ? config.Async_Threshold_Bytes__c.longValue() : 500000L;
                    if (uncompressedSize > threshold) {
                        useAsync = true;
                    }
                }

                if (useAsync) {
                    System.enqueueJob(new XLSXAsyncProcessor(req, config));
                } else {
                    runPipeline(config, req, cv.VersionData);
                }
            } catch (Exception e) {
                logError(config, req, e.getMessage(), e.getStackTraceString());
            }
        }
    }

    /**
     * The single execution pipeline shared by the Sync path (above) and XLSXAsyncProcessor - so the
     * two paths can never drift into wiring the configured handlers differently again. Instantiates
     * the row handler and result handler as two INDEPENDENT roles (Row_Handler_Class__c /
     * Result_Handler_Class__c) rather than assuming one class does both.
     */
    public static void runPipeline(XLSX_Reader_Config__mdt config, ProcessingRequest req, Blob fileData) {
        IXLSXRowHandler rowHandler = instantiateRowHandler(config);
        IXLSXResultHandler resultHandler = instantiateResultHandler(config, req.relatedRecordId);

        XLSXParser parser = new XLSXParser(rowHandler, config);
        parser.process(fileData);

        if (rowHandler instanceof IXLSXWarningSource) {
            for (String warning : ((IXLSXWarningSource) rowHandler).getWarnings()) {
                System.debug(LoggingLevel.WARN, 'XLSX row warning [' + config.DeveloperName + ']: ' + warning);
            }
        }

        resultHandler.handleResult(rowHandler.getResult());
    }

    private static IXLSXRowHandler instantiateRowHandler(XLSX_Reader_Config__mdt config) {
        if (String.isBlank(config.Row_Handler_Class__c)) {
            throw new XLSXParserException('Row_Handler_Class__c is not configured on ' + config.DeveloperName + '.');
        }
        Type handlerType = Type.forName(config.Row_Handler_Class__c);
        if (handlerType == null) {
            throw new XLSXParserException('Row_Handler_Class__c \'' + config.Row_Handler_Class__c + '\' could not be found.');
        }
        Object instance = handlerType.newInstance();
        if (!(instance instanceof IXLSXRowHandler)) {
            throw new XLSXParserException('Row_Handler_Class__c \'' + config.Row_Handler_Class__c + '\' does not implement IXLSXRowHandler.');
        }
        IXLSXRowHandler rowHandler = (IXLSXRowHandler) instance;
        rowHandler.initialize(config);
        return rowHandler;
    }

    private static IXLSXResultHandler instantiateResultHandler(XLSX_Reader_Config__mdt config, Id relatedRecordId) {
        if (String.isBlank(config.Result_Handler_Class__c)) {
            throw new XLSXParserException('Result_Handler_Class__c is not configured on ' + config.DeveloperName + '.');
        }
        Type handlerType = Type.forName(config.Result_Handler_Class__c);
        if (handlerType == null) {
            throw new XLSXParserException('Result_Handler_Class__c \'' + config.Result_Handler_Class__c + '\' could not be found.');
        }
        Object instance = handlerType.newInstance();
        if (!(instance instanceof IXLSXResultHandler)) {
            throw new XLSXParserException('Result_Handler_Class__c \'' + config.Result_Handler_Class__c + '\' does not implement IXLSXResultHandler.');
        }
        IXLSXResultHandler resultHandler = (IXLSXResultHandler) instance;
        resultHandler.initialize(config, relatedRecordId);
        return resultHandler;
    }

    public static void logError(XLSX_Reader_Config__mdt config, ProcessingRequest req, String message, String stackTrace) {
        if (config.Error_Handling_Behavior__c == 'Throw Exception') {
            throw new XLSXParserException(message);
        } else if (config.Error_Handling_Behavior__c == 'Fail Silently') {
            return;
        }

        // Log Error. Intentionally system-mode: an error logger that only works when the acting
        // user happens to have create access on the log object defeats its own purpose.
        XLSX_Error_Log__c log = new XLSX_Error_Log__c();
        log.Error_Message__c = message;
        log.Stack_Trace__c = stackTrace;
        log.Related_Record_Id__c = req.relatedRecordId;
        insert log;
    }
}
