/**
 * Interface representing a pure Result handler for the XLSX Parser.
 * Once the parser and row handlers have finished their work,
 * the resulting object (which could be a List of SObjects, an aggregate Decimal, etc.)
 * is passed to this interface for final Database commit or downstream processing.
 * This completely isolates DML operations from the parser logic.
 */
public interface IXLSXResultHandler {
    /**
     * Called before processing starts to provide the handler with the configuration
     * and the related record Id from the request (for write-back or error-linkage use cases).
     * relatedRecordId may be null - handlers that don't need it can ignore the parameter.
     */
    void initialize(XLSX_Reader_Config__mdt config, Id relatedRecordId);

    /**
     * Executes the final DML or logic based on the extracted data.
     *
     * @param parsedResult The final result object produced by the Row Handler.
     */
    void handleResult(Object parsedResult);
}
