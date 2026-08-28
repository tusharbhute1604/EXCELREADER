# XLSX Reader - Use Cases & Examples

This document outlines the various use cases supported by the custom Salesforce XLSX Reader utility. It details how to configure the necessary Custom Metadata Types (CMDT) and the steps to invoke the utility for each scenario.

---

## Use Case 1: Simple Synchronous SObject Creation via Flow
**Scenario**: A user uploads a lightweight Excel file (e.g., a list of 500 Leads) through a Screen Flow. The business wants the records created immediately (synchronously) so the user sees the result on the next screen. If any error occurs, the Flow should catch it and display a friendly fault screen.

### 1. CMDT Configuration (`XLSX_Reader_Config__mdt`)
Create a new configuration record (e.g., `DeveloperName` = `Lead_Sync_Upload`):
- **Execution Mode**: `Sync`
- **Row Handler Class**: `SObjectCreatorRowHandler` (builds the in-memory records from parsed rows)
- **Result Handler Class**: `DatabaseInsertResultHandler` (persists them - this is a separate, independently-configurable role from the row handler)
- **Error Handling Behavior**: `Throw Exception` (Forces the Flow to follow a Fault Path if parsing fails)
- **Max Row Threshold**: `10000`

### 2. CMDT Field Mappings (`XLSX_Field_Mapping__mdt`)
Create child mapping records linked to the `Lead_Sync_Upload` config:
| Excel Column Header | Target SObject | Target Field |
| :--- | :--- | :--- |
| `First Name` | `Lead` | `FirstName` |
| `Last Name` | `Lead` | `LastName` |
| `Company Name` | `Lead` | `Company` |

### 3. Invocation Steps
1. Create a **Screen Flow**.
2. Add a **File Upload** component to the screen and capture the output `ContentDocumentId`.
3. Add an **Action** element calling the `@InvocableMethod` (`Process XLSX File` / `XLSXReaderInvocable`).
4. Pass the inputs:
   - **Content Document Id**: The ID from step 2.
   - **Configuration Developer Name**: `Lead_Sync_Upload`.
5. Connect a Fault Path to a custom error screen to elegantly handle exceptions.

---

## Use Case 2: Massive File Upload (Automatic Asynchronous Processing)
**Scenario**: Users periodically upload massive Excel files (e.g., 50,000 rows, 4MB) containing historical Account data. Processing this synchronously will breach Salesforce CPU and Heap limits. The utility needs to automatically detect the file size and process it in the background, logging any errors to a custom object rather than throwing exceptions to the user.

