/**
 * Out-of-the-box row handler for the "Data Aggregation" capability: reads one configured column
 * and computes SUM / COUNT / MIN / MAX / AVERAGE across all data rows, per the single
 * XLSX_Field_Mapping__mdt row for this config that has Aggregate_Function__c set.
 * Pairs with FieldWriteBackResultHandler, which writes the AggregateResult to a target record.
 */
public with sharing class AggregateRowHandler implements IXLSXRowHandler {

    /**
     * Wraps the computed value together with whether the result-handler write-back should be
     * skipped entirely - a plain null return can't distinguish "write null" from "write nothing".
     */
    public class AggregateResult {
        public Object value;
        public Boolean skip = false;
    }

    private XLSX_Reader_Config__mdt config;
    private String sourceColumnHeader;
    private String aggregateFunction;
    private String sourceColLetter;

    // The literal Excel row number that holds the headers. Defaults to 1 so existing configs with
    // Header_Row_Number__c left blank keep their original behavior unchanged
    private Integer headerRowNumber = 1;

    private Integer count = 0;
    private Decimal runningSum = 0;
    private Decimal runningMin;
    private Decimal runningMax;

    public void initialize(XLSX_Reader_Config__mdt config) {
        this.config = config;
        this.headerRowNumber = (config != null && config.Header_Row_Number__c != null)
            ? config.Header_Row_Number__c.intValue()
            : 1;

        List<XLSX_Field_Mapping__mdt> specs = [
            SELECT Excel_Column_Header__c, Aggregate_Function__c
            FROM XLSX_Field_Mapping__mdt
            WHERE Config__c = :config.Id AND Aggregate_Function__c != null
            LIMIT 1
        ];
        if (!specs.isEmpty()) {
            this.sourceColumnHeader = specs[0].Excel_Column_Header__c;
            this.aggregateFunction = specs[0].Aggregate_Function__c;
        }
    }

    public void processRow(Integer rowNumber, Map<String, String> rowData) {
        if (this.sourceColumnHeader == null) return;

        // The header row is whatever Header_Row_Number__c says (row 1 by default) - see the same
        // note in SObjectCreatorRowHandler.processRow().
        if (rowNumber == this.headerRowNumber) {
            for (String colLetter : rowData.keySet()) {
                if (this.sourceColumnHeader.equalsIgnoreCase(rowData.get(colLetter))) {
                    this.sourceColLetter = colLetter;
                    break;
                }
            }
            return;
        }

        if (this.sourceColLetter == null) return;

        String rawValue = rowData.get(this.sourceColLetter);
        if (!isNumeric(rawValue)) return;

        Decimal value = Decimal.valueOf(rawValue);
        this.count++;
        this.runningSum += value;
        this.runningMin = (this.runningMin == null || value < this.runningMin) ? value : this.runningMin;
        this.runningMax = (this.runningMax == null || value > this.runningMax) ? value : this.runningMax;
    }

    public void finishProcessing() {
        // All state already maintained incrementally in processRow
    }

    public Object getResult() {
        AggregateResult result = new AggregateResult();
        Boolean hasData = this.count > 0;
        String emptyBehavior = this.config != null ? this.config.Empty_Result_Behaviour__c : null;

        if (!hasData) {
            if (emptyBehavior == 'Skip') {
                result.skip = true;
            } else if (emptyBehavior == 'Null') {
                result.value = null;
            } else if (emptyBehavior == 'Zero') {
                result.value = 0;
            } else {
                // No explicit override: SUM/COUNT of nothing is 0, MIN/MAX/AVERAGE of nothing is null.
                result.value = (this.aggregateFunction == 'SUM' || this.aggregateFunction == 'COUNT') ? 0 : null;
            }
            return result;
        }

        if (this.aggregateFunction == 'COUNT') {
            result.value = this.count;
        } else if (this.aggregateFunction == 'MIN') {
            result.value = this.runningMin;
        } else if (this.aggregateFunction == 'MAX') {
            result.value = this.runningMax;
        } else if (this.aggregateFunction == 'AVERAGE') {
            result.value = this.runningSum / this.count;
        } else {
            result.value = this.runningSum; // SUM, and the fallback for an unrecognized function
        }
        return result;
    }

    private Boolean isNumeric(String value) {
        if (String.isBlank(value)) return false;
        try {
            Decimal.valueOf(value);
            return true;
        } catch (Exception e) {
            return false;
        }
    }
}
