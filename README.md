# Native Salesforce PDF Generation

100% native Salesforce document generation (Conga-style) with no external APIs. Apex owns metadata, data queries, and queue orchestration. A headless Lightning Web Component in the utility bar uses `pdf-lib` in the browser to fill AcroForm PDFs and write `ContentVersion` files back to Salesforce.

## Architecture

1. Admin uploads a fillable AcroForm PDF in `pdfTemplateManager` and maps PDF field IDs to Salesforce field paths.
2. Apex stores the template file (`ContentVersion` / `ContentDocument`) plus `PDF_Template__c` and `PDF_Field_Mapping__c` rows.
3. Callers insert `Pending_PDF_Generation__c` rows (or use `PdfGenerationEnqueueService.enqueueGeneration`).
4. `automatedPdfEngine` polls every 15 seconds, claims Pending jobs, fills/flattens the PDF with `window.PDFLib`, and finalizes via Apex.

## Project layout

```
force-app/main/default/
  objects/           PDF_Template__c, PDF_Field_Mapping__c, Pending_PDF_Generation__c
  classes/           Controllers, enqueue service, tests
  lwc/               pdfTemplateManager, automatedPdfEngine
  staticresources/   pdfLib (pdf-lib UMD)
  permissionsets/    Native_PDF_Generation_User
  applications/      Native_PDF_Generation (includes utility bar worker)
  flexipages/        Native_PDF_Generation_UtilityBar
  tabs/              Admin + object tabs
```

## Deploy

```bash
sf org create scratch -f config/project-scratch-def.json -a pdf-gen -d
sf project deploy start -d force-app
sf org assign permset --name Native_PDF_Generation_User
sf org open
```

## Admin setup

1. Open the **Native PDF Generation** app.
2. Open **PDF Template Manager**.
3. Enter a template name, choose Account or Contact, upload a fillable AcroForm PDF.
4. Map each discovered PDF text field to a Salesforce field path (`Name`, `BillingCity`, `Account.Name`, etc.).
5. Save.

`automatedPdfEngine` is hosted in the app utility bar and is also embedded on the PDF Template Manager page so polling starts while admins work there. Keep a browser session on the Native PDF Generation app (or open the PDF Engine utility item) for background processing.

## Enqueue a job

Anonymous Apex:

```apex
Id accountId = '001XXXXXXXXXXXX'; // donor Account Id
Id templateId = 'a0XXXXXXXXXXXXX'; // PDF_Template__c Id
Id jobId = PdfGenerationEnqueueService.enqueueGeneration(accountId, templateId);
System.debug(jobId);
```

Or insert `Pending_PDF_Generation__c` with `Status__c = Pending`, `Record_Id__c`, and `Template_Id__c`.

## Notes

- Supported objects are intentionally limited to Account and Contact.
- Template `File_Id__c` stores the `ContentDocumentId`.
- Generated PDFs are published with `FirstPublishLocationId` set to the donor record.
- Queue failures are written to `Error_Message__c` with status `Failed`.