### 1. CMDT Configuration (`XLSX_Reader_Config__mdt`)
Create a new configuration record (e.g., `DeveloperName` = `Historical_Account_Import`):
- **Execution Mode**: `Auto` (The engine will decide whether to run Sync or Async based on the file's uncompressed sheet size, not the raw upload size).
- **Async Threshold Bytes**: `500000` (Any file over ~500KB uncompressed will automatically be shunted to a Queueable background job).
- **Row Handler Class**: `SObjectCreatorRowHandler`
- **Result Handler Class**: `DatabaseInsertResultHandler`
- **Error Handling Behavior**: `Log Error` (Because background Queueable jobs shouldn't throw unhandled exceptions. Instead, errors are safely written to the `XLSX_Error_Log__c` object).

### 2. CMDT Field Mappings (`XLSX_Field_Mapping__mdt`)
Linked to `Historical_Account_Import`:
| Excel Column Header | Target SObject | Target Field |
| :--- | :--- | :--- |
| `Account Name` | `Account` | `Name` |
| `Industry Type` | `Account` | `Industry` |

### 3. Invocation Steps
1. The user uploads the file via a standard Salesforce File Upload (e.g., attaching it to a specific Campaign record).
2. A **Record-Triggered Flow** (or Apex Trigger) on `ContentDocumentLink` fires when the file is attached to the Campaign.
3. The Flow calls the `Process XLSX File` invocable action.
4. Pass the inputs:
   - **Content Document Id**: The ID of the uploaded file.
   - **Configuration Developer Name**: `Historical_Account_Import`.
   - **Related Record Id**: The ID of the Campaign (so if errors happen, the `XLSX_Error_Log__c` record is linked back to the Campaign).

---

## Use Case 3: Complex Orchestration via Custom Apex Handlers
**Scenario**: The business receives a complex Excel file containing "Orders". Each row contains Customer Information, Product Information, and Pricing. Inserting this data requires creating an Account, a Contact, an Opportunity, and Opportunity Line Items with complex cross-referencing logic. The out-of-the-box `DatabaseInsertResultHandler` cannot handle this multi-object relational orchestration.

### 1. Build Custom Handlers (Apex)
A developer creates a custom class implementing the core interfaces to handle the complex relational logic.

```apex
public class ComplexOrderHandler implements IXLSXRowHandler, IXLSXResultHandler {
    private XLSX_Reader_Config__mdt config;
    private Id relatedRecordId;
    private List<ComplexOrderWrapper> wrappers = new List<ComplexOrderWrapper>();

    // IXLSXRowHandler.initialize - called before row processing starts.
    public void initialize(XLSX_Reader_Config__mdt config) {
        this.config = config;
    }

    // IXLSXResultHandler.initialize - called before handleResult, also receives the
    // request's Related Record Id directly (no need to smuggle it in separately).
    public void initialize(XLSX_Reader_Config__mdt config, Id relatedRecordId) {
        this.config = config;
        this.relatedRecordId = relatedRecordId;
    }

    public void processRow(Integer rowNumber, Map<String, String> rowData) {
        // Skip headers
        if (rowNumber == 1) return;
        
        // Extract raw data and build custom wrapper memory structures
        ComplexOrderWrapper wrap = new ComplexOrderWrapper();
        wrap.customerName = rowData.get('A'); // e.g., John Doe
        wrap.productCode = rowData.get('B'); // e.g., SKU-123
        wrappers.add(wrap);
    }
    
    public void finishProcessing() {}
    
    public Object getResult() {
        return wrappers;
    }

    public void handleResult(Object parsedResult) {
        List<ComplexOrderWrapper> data = (List<ComplexOrderWrapper>)parsedResult;
        
        // Perform complex Unit of Work DML orchestration
        // 1. Upsert Accounts
        // 2. Upsert Contacts
        // 3. Insert Opportunities
        // 4. Insert OpportunityLineItems
    }
}
```

Note: a class is free to implement both interfaces, as above - but `Row_Handler_Class__c` and `Result_Handler_Class__c` are still two independent configuration values, and the engine instantiates each independently - even pointed at the same class name, you get two separate instances, not one shared one. That's why data must flow through `getResult()` -> `handleResult(parsedResult)` (as above), not through instance fields you'd expect to be shared.

### 2. CMDT Configuration (`XLSX_Reader_Config__mdt`)
Create a new configuration record (e.g., `DeveloperName` = `Complex_Orders`):
- **Execution Mode**: `Auto`
- **Row Handler Class**: `ComplexOrderHandler`
- **Result Handler Class**: `ComplexOrderHandler` (Same class as the row handler here since it implements both interfaces - the engine dynamically instantiates whatever class each field names).

### 3. Invocation Steps
Can be invoked from Flow, or directly from an Apex Controller/Service:
```apex
XLSXProcessorService.ProcessingRequest req = new XLSXProcessorService.ProcessingRequest();
req.contentDocumentId = '069xxxxxxxxxxxx';
req.configDeveloperName = 'Complex_Orders';
req.relatedRecordId = '001xxxxxxxxxxxx';

XLSXProcessorService.processFiles(new List<XLSXProcessorService.ProcessingRequest>{req});
```

---

## Use Case 4: Aggregating Data and Updating a Parent Record (No Code)
**Scenario**: Users upload an Excel file containing a list of line items (e.g., "Expenses") to a parent record (e.g. a Case, Campaign, or custom object). Instead of creating individual child records in Salesforce, the business only wants to sum up the "Amount" column from the Excel file and write that total directly to a field on the parent record. This is the out-of-the-box "Data Aggregation" capability - no custom Apex needed.

### 1. CMDT Configuration (`XLSX_Reader_Config__mdt`)
Create a new configuration record (e.g., `DeveloperName` = `Expense_Aggregator`):
- **Execution Mode**: `Sync`
- **Row Handler Class**: `AggregateRowHandler`
- **Result Handler Class**: `FieldWriteBackResultHandler`
- **Error Handling Behavior**: `Throw Exception` (to alert the user immediately if aggregation fails)
- **Empty Result Behaviour**: leave blank to get the sensible per-function default (SUM/COUNT of an empty file is `0`; MIN/MAX/AVERAGE of an empty file is `null`), or set explicitly to `Zero`, `Null`, or `Skip` (skip the write-back entirely) to override it.

### 2. CMDT Field Mapping (`XLSX_Field_Mapping__mdt`)
Create exactly **one** mapping record linked to `Expense_Aggregator` with `Aggregate_Function__c` set - this single record fully specifies the aggregation (source column, function, and target field), unlike record-creation mappings which use one row per target field:
| Excel Column Header | Target Field | Aggregate Function |
| :--- | :--- | :--- |
| `Amount` | `Total_Expenses__c` (on the parent record) | `SUM` |

### 3. Invocation Steps
Pass the parent record's Id as `relatedRecordId` - that's the record `FieldWriteBackResultHandler` writes the result onto:
```apex
Id expenseReportId = 'a00xxxxxxxxxxxx';
Id contentDocId = '069xxxxxxxxxxxx';

XLSXProcessorService.ProcessingRequest req = new XLSXProcessorService.ProcessingRequest();
req.contentDocumentId = contentDocId;
req.configDeveloperName = 'Expense_Aggregator';
req.relatedRecordId = expenseReportId;

XLSXProcessorService.processFiles(new List<XLSXProcessorService.ProcessingRequest>{req});
```

---

## Use Case 5: Custom Aggregation Logic Beyond SUM/COUNT/MIN/MAX/AVERAGE
**Scenario**: The built-in `AggregateRowHandler` (Use Case 4) covers the five standard functions over a single column. When the calculation is more involved - a weighted average, a formula spanning multiple columns, currency conversion before summing - write a custom handler pair instead.

### 1. Build Custom Handlers (Apex)
A developer creates a custom class that accumulates the total amount while parsing rows, and then performs a single DML update on the parent record. The Related Record Id is available directly via `IXLSXResultHandler.initialize()` - no need to smuggle it in through a side channel.

```apex
public class WeightedAverageHandler implements IXLSXRowHandler, IXLSXResultHandler {
    private XLSX_Reader_Config__mdt config;
    private Id parentRecordId;
    private Decimal weightedSum = 0;
    private Decimal totalWeight = 0;

    // IXLSXRowHandler.initialize
    public void initialize(XLSX_Reader_Config__mdt config) {
        this.config = config;
    }

    // IXLSXResultHandler.initialize - relatedRecordId comes straight from the request, no side channel needed.
    public void initialize(XLSX_Reader_Config__mdt config, Id relatedRecordId) {
        this.config = config;
        this.parentRecordId = relatedRecordId;
    }

    public void processRow(Integer rowNumber, Map<String, String> rowData) {
        if (rowNumber == 1) return; // headers

        // Assumes Column B = value, Column C = weight - a calculation the built-in
        // AggregateRowHandler can't express since it only reads a single column.
        String valueStr = rowData.get('B');
        String weightStr = rowData.get('C');
        if (String.isNotBlank(valueStr) && String.isNotBlank(weightStr) && valueStr.isNumeric() && weightStr.isNumeric()) {
            Decimal weight = Decimal.valueOf(weightStr);
            this.weightedSum += Decimal.valueOf(valueStr) * weight;
            this.totalWeight += weight;
        }
    }

    public void finishProcessing() {}

    public Object getResult() {
        return this.totalWeight > 0 ? this.weightedSum / this.totalWeight : null;
    }

    public void handleResult(Object parsedResult) {
        if (parsedResult == null || this.parentRecordId == null) return;

        Expense_Report__c report = new Expense_Report__c(
            Id = this.parentRecordId,
            Weighted_Average_Amount__c = (Decimal) parsedResult
        );
        update report;
    }
}
```

### 2. CMDT Configuration (`XLSX_Reader_Config__mdt`)
Create a new configuration record (e.g., `DeveloperName` = `Expense_Weighted_Average`):
- **Execution Mode**: `Sync`
- **Row Handler Class**: `WeightedAverageHandler`
- **Result Handler Class**: `WeightedAverageHandler`
- **Error Handling Behavior**: `Throw Exception` (to alert the user immediately if aggregation fails).

### 3. Invocation Steps
```apex
Id expenseReportId = 'a00xxxxxxxxxxxx';
Id contentDocId = '069xxxxxxxxxxxx';

XLSXProcessorService.ProcessingRequest req = new XLSXProcessorService.ProcessingRequest();
req.contentDocumentId = contentDocId;
req.configDeveloperName = 'Expense_Weighted_Average';
req.relatedRecordId = expenseReportId;

XLSXProcessorService.processFiles(new List<XLSXProcessorService.ProcessingRequest>{req});
```

---

## Use Case 6: A Table That Doesn't Start at the Top of the Sheet (No Code)
**Scenario**: Finance exports a report where row 1 is a title ("Q3 Expense Report — Generated 2026-01-01"), row 2 is blank, and the real header row - Item, Amount, Date - doesn't start until row 3. Real-world exports routinely look like this, and by default the engine assumes the header row is the sheet's literal row 1.

### 1. CMDT Configuration (`XLSX_Reader_Config__mdt`)
On the existing config record (works for both record-creation and aggregation configs - `Lead_Sync_Upload`, `Expense_Aggregator`, whatever you're already using):
- **Header Row Number**: `3` (the literal Excel row number - as shown in Excel's own row gutter - that holds the column headers)

Leave it blank for the default, unchanged behavior (row 1). This is the only setting that changes; the field mappings are configured exactly as in any other use case, matched by header **text**, not position - so it doesn't matter whether your table also starts partway across the columns (e.g. column C instead of A). Only the *row* the headers sit on needs to be told to the engine explicitly.

### 2. What to watch for
- The row number is literal - if you hide rows 1-2 in Excel and set `Hidden_Row_Handling__c = Exclude`, the header row is *still* row 3, not row 1. Hiding rows never renumbers the rows below them.
- Rows above the configured header row are harmless to leave in the file - they're never mistaken for data, because the column-to-field mapping doesn't exist yet when they arrive, so nothing about them gets processed.
- This is a config-only fix; no field mapping records change.

### 3. Invocation Steps
Identical to whichever use case you're layering this onto - Screen Flow, Record-Triggered Flow, or a direct `XLSXProcessorService.processFiles()` call. `Header_Row_Number__c` requires no changes anywhere else in the pipeline.
