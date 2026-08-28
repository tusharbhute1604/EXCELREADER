/**
 * Interface representing a pure row handler for the XLSX Parser.
 * The parser will stream XML row by row, and pass each row of data 
 * to an implementation of this interface to process.
 */
public interface IXLSXRowHandler {
    /**
     * Called before processing starts to provide the handler with the configuration.
     */
    void initialize(XLSX_Reader_Config__mdt config);

    /**
     * Called by the parser for every valid row found in the Excel sheet.
     * 
     * @param rowNumber The Excel row number (1-indexed)
     * @param rowData A map of Column Letter (e.g., 'A', 'B') to Cell Value (String)
     */
    void processRow(Integer rowNumber, Map<String, String> rowData);

    /**
     * Called when the parser has finished reading the entire sheet.
     * Implementations can use this to finalize any internal state.
     */
    void finishProcessing();

    /**
     * Returns the final result of the processing (e.g., List<SObject>, Decimal, etc.)
     * to be handed over to the Result Handler.
     */
    Object getResult();
}
