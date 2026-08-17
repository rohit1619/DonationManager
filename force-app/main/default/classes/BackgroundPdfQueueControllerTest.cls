/**
 * Test coverage for BackgroundPdfQueueController.
 */
@IsTest
private class BackgroundPdfQueueControllerTest {
    @TestSetup
    static void setupData() {
        Account accountRecord = new Account(Name = 'PDF Test Account', BillingCity = 'San Francisco');
        insert accountRecord;

        ContentVersion cv = new ContentVersion();
        cv.Title = 'Template';
        cv.PathOnClient = 'template.pdf';
        cv.VersionData = Blob.valueOf('%PDF-1.4 template');
        cv.IsMajorVersion = true;
        insert cv;

        cv = [
            SELECT Id, ContentDocumentId
            FROM ContentVersion
            WHERE Id = :cv.Id
        ];

        PDF_Template__c template = new PDF_Template__c(
            Name = 'Account Template',
            Object_API_Name__c = 'Account',
            File_Id__c = String.valueOf(cv.ContentDocumentId)
        );
        insert template;

        insert new PDF_Field_Mapping__c(
            PDF_Template__c = template.Id,
            PDF_Field_Name__c = 'AccountName',
            Salesforce_Field_Path__c = 'Name'
        );
        insert new PDF_Field_Mapping__c(
            PDF_Template__c = template.Id,
            PDF_Field_Name__c = 'BillingCity',
            Salesforce_Field_Path__c = 'BillingCity'
        );

        insert new Pending_PDF_Generation__c(
            Record_Id__c = String.valueOf(accountRecord.Id),
            Template_Id__c = template.Id,
            Status__c = 'Pending'
        );
    }

    @IsTest
    static void getPendingJobs_claimsJobAndReturnsFieldPacket() {
        Test.startTest();
        List<BackgroundPdfQueueController.PdfJobPacket> packets =
            BackgroundPdfQueueController.getPendingJobs(5);
        Test.stopTest();

        System.assertEquals(1, packets.size(), 'One pending job should be returned');
        BackgroundPdfQueueController.PdfJobPacket packet = packets[0];
        System.assertEquals('Account', packet.objectApiName);
        System.assertNotEquals(null, packet.templateBase64);
        System.assertEquals(2, packet.fieldValues.size());

        Map<String, String> valuesByPdfField = new Map<String, String>();
        for (BackgroundPdfQueueController.FieldValuePacket fieldValue : packet.fieldValues) {
            valuesByPdfField.put(fieldValue.pdfFieldName, fieldValue.fieldValue);
        }
        System.assertEquals('PDF Test Account', valuesByPdfField.get('AccountName'));
        System.assertEquals('San Francisco', valuesByPdfField.get('BillingCity'));

        Pending_PDF_Generation__c job = [
            SELECT Status__c
            FROM Pending_PDF_Generation__c
            WHERE Id = :packet.jobId
        ];
        System.assertEquals('Processing', job.Status__c);
    }

    @IsTest
    static void finalizeJob_createsContentVersionAndCompletes() {
        Pending_PDF_Generation__c job = [
            SELECT Id, Record_Id__c
            FROM Pending_PDF_Generation__c
            LIMIT 1
        ];
        job.Status__c = 'Processing';
        update job;

        String filledPdf = EncodingUtil.base64Encode(Blob.valueOf('%PDF-1.4 filled'));

        Test.startTest();
        BackgroundPdfQueueController.FinalizeResult result =
            BackgroundPdfQueueController.finalizeJob(job.Id, filledPdf, 'Filled Account.pdf');
        Test.stopTest();

        System.assertEquals('Completed', result.status);
        System.assertNotEquals(null, result.contentVersionId);

        Pending_PDF_Generation__c refreshed = [
            SELECT Status__c, Output_Content_Version_Id__c
            FROM Pending_PDF_Generation__c
            WHERE Id = :job.Id
        ];
        System.assertEquals('Completed', refreshed.Status__c);
        System.assertEquals(String.valueOf(result.contentVersionId), refreshed.Output_Content_Version_Id__c);

        Integer links = [
            SELECT COUNT()
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :job.Record_Id__c
        ];
        System.assert(links >= 1, 'Generated file should be linked to the donor record');
    }

    @IsTest
    static void failJob_marksQueueItemFailed() {
        Pending_PDF_Generation__c job = [
            SELECT Id
            FROM Pending_PDF_Generation__c
            LIMIT 1
        ];

        Test.startTest();
        BackgroundPdfQueueController.failJob(job.Id, 'Browser worker exploded');
        Test.stopTest();

        Pending_PDF_Generation__c refreshed = [
            SELECT Status__c, Error_Message__c
            FROM Pending_PDF_Generation__c
            WHERE Id = :job.Id
        ];
        System.assertEquals('Failed', refreshed.Status__c);
        System.assertEquals('Browser worker exploded', refreshed.Error_Message__c);
    }
}
