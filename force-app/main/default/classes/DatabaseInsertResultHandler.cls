/**
 * A concrete result handler that takes the list of parsed SObjects and inserts them.
 */
public with sharing class DatabaseInsertResultHandler implements IXLSXResultHandler {

    private static final Integer CHUNK_SIZE = 200;

    private XLSX_Reader_Config__mdt config;

    public void initialize(XLSX_Reader_Config__mdt config, Id relatedRecordId) {
        this.config = config;
    }

    public void handleResult(Object parsedResult) {
        if (!(parsedResult instanceof List<SObject>)) {
            throw new XLSXParserException('DatabaseInsertResultHandler expects a List<SObject> result. Check that Row_Handler_Class__c is set to a row handler that builds records (e.g. SObjectCreatorRowHandler).');
        }
        List<SObject> records = (List<SObject>) parsedResult;
        if (records.isEmpty()) {
            return;
        }

        // Chunk into safe batches and allow partial success (Database.insert(records, false, ...))
        // rather than one unchunked insert - a single all-or-nothing DML call on a large parsed
        // result sits right at (or over) the per-transaction DML row ceiling and discards everything
        // on the first bad record. USER_MODE so this insert respects the acting Flow/Apex user's
        // CRUD/FLS rather than running as full system mode.
        List<String> failureMessages = new List<String>();
        Integer failureCount = 0;

        for (Integer start = 0; start < records.size(); start += CHUNK_SIZE) {
            Integer stop = Math.min(start + CHUNK_SIZE, records.size());
            List<SObject> chunk = new List<SObject>();
            for (Integer i = start; i < stop; i++) {
                chunk.add(records[i]);
            }

            List<Database.SaveResult> results = Database.insert(chunk, false, AccessLevel.USER_MODE);
            for (Integer i = 0; i < results.size(); i++) {
                Database.SaveResult result = results[i];
                if (!result.isSuccess()) {
                    failureCount++;
                    if (failureMessages.size() < 10) {
                        List<String> errorTexts = new List<String>();
                        for (Database.Error err : result.getErrors()) {
                            errorTexts.add(err.getStatusCode() + ': ' + err.getMessage());
                        }
                        failureMessages.add('Row ' + (start + i) + ' - ' + String.join(errorTexts, '; '));
                    }
                }
            }
        }

        if (failureCount > 0) {
            String summary = failureCount + ' of ' + records.size() + ' record(s) failed to insert. First failures: ' + String.join(failureMessages, ' | ');
            throw new XLSXParserException(summary);
        }
    }
}
