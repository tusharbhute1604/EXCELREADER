/**
 * A standard Row Handler that translates Excel Rows into Salesforce SObjects
 * by leveraging XLSX_Field_Mapping__mdt records linked to the active configuration.
 */
public with sharing class SObjectCreatorRowHandler implements IXLSXRowHandler, IXLSXWarningSource {

    private XLSX_Reader_Config__mdt config;
    private List<XLSX_Field_Mapping__mdt> mappings;
    private List<SObject> parsedRecords;
    private String targetSObjectType;
    private List<String> warnings = new List<String>();

    // Map of Excel Column Header (e.g. "First Name") to Salesforce Field API Name (e.g. "FirstName"),
    // built once the configured header row is seen.
    private Map<String, String> colLetterToFieldMap = new Map<String, String>();

    // The literal Excel row number that holds the headers. Defaults to 1 so existing configs with
    // Header_Row_Number__c left blank keep their original behavior unchanged.
    private Integer headerRowNumber = 1;

    // Field API name -> field type, cached once so per-row processing never re-describes.
    private Map<String, Schema.DisplayType> fieldTypeCache = new Map<String, Schema.DisplayType>();

    public void initialize(XLSX_Reader_Config__mdt config) {
        this.config = config;
        this.parsedRecords = new List<SObject>();
        this.headerRowNumber = (config != null && config.Header_Row_Number__c != null)
            ? config.Header_Row_Number__c.intValue()
            : 1;

        // Only mapping rows with no Aggregate_Function__c are record-creation column mappings -
        // rows with a function set belong to AggregateRowHandler instead.
        this.mappings = [
            SELECT Excel_Column_Header__c, Target_Field__c, Target_SObject__c
            FROM XLSX_Field_Mapping__mdt
            WHERE Config__c = :config.Id AND Aggregate_Function__c = null
        ];

        if (!this.mappings.isEmpty()) {
            this.targetSObjectType = this.mappings[0].Target_SObject__c;
            cacheFieldTypes();
        }
    }

    public void processRow(Integer rowNumber, Map<String, String> rowData) {
        if (this.targetSObjectType == null) return;

        // The header row is whatever Header_Row_Number__c says (row 1 by default) - not "whichever
        // row we see first" and not necessarily the sheet's physical first row. A title/banner row,
        // or blank rows, above the real headers is common in real files and must not be mistaken
        // for the header row.
        if (rowNumber == this.headerRowNumber) {
            for (String colLetter : rowData.keySet()) {
                String headerName = rowData.get(colLetter);
                for (XLSX_Field_Mapping__mdt mapping : this.mappings) {
                    if (mapping.Excel_Column_Header__c.equalsIgnoreCase(headerName)) {
                        this.colLetterToFieldMap.put(colLetter, mapping.Target_Field__c);
                        break;
                    }
                }
            }
            return; // We do not create an SObject for the header row
        }

        // Process data rows
        Type sObjType = Type.forName(this.targetSObjectType);
        if (sObjType != null) {
            SObject record = (SObject) sObjType.newInstance();
            Boolean hasData = false;

            for (String colLetter : rowData.keySet()) {
                String fieldApiName = this.colLetterToFieldMap.get(colLetter);
                if (fieldApiName != null) {
                    String rawValue = rowData.get(colLetter);
                    if (String.isNotBlank(rawValue)) {
                        try {
                            record.put(fieldApiName, convertValue(fieldApiName, rawValue));
                            hasData = true;
                        } catch (Exception e) {
                            this.warnings.add('Row ' + rowNumber + ', field ' + fieldApiName + ': could not set value \'' + rawValue + '\' (' + e.getMessage() + ')');
                        }
                    }
                }
            }

            if (hasData) {
                this.parsedRecords.add(record);
            }
        }
    }

    public void finishProcessing() {
        // Nothing to do for this handler specifically, it holds the list in memory
    }

    /**
     * Expose the parsed records to the ResultHandler.
     */
    public Object getResult() {
        return this.parsedRecords;
    }

    /**
     * Per-field values that couldn't be set (bad type, describe mismatch, etc.) - the row is still
     * inserted with whatever DID map cleanly, but callers can see what got skipped.
     */
    public List<String> getWarnings() {
        return this.warnings;
    }

    private void cacheFieldTypes() {
        if (String.isBlank(this.targetSObjectType)) return;
        Schema.SObjectType sObjType = Schema.getGlobalDescribe().get(this.targetSObjectType);
        if (sObjType == null) return;

        Map<String, Schema.SObjectField> fieldMap = sObjType.getDescribe().fields.getMap();
        for (XLSX_Field_Mapping__mdt mapping : this.mappings) {
            Schema.SObjectField field = fieldMap.get(mapping.Target_Field__c);
            if (field != null) {
                this.fieldTypeCache.put(mapping.Target_Field__c, field.getDescribe().getType());
            }
        }
    }

    /**
     * Routes Date/Datetime target fields through XLSXDateConverter when the raw cell value is a
     * numeric Excel serial, and routes Currency/Percent/Double/Integer target fields through an
     * explicit Decimal (or Integer) parse - instead of relying on SObject.put()'s implicit String
     * coercion, which does not exist for any of these types. put() throws "Illegal assignment from
     * String to Decimal" (or "...to Integer") for every numeric field regardless of whether the
     * string is well-formed, so without this every numeric target field would fail on every row.
     */
    private Object convertValue(String fieldApiName, String rawValue) {
        Schema.DisplayType fieldType = this.fieldTypeCache.get(fieldApiName);
        if ((fieldType == Schema.DisplayType.DATE || fieldType == Schema.DisplayType.DATETIME) && isNumeric(rawValue)) {
            Datetime converted = XLSXDateConverter.convertToDatetime(Decimal.valueOf(rawValue));
            if (fieldType == Schema.DisplayType.DATE) {
                return converted != null ? converted.dateGmt() : null;
            }
            return converted;
        }
        if (isNumericFieldType(fieldType) && isNumeric(rawValue)) {
            Decimal parsed = Decimal.valueOf(rawValue);
            // Integer fields need a real Integer - Decimal.intValue() truncates toward zero, the same
            // convention FieldWriteBackResultHandler.coerceForTargetField() already uses, so a value
            // like '12.7' becomes 12, not a rejected row. Currency/Percent/Double all accept Decimal
            // directly. Deliberately NOT a ternary here: `cond ? parsed.intValue() : parsed` unifies
            // both branches to a common numeric type and silently widens the Integer branch back into
            // a Decimal, which then fails put() with "Illegal assignment from Decimal to Integer" -
            // separate if/else returns avoid that implicit type promotion entirely.
            if (fieldType == Schema.DisplayType.INTEGER) {
                return parsed.intValue();
            }
            return parsed;
        }
        return rawValue;
    }

    /**
     * The Salesforce numeric DisplayTypes that need an explicit Apex numeric type for put() - a
     * custom "Number" field describes as DOUBLE regardless of its configured decimal places.
     */
    private Boolean isNumericFieldType(Schema.DisplayType fieldType) {
        return fieldType == Schema.DisplayType.CURRENCY
            || fieldType == Schema.DisplayType.PERCENT
            || fieldType == Schema.DisplayType.DOUBLE
            || fieldType == Schema.DisplayType.INTEGER;
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
