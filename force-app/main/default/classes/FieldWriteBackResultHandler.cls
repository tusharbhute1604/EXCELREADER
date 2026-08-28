/**
 * Out-of-the-box result handler for the "Data Aggregation" capability: writes an
 * AggregateRowHandler.AggregateResult onto a single field on the request's Related Record Id.
 * Pairs with AggregateRowHandler - set as Result_Handler_Class__c alongside
 * Row_Handler_Class__c = AggregateRowHandler.
 */
public with sharing class FieldWriteBackResultHandler implements IXLSXResultHandler {

    private XLSX_Reader_Config__mdt config;
    private Id relatedRecordId;
    private String targetField;

    public void initialize(XLSX_Reader_Config__mdt config, Id relatedRecordId) {
        this.config = config;
        this.relatedRecordId = relatedRecordId;

        List<XLSX_Field_Mapping__mdt> specs = [
            SELECT Target_Field__c
            FROM XLSX_Field_Mapping__mdt
            WHERE Config__c = :config.Id AND Aggregate_Function__c != null
            LIMIT 1
        ];
        if (!specs.isEmpty()) {
            this.targetField = specs[0].Target_Field__c;
        }
    }

    public void handleResult(Object parsedResult) {
        if (!(parsedResult instanceof AggregateRowHandler.AggregateResult)) {
            throw new XLSXParserException('FieldWriteBackResultHandler expects a result produced by AggregateRowHandler. Check that Row_Handler_Class__c is set to AggregateRowHandler.');
        }
        AggregateRowHandler.AggregateResult aggResult = (AggregateRowHandler.AggregateResult) parsedResult;

        if (aggResult.skip == true) {
            return;
        }
        if (this.relatedRecordId == null) {
            throw new XLSXParserException('FieldWriteBackResultHandler requires a Related Record Id to write the aggregate result to.');
        }
        if (String.isBlank(this.targetField)) {
            throw new XLSXParserException('No aggregation field mapping (XLSX_Field_Mapping__mdt with Aggregate_Function__c set) found for config ' + (this.config != null ? this.config.DeveloperName : '') + '.');
        }

        SObject record = this.relatedRecordId.getSObjectType().newSObject(this.relatedRecordId);
        record.put(this.targetField, coerceForTargetField(aggResult.value));
        Database.update(record, true, AccessLevel.USER_MODE);
    }

    /**
     * AggregateRowHandler always produces Decimal/Integer math results, but the target field might
     * be a genuine Integer field - SObject.put() throws "Illegal assignment from Decimal to Integer"
     * rather than coercing, so round explicitly when the target field's real type calls for it.
     */
    private Object coerceForTargetField(Object value) {
        if (!(value instanceof Decimal) || value == null) {
            return value;
        }
        Schema.DescribeFieldResult fieldDescribe = this.relatedRecordId.getSObjectType().getDescribe().fields.getMap().get(this.targetField)?.getDescribe();
        if (fieldDescribe != null && fieldDescribe.getType() == Schema.DisplayType.INTEGER) {
            return ((Decimal) value).intValue();
        }
        return value;
    }
}
