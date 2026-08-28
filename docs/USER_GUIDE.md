# XLSX Reader — User Guide

A plain-language manual for configuring and running the XLSX import engine. This covers what it does, how to set it up, and what every setting means — no Apex knowledge required for the common cases. For narrower "recipe" style walkthroughs of five specific scenarios, see [EXAMPLES.md](EXAMPLES.md); this guide is the fuller reference those examples are drawn from.

> A polished, navigable version of this same content is also published as a Claude artifact, if you'd rather read it in a browser with a sidebar and search.

---

## Table of Contents

- [What this is](#what-this-is)
- [How it works](#how-it-works)
- [The two things you configure](#the-two-things-you-configure)
- [Sync, Async & Auto](#sync-async--auto)
- [Hidden rows, totals rows & dates](#hidden-rows-totals-rows--dates)
- [Tables that don't start at the top of the sheet](#tables-that-dont-start-at-the-top-of-the-sheet)
- [Quick start: your first import](#quick-start-your-first-import)
- [Reference: XLSX_Reader_Config__mdt fields](#reference-xlsx_reader_configmdt-fields)
- [Reference: XLSX_Field_Mapping__mdt fields](#reference-xlsx_field_mappingmdt-fields)
- [Built-in row handlers](#built-in-row-handlers)
- [How decimals and rounding work](#how-decimals-and-rounding-work)
- [Built-in result handlers](#built-in-result-handlers)
- [Where errors go](#where-errors-go)
- [Six worked examples](#six-worked-examples)
- [Running it from Flow](#running-it-from-flow)
- [Running it from Apex](#running-it-from-apex)
- [Custom handlers, for developers](#custom-handlers-for-developers)
- [Troubleshooting & FAQ](#troubleshooting--faq)
- [Cheat sheet](#cheat-sheet)

---

## What this is

Think of XLSX Reader as a translator that sits between an uploaded Excel file and your Salesforce data. Someone uploads a spreadsheet — a list of Leads, a batch of expenses, a stack of historical Accounts — and this engine reads it, row by row, and does something useful with it: create records, add up a column, or run whatever custom logic your business needs.

The important idea is that **you control what it does through configuration, not code**. Two Custom Metadata Types — `XLSX_Reader_Config__mdt` and `XLSX_Field_Mapping__mdt` — describe the whole job: which columns map to which fields, whether to run instantly or in the background, and what to do if something goes wrong. For the two most common jobs — "create records from rows" and "add up a column and write the total somewhere" — you never touch Apex at all.

> **Good to know:** This package doesn't ship a file-upload screen of its own. You pair it with a standard Salesforce upload point — a Screen Flow's File Upload component, or a file attached to a record — and this engine takes it from there.

---

## How it works

Every file goes through the same five stops. What happens at stops 3 and 4 is entirely up to your configuration.

```
1. File uploaded  →  2. Parser reads it  →  3. Row Handler  →  4. Result Handler  →  5. Done
   (ContentVersion)     (streamed, row       (YOU CONFIGURE:     (YOU CONFIGURE:       (records exist,
                         by row, never        builds an in-       saves that result     or errors are
                         loaded whole)         memory result)      — inserts records,    logged)
                                                                    writes a total, etc.)
```

One detail worth knowing if you ever look at how rows are read: the parser hands each row to the handler as data keyed by **spreadsheet column letter** — `A`, `B`, `C`, ... — not by whatever text is in your header row. The built-in handlers read the configured header row (row 1 by default — see [Tables that don't start at the top of the sheet](#tables-that-dont-start-at-the-top-of-the-sheet)) and work out the letter-to-field mapping from there, the same way you'd read a spreadsheet yourself: "column C is Company Name."

---

## The two things you configure

Everything about a specific import job lives in one parent record and its children. Get comfortable with these two objects and you can configure almost any scenario without asking a developer.

### `XLSX_Reader_Config__mdt` — the job's settings

One record per "type of import." It answers questions like: should this run instantly or in the background? What Apex class builds the records? What happens if a row is bad? Give it a memorable `DeveloperName` (e.g. `Lead_Sync_Upload`) — that name is what you'll pass in whenever you trigger this specific import.

### `XLSX_Field_Mapping__mdt` — the column-to-field wiring

Child records under a config, one per column you care about. Each one says "this Excel column header goes to this Salesforce field" — or, for totals, "aggregate this column with this function." A config with no mapping records isn't useful; the mappings are what actually tell the engine what to do with each column.

> **Mental model:** Config = *the recipe's method* (sync or async, what to do on error, which classes run it). Field Mappings = *the recipe's ingredient list* (which columns matter, and where they go). You always need one Config and at least one Field Mapping to do anything.

---

## Sync, Async & Auto

Salesforce puts a ceiling on how much work can happen in a single instant transaction (roughly 6 MB of memory, 10 seconds of CPU). A 500-row file is nothing; a 50,000-row file can bump into that ceiling. `Execution_Mode__c` decides which lane a given import runs in.

| Mode | What happens | Use it when… |
|---|---|---|
| `Sync` | Runs immediately, in the same transaction that called it. The user sees the result right away (or the Flow's Fault Path fires right away). | Files are small and the user is waiting on screen for the outcome. |
| `Async` | Always queued as a background job (a Queueable), which gets a bigger memory ceiling (~12 MB) and its own 60-second CPU budget. | Files are reliably large, or you never want file processing to block the user's screen. |
| `Auto` *(recommended default)* | The engine peeks at the *uncompressed* size of the sheet inside the file — before fully extracting it — and compares that to `Async_Threshold_Bytes__c` (default ~500 KB). Under the threshold, it runs Sync; over it, Async. | You don't know in advance how big files will be, which is most real-world cases. |

Why "uncompressed size" and not just the file's upload size? Excel files compress extremely well — a repetitive 50,000-row spreadsheet can zip down to a file that *looks* tiny but would still blow up memory once opened. Auto mode looks at the size it will actually become in memory, not the size on disk, so the routing decision is honest.

> **Tip:** If you're not sure which mode to pick, pick `Auto`. It removes the guesswork and self-adjusts as your files grow over time.

---

## Hidden rows, totals rows & dates

Real-world spreadsheets aren't clean data tables — people hide rows, Excel Tables auto-add a totals row at the bottom, and dates are stored as numbers internally. The engine handles all three without any extra configuration on your part beyond two switches.

### Hidden rows

If someone hid a row in Excel (right-click → Hide Row) before uploading, `Hidden_Row_Handling__c` decides whether that row reaches your data:

- `Include` *(default)* — hidden rows are processed like any other row.
- `Exclude` — hidden rows are skipped entirely, as if they weren't there.

### Totals rows

If your source data is formatted as a real Excel Table with a Totals Row turned on, `Totals_Row_Handling__c` decides whether that summary row gets treated as a data row:

- `Include` *(default)* — the totals row is processed like a normal row (usually not what you want — it would try to create a record out of a "Total: 4,500" line).
- `Exclude` — the totals row is detected and skipped automatically.

> **One table per sheet:** Totals-row detection is scoped to one Excel Table per sheet — the common case. If a sheet has more than one Table object, the engine won't try to disambiguate which totals row belongs to which.

### Dates

Excel stores dates as plain numbers (day 1 = January 1, 1900) rather than text. When the built-in record-creation handler maps a column onto a Date or Datetime field and the cell's raw value is numeric, it automatically converts that serial number into a real Salesforce date — including correctly reproducing Excel's infamous fake "February 29, 1900" bug, so your dates land exactly where Excel itself would show them. You don't configure anything for this; it just works whenever the target field's type is a date.

---

## Tables that don't start at the top of the sheet

Real exports often have a title line, a generated-on date, or a blank spacer row sitting above the actual table — the header row isn't always the sheet's literal row 1. `Header_Row_Number__c` on the config tells the engine which row to treat as headers.

- Leave it **blank** (the default) and the header row is assumed to be row 1, same as always.
- Set it to the literal Excel row number — the same number shown in Excel's own row gutter on the left — that actually holds your column headers. For a file with a title on row 1, a blank row 2, and headers on row 3, set `Header_Row_Number__c` to `3`.

Everything above the header row is simply ignored — it's never mistaken for data, because the engine hasn't learned which column goes to which field yet when those rows arrive, so nothing about them gets processed.

This only affects the *row* the table starts on. A table that starts at a column other than A (e.g. your data begins at column C, with columns A and B empty) already works with no configuration at all — column matching is done by the header **text**, not by position.

> **Tip:** Hiding the rows above the header in Excel and setting `Hidden_Row_Handling__c = Exclude` does *not* substitute for setting `Header_Row_Number__c` — hiding a row never renumbers the rows below it. If your headers are on row 3, `Header_Row_Number__c` needs to say `3`, whether or not rows 1-2 are hidden.

---

## Quick start: your first import

Let's build the simplest possible scenario end to end: uploading a list of Leads (First Name, Last Name, Company) and creating Lead records immediately.

### Step 1 — Create the Config record

In Setup, go to Custom Metadata Types → XLSX Reader Config → Manage Records → New. Fill in:

| Field | Value |
|---|---|
| Label / Developer Name | `Lead_Sync_Upload` |
| Execution Mode | `Sync` |
| Row Handler Class | `SObjectCreatorRowHandler` |
| Result Handler Class | `DatabaseInsertResultHandler` |
| Error Handling Behavior | `Throw Exception` |

### Step 2 — Add the column mappings

Still in Setup, open the new record and add three child `XLSX Field Mapping` records:

| Excel Column Header | Target SObject | Target Field |
|---|---|---|
| First Name | Lead | FirstName |
| Last Name | Lead | LastName |
| Company Name | Lead | Company |

The header text must match your Excel file's actual header row exactly (case-sensitive). *Company Name* in the sheet needs *Company Name* here, not *Company*.

### Step 3 — Trigger it

From a Screen Flow: add a File Upload component, then an Action calling **Process XLSX File**, passing the uploaded file's Content Document Id and `Lead_Sync_Upload` as the Configuration Developer Name. Connect a Fault Path so a bad file shows a friendly error instead of an ugly stack trace.

That's the whole thing — no Apex was written. The full step-by-step for Flow wiring is in [Running it from Flow](#running-it-from-flow), and five more scenarios (background processing, custom orchestration, aggregation, and an offset table) are in [Worked examples](#six-worked-examples).

---

## Reference: XLSX_Reader_Config__mdt fields

Every setting on the parent config record, explained.

| Field | Type | What it controls |
|---|---|---|
| `Execution_Mode__c` | Picklist | `Sync` / `Async` / `Auto` — see [Sync, Async & Auto](#sync-async--auto). Defaults to Sync. |
| `Async_Threshold_Bytes__c` | Number | Only matters in Auto mode. Uncompressed sheet size above this many bytes routes to Async. Defaults to **500,000** (~500 KB). |
| `Max_Row_Threshold__c` | Number | Hard ceiling on rows in one file. The parser counts every physical row — including hidden and totals rows, before any exclusion — and stops immediately once this is exceeded, rather than finishing the whole parse first. Defaults to **10,000**. |
| `Row_Handler_Class__c` | Text | Apex class name that turns parsed rows into an in-memory result. Built-ins: `SObjectCreatorRowHandler`, `AggregateRowHandler`. Can be a custom class. |
| `Result_Handler_Class__c` | Text | Apex class name that saves that result. Built-ins: `DatabaseInsertResultHandler`, `FieldWriteBackResultHandler`. Configured completely independently of the row handler — see the note below. |
| `Error_Handling_Behavior__c` | Picklist | `Log Error` (default) writes to the error log and moves on quietly. `Throw Exception` re-raises the error — use this when a human is waiting on screen and should see a Fault Path. `Fail Silently` swallows the error entirely with no log record. |
| `Empty_Result_Behaviour__c` | Picklist | Only read by aggregation configs, when the file had zero data rows. Blank = sensible per-function default (SUM/COUNT → 0, MIN/MAX/AVERAGE → null). Override with `Zero`, `Null`, or `Skip` (don't write anything at all). |
| `Hidden_Row_Handling__c` | Picklist | `Include` (default) / `Exclude`. See [Hidden rows](#hidden-rows-totals-rows--dates). |
| `Totals_Row_Handling__c` | Picklist | `Include` (default) / `Exclude`. See [Totals rows](#hidden-rows-totals-rows--dates). |
| `Header_Row_Number__c` | Number | The literal Excel row number that holds the column headers. Blank defaults to `1`. See [Tables that don't start at the top of the sheet](#tables-that-dont-start-at-the-top-of-the-sheet). |

> **Row handler ≠ result handler.** These are two separate roles, set independently, even if you point both fields at the *same* class name. The engine creates two separate instances — one to build the result, one to save it. If you write a custom class that implements both jobs, data must travel from one to the other through `getResult()` → `handleResult(parsedResult)`, never through shared instance variables, because they genuinely are two different objects in memory.

---

## Reference: XLSX_Field_Mapping__mdt fields

Each mapping record does one of two completely different jobs, decided by whether `Aggregate_Function__c` is set.

| Field | Type | What it controls |
|---|---|---|
| `Config__c` | Metadata Relationship | Which parent `XLSX_Reader_Config__mdt` record this mapping belongs to. |
| `Excel_Column_Header__c` | Text | The exact header text as it appears on the configured header row of the spreadsheet (row 1 by default — see `Header_Row_Number__c`). |
| `Target_SObject__c` | Text | Record-creation mode: the object this column's value should be written onto (e.g. `Lead`). Required by the field definition even for aggregation mappings, where it's ignored — put anything. |
| `Target_Field__c` | Text | Record-creation mode: the API name of the field on `Target_SObject__c`. Aggregation mode: the API name of the field on the *related record* (the record whose Id you passed in) that the total gets written onto. |
| `Aggregate_Function__c` | Picklist | Leave blank for a normal "map this column to a field" row. Set to `SUM` / `COUNT` / `MIN` / `MAX` / `AVERAGE` to turn this row into an aggregation spec instead — see below. |

### Two very different row shapes

It's easy to mix these up, so here's both side by side using the same fields:

| Purpose | Excel Column Header | Target SObject | Target Field | Aggregate Function |
|---|---|---|---|---|
| Record creation (one row per field you want populated) | Company Name | Lead | Company | *blank* |
| Aggregation (exactly one row for the whole config) | Amount | *ignored* | Total_Expenses__c | SUM |

A record-creation config typically has several mapping rows — one per column you want to capture. An aggregation config has exactly **one** mapping row, because a single row fully describes the whole job: which column to add up, and which field to write the answer into.

---

## Built-in row handlers

### `SObjectCreatorRowHandler`

Reads the configured header row (row 1 by default, or whatever `Header_Row_Number__c` says — see [Tables that don't start at the top of the sheet](#tables-that-dont-start-at-the-top-of-the-sheet)) and matches each header against your `Excel_Column_Header__c` mappings, then builds one new SObject per data row below it. A few things it does automatically:

- Converts numeric cells into Date/Datetime automatically when the target field is a date type (see [Dates](#hidden-rows-totals-rows--dates)).
- Converts numeric cells into the right Apex number type automatically when the target field is a Number, Currency, Percent, or whole-number (Integer) field — see [How decimals and rounding work](#how-decimals-and-rounding-work).
- If converting one particular cell fails (e.g. text in a number column), that single field's failure is recorded as a warning rather than silently dropped or blowing up the whole row.

### `AggregateRowHandler`

Reads the one aggregation mapping for the config, pulls the named column out of every data row below the configured header row, and applies the chosen function: `SUM`, `COUNT`, `MIN`, `MAX`, or `AVERAGE`. Respects `Empty_Result_Behaviour__c` when the file has no data rows to aggregate.

> **Neither built-in fits?** If your data needs relational logic (creating an Account *and* a Contact *and* an Opportunity from one row) or a calculation the five aggregate functions can't express (a weighted average, a multi-column formula), that's when you write a small custom class — see [Custom handlers](#custom-handlers-for-developers).

---

## Built-in result handlers

### `DatabaseInsertResultHandler`

Takes the list of new records built by the row handler and inserts them, 200 at a time (Salesforce's DML chunk size), respecting the running user's own object and field permissions. If some records in a chunk fail while others succeed, the successful ones stay inserted — the handler then throws a summary listing what failed, so nothing fails silently and nothing gets needlessly rolled back.

### `FieldWriteBackResultHandler`

Pairs with `AggregateRowHandler`. Takes the single aggregated number and writes it onto the field named in the mapping's `Target_Field__c`, on whichever record Id you passed as the **Related Record Id** when you triggered the import. If the target field is a whole-number (Integer) field, it automatically truncates the decimal result down to a whole number rather than throwing a type error — see below for exactly what "truncates" means.

---

## How decimals and rounding work

**Record creation.** A Number, Currency, or Percent column in Excel maps cleanly onto the matching Salesforce field type, decimals included — `1234.56` in Excel becomes `1234.56` on the record. If the target field is a whole-number (Integer) field and the Excel value has a decimal part, the decimal part is dropped: `12.7` becomes `12`, not `13` and not an error. This is a straight truncation (rounds toward zero), not "round to nearest."

**Aggregation.** SUM, MIN, and MAX add up your numbers exactly as entered — no floating-point drift, so `10.55 + 25.99` is exactly `36.54`, never something like `36.53999999999999`. AVERAGE can produce a *lot* of decimal places when the numbers don't divide evenly (an average of three unevenly-sized values might carry 20+ decimal digits) — that's expected, not a malfunction. As with record creation, writing that result onto a whole-number (Integer) target field truncates it: an average of `36.54` written to an Integer field becomes `36`.

> **Note:** A Currency/Number/Percent field's configured "decimal places" is a *display* setting in Salesforce, not a storage limit — the platform doesn't round a value down to fewer decimals just because you write more than the field is set to show. If an aggregation produces a long decimal and you want it visibly rounded, either build that rounding into a custom result handler (see [Custom handlers](#custom-handlers-for-developers)) or adjust how the field is displayed in Salesforce.

---

## Where errors go

`XLSX_Error_Log__c` is the audit trail for anything that goes wrong (when `Error_Handling_Behavior__c` is `Log Error`, which is the default). Records are visible to everyone but editable only by admins, by design — it's meant to be a trustworthy history, not a working list people casually clean up.

| Field | Purpose |
|---|---|
| `Error_Message__c` | What went wrong, in the exception's own words. |
| `Stack_Trace__c` | The full Apex stack trace, for a developer to diagnose. |
| `Related_Record_Id__c` | The **Related Record Id** you passed in when triggering the import — a Case, Campaign, Lead, whatever it was. |
| `Related_Record_Link__c` | A clickable link built from the Id above, since it's stored as plain text (it can point at any object) and can't be a real Lookup field. |
| `File_Name__c` | The name of the file that failed, where available. |

Error logs are always written even if the uploading user doesn't personally have create access on this object — that's deliberate, so a permissions gap never causes a failure to vanish without a trace.

---

## Six worked examples

Each of these is a complete, realistic scenario — the config, the mappings, and how it gets triggered.

### Example 1 — Simple sync upload from a Screen Flow

*Scenario: a user uploads a small file of 500 Leads through a Screen Flow and wants to see the result on the very next screen — including a friendly error screen if something's wrong with the file.*

- **Config:** `Execution_Mode__c` = Sync · `Row_Handler_Class__c` = SObjectCreatorRowHandler · `Result_Handler_Class__c` = DatabaseInsertResultHandler · `Error_Handling_Behavior__c` = Throw Exception
- **Mappings:** one row per Lead field you want populated (First Name → FirstName, Last Name → LastName, Company Name → Company)
- **Trigger:** Screen Flow → File Upload component → Action ("Process XLSX File") → Fault Path to an error screen

### Example 2 — Massive file, automatic background processing

*Scenario: users occasionally attach a 50,000-row, 4 MB Account file to a Campaign. It's too big to process while someone waits, and errors shouldn't interrupt anyone — they should just get logged.*

- **Config:** `Execution_Mode__c` = Auto · `Async_Threshold_Bytes__c` = 500000 · `Row_Handler_Class__c` = SObjectCreatorRowHandler · `Result_Handler_Class__c` = DatabaseInsertResultHandler · `Error_Handling_Behavior__c` = Log Error
- **Mappings:** Account Name → Name, Industry Type → Industry
- **Trigger:** a Record-Triggered Flow on ContentDocumentLink (fires when a file is attached to a Campaign) → Action, passing the Campaign's Id as **Related Record Id** so any error log links straight back to that Campaign

### Example 3 — Complex multi-object orchestration (custom Apex)

*Scenario: an "Orders" spreadsheet mixes Customer, Product, and Pricing columns in one row. One row needs to become an Account, a Contact, an Opportunity, and Opportunity Line Items, all cross-referenced — well beyond what plain record-creation mapping can express.*

A developer writes one class implementing both interfaces:

```apex
public class ComplexOrderHandler implements IXLSXRowHandler, IXLSXResultHandler {
    // IXLSXRowHandler: accumulate rows into wrapper objects during processRow()
    // IXLSXResultHandler: on handleResult(), do the real Account/Contact/
    // Opportunity/Line-Item DML with proper cross-referencing
}
```

- **Config:** `Row_Handler_Class__c` = ComplexOrderHandler · `Result_Handler_Class__c` = ComplexOrderHandler *(same class name — instantiated twice, independently)*
- **Trigger, direct from Apex:**

```apex
XLSXProcessorService.ProcessingRequest req = new XLSXProcessorService.ProcessingRequest();
req.contentDocumentId = '069xxxxxxxxxxxx';
req.configDeveloperName = 'Complex_Orders';
req.relatedRecordId = '001xxxxxxxxxxxx';

XLSXProcessorService.processFiles(new List<XLSXProcessorService.ProcessingRequest>{req});
```

### Example 4 — Aggregate a column onto a parent record (no code)

*Scenario: users upload an "Expenses" spreadsheet against a parent record (a Case, Campaign, or custom object) and the business only cares about the total — not individual line-item records.*

- **Config:** `Row_Handler_Class__c` = AggregateRowHandler · `Result_Handler_Class__c` = FieldWriteBackResultHandler · `Error_Handling_Behavior__c` = Throw Exception
- **Mapping (exactly one row):** Excel Column Header = Amount · Aggregate Function = SUM · Target Field = Total_Expenses__c
- **Trigger, direct from Apex:**

```apex
XLSXProcessorService.ProcessingRequest req = new XLSXProcessorService.ProcessingRequest();
req.contentDocumentId = contentDocId;
req.configDeveloperName = 'Expense_Aggregator';
req.relatedRecordId = expenseReportId; // the record Total_Expenses__c lives on

XLSXProcessorService.processFiles(new List<XLSXProcessorService.ProcessingRequest>{req});
```

### Example 5 — Custom calculation beyond SUM/COUNT/MIN/MAX/AVERAGE

*Scenario: the built-in five functions only ever read one column. A weighted average — reading a value column and a weight column together — needs a small custom class instead.*

```apex
public class WeightedAverageHandler implements IXLSXRowHandler, IXLSXResultHandler {
    // processRow(): read column B (value) and column C (weight),
    // accumulate weightedSum and totalWeight
    // getResult(): return weightedSum / totalWeight
    // handleResult(): update the parent record's Weighted_Average_Amount__c field
}
```

- **Config:** `Row_Handler_Class__c` = WeightedAverageHandler · `Result_Handler_Class__c` = WeightedAverageHandler
- Triggered the same way as Example 4 — `relatedRecordId` is handed to the custom class's `initialize()` directly, no side-channel needed.

### Example 6 — A table that doesn't start at the top of the sheet

*Scenario: Finance's export has a title on row 1 ("Q3 Expense Report — Generated 2026-01-01"), a blank row 2, and the real header row — Item, Amount, Date — starting on row 3. This layers onto any of the examples above; nothing about the field mappings changes.*

- **Config:** on your existing config record (record-creation or aggregation, doesn't matter which), set `Header_Row_Number__c` = `3`. Leave everything else as it already was.
- **Mappings:** unchanged — matched by header text, not position.
- **Trigger:** unchanged — Flow or Apex, exactly as in whichever example you're layering this onto.

---

## Running it from Flow

The action to look for is **Process XLSX File** (backed by `XLSXReaderInvocable`). It takes three inputs:

| Input | Required | What to pass |
|---|---|---|
| Content Document Id | Yes | The uploaded file's Id — typically the output of a File Upload screen component. |
| Configuration Developer Name | Yes | The `DeveloperName` of the `XLSX_Reader_Config__mdt` record to use, as plain text. |
| Related Record Id | No | Two jobs at once: it's what error logs link back to, *and* — for aggregation configs — it's the actual record `FieldWriteBackResultHandler` writes the total onto. Leave it blank for a plain record-creation import with no parent context. |

1. Build a Screen Flow (or Record-Triggered Flow) and add a File Upload component, capturing its `ContentDocumentId` output.
2. Add an Action element → search for **Process XLSX File**.
3. Wire up the three inputs above.
4. If `Error_Handling_Behavior__c` on the config is `Throw Exception`, connect a Fault Path from this Action to a screen that explains the failure in plain language.

---

## Running it from Apex

The direct entry point is `XLSXProcessorService.processFiles(List<ProcessingRequest>)` — the same method Flow calls under the hood, so behavior is identical either way.

```apex
XLSXProcessorService.ProcessingRequest req = new XLSXProcessorService.ProcessingRequest();
req.contentDocumentId = uploadedFile.ContentDocumentId;
req.configDeveloperName = 'Lead_Sync_Upload';
req.relatedRecordId = null; // optional

XLSXProcessorService.processFiles(
    new List<XLSXProcessorService.ProcessingRequest>{ req }
);
```

You can pass several requests in one list — each one is processed independently, wrapped in its own try/catch, so one bad file in a batch of ten can't take the other nine down with it.

---

## Custom handlers, for developers

When the two built-in pairs don't fit, write a class implementing one or both interfaces:

| Interface | Your job |
|---|---|
| `IXLSXRowHandler` | `initialize(config)`, then `processRow(rowNumber, rowData)` per row (remember: `rowData` is keyed by column letter, and `rowNumber` is the row's literal Excel row number, not "whichever row arrives first" — check it against `config.Header_Row_Number__c`, defaulting to `1` if blank, the same way the built-in handlers do, since a title banner above the real headers is common), then `finishProcessing()`, then return your built result from `getResult()`. |
| `IXLSXResultHandler` | `initialize(config, relatedRecordId)`, then `handleResult(parsedResult)` — this is the only place that should perform DML. |

A class is free to implement both interfaces and be named in both config fields — but the engine still instantiates it twice, independently. Design your class so all the state it needs travels through `getResult()` → `handleResult()`, not through instance variables you'd expect to survive between the two roles (they won't — see Examples 3 and 5 above for the pattern).

---

## Troubleshooting & FAQ

**My config or class name is misspelled — what happens?**
The engine throws immediately, with a clear message, rather than silently doing nothing. Blank, unresolvable, or wrong-interface class names in `Row_Handler_Class__c` / `Result_Handler_Class__c` are never treated as "skip this step" — there's no silent no-op fallback anywhere in this engine, by design.

**SOQL or Apex says "No such column" on an XLSX_Error_Log__c field, even though the field clearly exists**
This is almost always Field-Level Security, not a real schema problem. Custom fields created through a metadata deploy (as opposed to the Setup UI) get **zero** FLS granted to any profile by default — invisible to everyone, including System Administrator — until it's explicitly granted. Salesforce reports this identically to "the field doesn't exist" rather than a permission error, specifically so it doesn't leak schema information to users who shouldn't see it. Fix: grant Field-Level Security on the affected fields in Setup.

**I got an error about "exceeds the safe heap budget"**
Before decompressing any part of the file, the engine checks whether that part would use more than 40% of the available memory for the current execution context (sync or async), and refuses upfront rather than risking a hard crash mid-parse. If you see this, the file's sheet is genuinely too large for the mode it's running in — move the config to `Async` or `Auto`, or ask the user to trim the file.

**I got an error mentioning "Max Row Threshold"**
The file has more physical rows than `Max_Row_Threshold__c` allows (default 10,000) — counted before any hidden/totals-row exclusion happens. This is intentional fail-fast behavior: rather than fully parsing an oversized file just to reject it at the very end, the engine stops the moment the threshold is crossed. Raise the threshold on the config if the file size is expected to grow, or ask for a smaller file.

**My totals row (or a hidden row) still showed up as a record**
Check that `Totals_Row_Handling__c` / `Hidden_Row_Handling__c` is actually set to `Exclude` on the config — both default to `Include`. Also confirm your data is a real Excel Table (Insert → Table) with the Totals Row option turned on for totals-row detection to find it; a plain range with a manually typed "Total" line at the bottom won't be recognized. And remember detection only handles one Table per sheet.

**My table doesn't start at the top of the sheet — do I need a custom handler?**
No — set `Header_Row_Number__c` on the config to the literal Excel row number your headers are actually on. See [Tables that don't start at the top of the sheet](#tables-that-dont-start-at-the-top-of-the-sheet). Column offsets (data starting at column C instead of A) already worked with no configuration; this setting is specifically for row offsets — a title banner, a generated-on line, or blank spacer rows above the real header row.

**Does it matter which sheet in the workbook I put my data on?**
Yes — the engine always resolves and reads the **first** sheet in the workbook (in the order Excel itself lists them), regardless of what it's named. If a file has multiple tabs, make sure the data you want is on the first one.

**Can I filter or build a list view on Error_Message__c?**
Not directly in a WHERE clause — it's a Long Text Area field, and Salesforce doesn't allow those in SOQL filters or standard list view filters. You can still report on it, search it, or filter in Apex after querying.

**My Amount/Number field ended up blank even though the Excel column had a value in it**
If you deployed this package before this fix shipped: numeric target fields (Currency, Percent, Number, whole-number Integer fields) used to always fail silently — every value, not just malformed ones — because of a coercion gap between Excel's raw text and Salesforce's numeric types. That's fixed; a valid numeric value now populates the field correctly, including decimals. If a field is still coming back blank, check `getWarnings()` (or the equivalent surfaced warning in your Flow/Apex caller) for the actual reason — it's most likely a genuinely non-numeric cell value now, not the old across-the-board failure.

**Why does my AVERAGE result have 15+ decimal places?**
That's expected — see [How decimals and rounding work](#how-decimals-and-rounding-work). Division that doesn't come out even carries a lot of precision, and Salesforce number fields store more precision than they display. It's not truncated automatically unless the target field is a whole-number (Integer) field.

**Will this ever elevate a user's permissions to do something they normally couldn't?**
Record creation and file reads run under the acting user's own permissions (user mode) — this engine doesn't grant access a user wouldn't otherwise have. The one deliberate exception is writing to the error log itself: that write always succeeds even if the uploading user lacks create access on `XLSX_Error_Log__c`, so a permissions gap can never cause a failure to go unrecorded.

---

## Cheat sheet

### Built-in classes

| Class | Role | Pairs with |
|---|---|---|
| `SObjectCreatorRowHandler` | Row Handler | `DatabaseInsertResultHandler` |
| `AggregateRowHandler` | Row Handler | `FieldWriteBackResultHandler` |
| `DatabaseInsertResultHandler` | Result Handler | `SObjectCreatorRowHandler` |
| `FieldWriteBackResultHandler` | Result Handler | `AggregateRowHandler` |

### All picklist values

| Field | Values |
|---|---|
| `Execution_Mode__c` | Sync *(default)* · Async · Auto |
| `Error_Handling_Behavior__c` | Log Error *(default)* · Throw Exception · Fail Silently |
| `Empty_Result_Behaviour__c` | *blank (function default)* · Zero · Null · Skip |
| `Hidden_Row_Handling__c` | Include *(default)* · Exclude |
| `Totals_Row_Handling__c` | Include *(default)* · Exclude |
| `Aggregate_Function__c` | *blank (record-creation mapping)* · SUM · COUNT · MIN · MAX · AVERAGE |

### Defaults worth remembering

| Setting | Default |
|---|---|
| Max Row Threshold | 10,000 rows |
| Async Threshold Bytes | 500,000 bytes (~500 KB uncompressed) |
| Heap safety ceiling before extraction | 40% of the execution context's memory limit |
| Header Row Number | 1 (the sheet's literal first row) |

---

*Covers the shipped Apex engine, its two Custom Metadata Types, and the built-in handler pairs. For interface-level detail when building a custom handler, read the Apex class comments on `IXLSXRowHandler` and `IXLSXResultHandler` directly.*
