# Solution Design: Reusable Excel (XLSX) Reader Utility

## 1. Executive Summary

Salesforce teams frequently receive structured business data in Excel (`.xlsx`) files. This project delivers a **Metadata-Driven Reusable XLSX Reader Utility** built natively on Salesforce. It allows Administrators to process Excel files automatically—without writing any new code—by configuring rules in the Setup menu. 

---

## 2. Key Capabilities & Use Cases

### Use Case A: Data Aggregation (Calculations)
Reads a specified column, calculates the total (SUM, COUNT, MIN, MAX, AVERAGE), and returns the number to Salesforce Flow or Apex to be saved.

### Use Case B: Dynamic Record Creation (Rows to Records)
Using a simple configuration table, Admins map Excel column headers to Salesforce fields. The utility reads the spreadsheet and emits the mapped records to a handler for insertion.

---

## 3. How It Works (Business & Operational View)

We have intentionally designed this utility to handle the "quirks" of real-world Excel files safely and reliably:

- **Smart Data Handling:** 
  - **Dates:** Excel stores dates strangely. The utility converts Excel dates into clean, accurate Salesforce Date/Times anchored to GMT (accounting for the 1900 leap-year bug).
  - **Text-Numbers (SAP Exports):** If a system exports numbers as text (`'100`), the utility is smart enough to convert it back to a number.
  - **Percents:** Automatically flags if a column contains percent formats (`15%` is stored as `0.15`), which can skew aggregations.
- **Ignoring the Noise:** 
  - **Charts & Macros:** Safely ignores complex elements like Pivot Tables and `.xlsm` files.
  - **Hidden / Filtered Rows:** If a user filters an Excel sheet, they only see a subset of rows. Admins can configure the utility to intentionally EXCLUDE hidden rows so the system matches what the human saw!
  - **Excel Table Totals:** If a user formats data as an "Excel Table" and turns on the Totals row, standard parsers will double-count the total. This utility natively reads the hidden Table configuration and explicitly skips the totals row.
- **Empty Result Semantics:** If a file is completely empty, a SUM returns `0`, but an AVERAGE or MIN/MAX correctly returns `null`.
- **Graceful Error Handling:** If a severely broken file is processed (e.g. via Email-to-Case), the utility logs the error to a dedicated `XLSX_Error_Log__c` tab and stops without crashing the parent transaction.

---

## 4. Technical Architecture (For Developers & Architects)

### 4.1. Core Engine (Pure Functions)
The central architectural decision is that **the reader is a pure function**. It does absolutely ZERO DML natively.
- **Parser (`XLSXParser.cls`)**: Uses `System.XmlStreamReader` to stream XML, minimizing heap size.
- **Row Handlers (`IXLSXRowHandler`)**: The parser emits rows to handlers (`Aggregator` or `DynamicRecordBuilder`).
- **Result Handlers (`IXLSXResultHandler`)**: Once processing is complete, the final result is passed to a configurable Result Handler (e.g., `FieldWriteBackHandler` or a custom Apex class) which is solely responsible for performing the DML.

### 4.2. Configuration Data Model (CMDT)
- **Parent CMDT (`XLSX_Reader_Config__mdt`)**: 
  - `Execution_Mode__c`: (Sync / Async / Auto).
  - `Hidden_Row_Handling__c`: (INCLUDE / EXCLUDE).
  - `Totals_Row_Handling__c`: (INCLUDE / EXCLUDE).
  - `Empty_Result_Behaviour__c`: (ZERO / NULL / SKIP).
  - `Error_Handling_Behavior__c`: (Log Error, Throw Exception, Fail Silently).
  - `Result_Handler_Class__c`: Defines which Apex class performs the final DML.
- **Child CMDT (`XLSX_Field_Mapping__mdt`)**: Used strictly for the "Dynamic Record Creation" mapping.

### 4.3. The Heap Budget (Governor Limits)
> [!WARNING]
> While `XmlStreamReader` streams XML nodes, it still requires the entire raw XML payload as an in-memory `String`. The absolute peak memory spike occurs during `Blob.toString()`, where the Heap holds both the raw Zip Blob and the expanded String simultaneously. 

Because this peak can easily exceed the 6MB Sync / 12MB Async limits for large files, **Phase 0** of execution will be a strict viability gate to measure `Blob.toString()` limits using programmatic testing before the rest of the engine is built.

### 4.4. Heap Headroom Strategy (Phase 0 Results)
Our Phase 0 measurements proved that `Blob.toString()` is the primary memory spike. A 25,000-row file consumes ~5.91 MB of the 6 MB Synchronous limit. 
To prevent the utility from crashing active transactions (which are already consuming Heap memory), we will enforce a strict **~40% Headroom Buffer** in our configuration defaults:
- **`Max_Row_Threshold__c`**: Defaulted to **10,000 rows** (aligns safely with the 10,000 DML row limit for record creation).
- **`Async_Threshold_Bytes__c`**: If a file exceeds roughly **500 KB** (approx. 3 MB of heap), the utility will auto-route to Asynchronous execution (`Execution_Mode__c = AUTO`) to leverage the 12 MB Async limit.

---

## 5. Rollout & Execution Phases

We will execute in strict phases:
1. **Phase 0 (Viability Gate):** Because Data Loss Prevention (DLP) rules prohibit testing with real business files, we will build an `XLSXTestFixtureFactory` to programmatically generate synthetic Excel files (1k, 10k, 50k rows) directly in Apex memory using `Compression.ZipWriter`. We will run micro-measurements on these synthetic files to find the true Heap ceiling of `Blob.toString()` and define our size constraints.
2. **Phase 1 (Core & Types):** Build the `XLSXDateConverter` (pure math, highest defect risk) and the core XML Streaming Parser.
3. **Phase 2 (Handlers):** Build the pure `IXLSXRowHandler` and `IXLSXResultHandler` interfaces.
4. **Phase 3 (Orchestration):** Wire up the Custom Metadata, Async Queueable limits, and Error Logging.
5. **Phase 4 (Packaging):** Finalize tests and prepare the unlocked package.
