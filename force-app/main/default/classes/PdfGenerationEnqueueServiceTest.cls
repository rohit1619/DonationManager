/**
 * Test coverage for PdfGenerationEnqueueService.
 */
@IsTest
private class PdfGenerationEnqueueServiceTest {
    @IsTest
    static void enqueueGeneration_createsPendingJob() {
        Account accountRecord = new Account(Name = 'Enqueue Account');
        insert accountRecord;

        PDF_Template__c template = new PDF_Template__c(
            Name = 'Enqueue Template',
            Object_API_Name__c = 'Account',
            File_Id__c = '069000000000000AAA'
        );
        insert template;

        Test.startTest();
        Id jobId = PdfGenerationEnqueueService.enqueueGeneration(accountRecord.Id, template.Id);
        Test.stopTest();

        Pending_PDF_Generation__c job = [
            SELECT Record_Id__c, Template_Id__c, Status__c
            FROM Pending_PDF_Generation__c
            WHERE Id = :jobId
        ];
        System.assertEquals(String.valueOf(accountRecord.Id), job.Record_Id__c);
        System.assertEquals(template.Id, job.Template_Id__c);
        System.assertEquals('Pending', job.Status__c);
    }

    @IsTest
    static void enqueueGeneration_rejectsObjectMismatch() {
        Contact contactRecord = new Contact(LastName = 'Mismatch');
        insert contactRecord;

        PDF_Template__c template = new PDF_Template__c(
            Name = 'Account Only Template',
            Object_API_Name__c = 'Account',
            File_Id__c = '069000000000000AAA'
        );
        insert template;

        Boolean didThrow = false;
        try {
            PdfGenerationEnqueueService.enqueueGeneration(contactRecord.Id, template.Id);
        } catch (AuraHandledException ex) {
            didThrow = true;
        }
        System.assertEquals(true, didThrow, 'Object mismatch should raise AuraHandledException');
    }
}
