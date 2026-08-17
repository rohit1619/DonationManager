/**
 * Helper service for enqueueing native PDF generation jobs against Account/Contact records.
 */
public with sharing class PdfGenerationEnqueueService {
    public class EnqueueRequest {
        @AuraEnabled public Id recordId { get; set; }
        @AuraEnabled public Id templateId { get; set; }
    }

    /**
     * Inserts a Pending_PDF_Generation__c queue row for background browser processing.
     */
    @AuraEnabled
    public static Id enqueueGeneration(Id recordId, Id templateId) {
        try {
            if (recordId == null) {
                throw new AuraHandledException('recordId is required.');
            }
            if (templateId == null) {
                throw new AuraHandledException('templateId is required.');
            }
            if (!Schema.sObjectType.Pending_PDF_Generation__c.isCreateable()) {
                throw new AuraHandledException(
                    'Insufficient permission to create Pending PDF Generation records.'
                );
            }

            PDF_Template__c template = [
                SELECT Id, Object_API_Name__c
                FROM PDF_Template__c
                WHERE Id = :templateId
                WITH SECURITY_ENFORCED
                LIMIT 1
            ];

            String recordTypeName = recordId.getSObjectType().getDescribe().getName();
            if (recordTypeName != template.Object_API_Name__c) {
                throw new AuraHandledException(
                    'Record type ' + recordTypeName +
                    ' does not match template object ' + template.Object_API_Name__c + '.'
                );
            }

            Pending_PDF_Generation__c job = new Pending_PDF_Generation__c(
                Record_Id__c = String.valueOf(recordId),
                Template_Id__c = templateId,
                Status__c = 'Pending'
            );
            insert job;
            return job.Id;
        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception ex) {
            throw new AuraHandledException(
                'Unable to enqueue PDF generation: ' + ex.getMessage()
            );
        }
    }
}
