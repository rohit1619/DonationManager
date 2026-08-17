Account acc = [
    SELECT Id
    FROM Account
    ORDER BY CreatedDate DESC
    LIMIT 1
];
PDF_Template__c template = [
    SELECT Id
    FROM PDF_Template__c
    WHERE Object_API_Name__c = 'Account'
    ORDER BY CreatedDate DESC
    LIMIT 1
];
Id jobId = PdfGenerationEnqueueService.enqueueGeneration(acc.Id, template.Id);
System.debug('Enqueued PDF job: ' + jobId);
