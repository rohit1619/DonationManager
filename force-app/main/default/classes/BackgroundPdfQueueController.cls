/**
 * Background queue controller consumed by the headless automatedPdfEngine LWC.
 * Claims pending jobs, dynamically queries mapped Salesforce data, and finalizes
 * generated PDFs into ContentVersion linked to the donor record.
 */
public with sharing class BackgroundPdfQueueController {
    private static final Integer DEFAULT_BATCH_SIZE = 3;
    private static final Set<String> ALLOWED_OBJECTS = new Set<String>{
        'Account',
        'Contact'
    };

    public class FieldValuePacket {
        @AuraEnabled public String pdfFieldName { get; set; }
        @AuraEnabled public String salesforceFieldPath { get; set; }
        @AuraEnabled public String fieldValue { get; set; }
    }

    public class PdfJobPacket {
        @AuraEnabled public Id jobId { get; set; }
        @AuraEnabled public String jobName { get; set; }
        @AuraEnabled public Id recordId { get; set; }
        @AuraEnabled public Id templateId { get; set; }
        @AuraEnabled public String templateName { get; set; }
        @AuraEnabled public String objectApiName { get; set; }
        @AuraEnabled public String contentDocumentId { get; set; }
        @AuraEnabled public String templateBase64 { get; set; }
        @AuraEnabled public List<FieldValuePacket> fieldValues { get; set; }
    }

    public class FinalizeResult {
        @AuraEnabled public Id jobId { get; set; }
        @AuraEnabled public Id contentVersionId { get; set; }
        @AuraEnabled public Id contentDocumentId { get; set; }
        @AuraEnabled public String status { get; set; }
    }

    /**
     * Pulls Pending queue items, marks them Processing, dynamically queries
     * mapped record fields, and returns fill packets for the browser worker.
     */
    @AuraEnabled
    public static List<PdfJobPacket> getPendingJobs(Integer maxJobs) {
        try {
            Integer batchSize = (maxJobs == null || maxJobs <= 0)
                ? DEFAULT_BATCH_SIZE
                : Math.min(maxJobs, 10);

            if (!Schema.sObjectType.Pending_PDF_Generation__c.isAccessible()) {
                throw new AuraHandledException(
                    'Insufficient permission to read Pending PDF Generation records.'
                );
            }

            List<Pending_PDF_Generation__c> pendingJobs = [
                SELECT
                    Id,
                    Name,
                    Record_Id__c,
                    Status__c,
                    Template_Id__c,
                    Template_Id__r.Name,
                    Template_Id__r.Object_API_Name__c,
                    Template_Id__r.File_Id__c
                FROM Pending_PDF_Generation__c
                WHERE Status__c = 'Pending'
                WITH SECURITY_ENFORCED
                ORDER BY CreatedDate ASC
                LIMIT :batchSize
                FOR UPDATE
            ];

            if (pendingJobs.isEmpty()) {
                return new List<PdfJobPacket>();
            }

            Set<Id> templateIds = new Set<Id>();
            for (Pending_PDF_Generation__c job : pendingJobs) {
                if (job.Template_Id__c != null) {
                    templateIds.add(job.Template_Id__c);
                }
                job.Status__c = 'Processing';
                job.Error_Message__c = null;
            }
            update pendingJobs;

            Map<Id, List<PDF_Field_Mapping__c>> mappingsByTemplate =
                loadMappingsByTemplate(templateIds);

            List<PdfJobPacket> packets = new List<PdfJobPacket>();
            for (Pending_PDF_Generation__c job : pendingJobs) {
                try {
                    packets.add(buildJobPacket(job, mappingsByTemplate.get(job.Template_Id__c)));
                } catch (Exception jobEx) {
                    markJobFailed(job.Id, jobEx.getMessage());
                }
            }
            return packets;
        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception ex) {
            throw new AuraHandledException(
                'Unable to retrieve pending PDF jobs: ' + ex.getMessage()
            );
        }
    }

    /**
     * Inserts the filled PDF as a ContentVersion linked to the donor record
     * and marks the queue item Completed.
     */
    @AuraEnabled
    public static FinalizeResult finalizeJob(
        Id jobId,
        String base64Pdf,
        String outputFileName
    ) {
        try {
            if (jobId == null) {
                throw new AuraHandledException('Job Id is required.');
            }
            if (String.isBlank(base64Pdf)) {
                throw new AuraHandledException('Generated PDF content is required.');
            }
            if (!Schema.sObjectType.Pending_PDF_Generation__c.isUpdateable()) {
                throw new AuraHandledException(
                    'Insufficient permission to update Pending PDF Generation records.'
                );
            }
            if (!Schema.sObjectType.ContentVersion.isCreateable()) {
                throw new AuraHandledException(
                    'Insufficient permission to create ContentVersion.'
                );
            }

            Pending_PDF_Generation__c job = [
                SELECT
                    Id,
                    Name,
                    Record_Id__c,
                    Status__c,
                    Template_Id__c,
                    Template_Id__r.Name
                FROM Pending_PDF_Generation__c
                WHERE Id = :jobId
                WITH SECURITY_ENFORCED
                LIMIT 1
                FOR UPDATE
            ];

            if (job.Status__c != 'Processing' && job.Status__c != 'Pending') {
                throw new AuraHandledException(
                    'Job ' + job.Name + ' cannot be finalized from status ' + job.Status__c + '.'
                );
            }

            Id donorRecordId;
            try {
                donorRecordId = Id.valueOf(job.Record_Id__c);
            } catch (Exception idEx) {
                throw new AuraHandledException(
                    'Queue item has an invalid Record Id: ' + job.Record_Id__c
                );
            }

            String titleBase = String.isNotBlank(outputFileName)
                ? outputFileName.trim().replaceAll('\\.pdf$', '')
                : (job.Template_Id__r != null && String.isNotBlank(job.Template_Id__r.Name)
                    ? job.Template_Id__r.Name + ' - ' + job.Name
                    : 'Generated PDF - ' + job.Name);

            ContentVersion cv = new ContentVersion();
            cv.Title = titleBase;
            cv.PathOnClient = titleBase + '.pdf';
            cv.VersionData = EncodingUtil.base64Decode(base64Pdf);
            cv.FirstPublishLocationId = donorRecordId;
            cv.IsMajorVersion = true;
            insert cv;

            ContentVersion insertedCv = [
                SELECT Id, ContentDocumentId
                FROM ContentVersion
                WHERE Id = :cv.Id
                WITH SECURITY_ENFORCED
                LIMIT 1
            ];

            job.Status__c = 'Completed';
            job.Error_Message__c = null;
            job.Output_Content_Version_Id__c = String.valueOf(insertedCv.Id);
            update job;

            FinalizeResult result = new FinalizeResult();
            result.jobId = job.Id;
            result.contentVersionId = insertedCv.Id;
            result.contentDocumentId = insertedCv.ContentDocumentId;
            result.status = 'Completed';
            return result;
        } catch (AuraHandledException ahe) {
            if (jobId != null) {
                markJobFailed(jobId, ahe.getMessage());
            }
            throw ahe;
        } catch (DmlException dmlEx) {
            String message = 'Unable to finalize PDF job: ' + dmlEx.getDmlMessage(0);
            if (jobId != null) {
                markJobFailed(jobId, message);
            }
            throw new AuraHandledException(message);
        } catch (Exception ex) {
            String message = 'Unexpected error finalizing PDF job: ' + ex.getMessage();
            if (jobId != null) {
                markJobFailed(jobId, message);
            }
            throw new AuraHandledException(message);
        }
    }

    /**
     * Marks a queue item Failed with an error message from the browser worker.
     */
    @AuraEnabled
    public static void failJob(Id jobId, String errorMessage) {
        try {
            if (jobId == null) {
                throw new AuraHandledException('Job Id is required.');
            }
            markJobFailed(
                jobId,
                String.isBlank(errorMessage) ? 'Unknown browser worker failure.' : errorMessage
            );
        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception ex) {
            throw new AuraHandledException(
                'Unable to mark PDF job as failed: ' + ex.getMessage()
            );
        }
    }

    private static Map<Id, List<PDF_Field_Mapping__c>> loadMappingsByTemplate(Set<Id> templateIds) {
        Map<Id, List<PDF_Field_Mapping__c>> result = new Map<Id, List<PDF_Field_Mapping__c>>();
        if (templateIds == null || templateIds.isEmpty()) {
            return result;
        }

        for (PDF_Field_Mapping__c mapping : [
            SELECT Id, PDF_Template__c, PDF_Field_Name__c, Salesforce_Field_Path__c
            FROM PDF_Field_Mapping__c
            WHERE PDF_Template__c IN :templateIds
            WITH SECURITY_ENFORCED
        ]) {
            if (!result.containsKey(mapping.PDF_Template__c)) {
                result.put(mapping.PDF_Template__c, new List<PDF_Field_Mapping__c>());
            }
            result.get(mapping.PDF_Template__c).add(mapping);
        }
        return result;
    }

    private static PdfJobPacket buildJobPacket(
        Pending_PDF_Generation__c job,
        List<PDF_Field_Mapping__c> mappings
    ) {
        if (job.Template_Id__c == null || job.Template_Id__r == null) {
            throw new AuraHandledException('Queue item is missing a valid template reference.');
        }
        if (String.isBlank(job.Record_Id__c)) {
            throw new AuraHandledException('Queue item is missing Record Id.');
        }
        if (mappings == null || mappings.isEmpty()) {
            throw new AuraHandledException(
                'No field mappings configured for template ' + job.Template_Id__r.Name + '.'
            );
        }

        String objectApiName = job.Template_Id__r.Object_API_Name__c;
        if (String.isBlank(objectApiName) || !ALLOWED_OBJECTS.contains(objectApiName)) {
            throw new AuraHandledException(
                'Template targets an unsupported object: ' + objectApiName
            );
        }

        Id donorRecordId = Id.valueOf(job.Record_Id__c);
        String donorType = donorRecordId.getSObjectType().getDescribe().getName();
        if (donorType != objectApiName) {
            throw new AuraHandledException(
                'Record Id type (' + donorType + ') does not match template object (' +
                objectApiName + ').'
            );
        }

        Set<String> selectPaths = new Set<String>();
        for (PDF_Field_Mapping__c mapping : mappings) {
            if (String.isNotBlank(mapping.Salesforce_Field_Path__c)) {
                selectPaths.add(mapping.Salesforce_Field_Path__c.trim());
            }
        }
        if (selectPaths.isEmpty()) {
            throw new AuraHandledException('Template mappings do not include Salesforce field paths.');
        }

        Schema.SObjectType donorTypeToken = Schema.getGlobalDescribe().get(objectApiName);
        if (donorTypeToken == null) {
            throw new AuraHandledException('Unable to describe object: ' + objectApiName);
        }
        for (String path : selectPaths) {
            validateFieldPath(donorTypeToken, path);
        }

        String soql =
            'SELECT ' +
            String.join(new List<String>(selectPaths), ', ') +
            ' FROM ' +
            String.escapeSingleQuotes(objectApiName) +
            ' WHERE Id = :donorRecordId LIMIT 1';

        List<SObject> records = Database.query(soql);
        if (records.isEmpty()) {
            throw new AuraHandledException(
                'Unable to find ' + objectApiName + ' record ' + donorRecordId
            );
        }
        SObject donor = records[0];

        List<FieldValuePacket> fieldValues = new List<FieldValuePacket>();
        for (PDF_Field_Mapping__c mapping : mappings) {
            FieldValuePacket packet = new FieldValuePacket();
            packet.pdfFieldName = mapping.PDF_Field_Name__c;
            packet.salesforceFieldPath = mapping.Salesforce_Field_Path__c;
            packet.fieldValue = resolveFieldValue(donor, mapping.Salesforce_Field_Path__c);
            fieldValues.add(packet);
        }

        String contentDocumentId = job.Template_Id__r.File_Id__c;
        String templateBase64 = loadTemplateBase64(contentDocumentId);

        PdfJobPacket packet = new PdfJobPacket();
        packet.jobId = job.Id;
        packet.jobName = job.Name;
        packet.recordId = donorRecordId;
        packet.templateId = job.Template_Id__c;
        packet.templateName = job.Template_Id__r.Name;
        packet.objectApiName = objectApiName;
        packet.contentDocumentId = contentDocumentId;
        packet.templateBase64 = templateBase64;
        packet.fieldValues = fieldValues;
        return packet;
    }

    private static String loadTemplateBase64(String fileId) {
        if (String.isBlank(fileId)) {
            throw new AuraHandledException('Template is missing File Id.');
        }

        Id parsedId;
        try {
            parsedId = Id.valueOf(fileId);
        } catch (Exception ex) {
            throw new AuraHandledException('Template File Id is invalid: ' + fileId);
        }

        String idType = parsedId.getSObjectType().getDescribe().getName();
        ContentVersion cv;

        if (idType == 'ContentDocument') {
            List<ContentVersion> versions = [
                SELECT Id, VersionData, Title
                FROM ContentVersion
                WHERE ContentDocumentId = :parsedId AND IsLatest = true
                WITH SECURITY_ENFORCED
                LIMIT 1
            ];
            if (versions.isEmpty()) {
                throw new AuraHandledException(
                    'No ContentVersion found for ContentDocument ' + parsedId
                );
            }
            cv = versions[0];
        } else if (idType == 'ContentVersion') {
            List<ContentVersion> versions = [
                SELECT Id, VersionData, Title
                FROM ContentVersion
                WHERE Id = :parsedId
                WITH SECURITY_ENFORCED
                LIMIT 1
            ];
            if (versions.isEmpty()) {
                throw new AuraHandledException('ContentVersion not found: ' + parsedId);
            }
            cv = versions[0];
        } else {
            throw new AuraHandledException(
                'Template File Id must be a ContentDocument or ContentVersion Id.'
            );
        }

        if (cv.VersionData == null) {
            throw new AuraHandledException('Template PDF VersionData is empty.');
        }
        return EncodingUtil.base64Encode(cv.VersionData);
    }

    private static String resolveFieldValue(SObject source, String fieldPath) {
        if (source == null || String.isBlank(fieldPath)) {
            return '';
        }

        List<String> parts = fieldPath.trim().split('\\.');
        SObject current = source;

        for (Integer i = 0; i < parts.size(); i++) {
            String part = parts[i];
            if (current == null) {
                return '';
            }
            if (i == parts.size() - 1) {
                Object raw = current.get(part);
                return raw == null ? '' : String.valueOf(raw);
            }
            current = current.getSObject(part);
        }
        return '';
    }

    private static void validateFieldPath(Schema.SObjectType rootType, String fieldPath) {
        if (rootType == null || String.isBlank(fieldPath)) {
            throw new AuraHandledException('Salesforce field path is required.');
        }
        if (!Pattern.matches('^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)*$', fieldPath)) {
            throw new AuraHandledException('Invalid Salesforce field path syntax: ' + fieldPath);
        }

        List<String> parts = fieldPath.split('\\.');
        Schema.SObjectType currentType = rootType;

        for (Integer i = 0; i < parts.size(); i++) {
            String part = parts[i];
            Map<String, Schema.SObjectField> fields = currentType.getDescribe().fields.getMap();

            if (i == parts.size() - 1) {
                if (!fields.containsKey(part)) {
                    throw new AuraHandledException(
                        'Unknown field "' + part + '" on ' + currentType.getDescribe().getName()
                    );
                }
                return;
            }

            Schema.SObjectField relationshipField = findRelationshipField(fields, part);
            if (relationshipField == null) {
                throw new AuraHandledException(
                    'Unknown relationship "' + part + '" on ' + currentType.getDescribe().getName()
                );
            }
            List<Schema.SObjectType> references =
                relationshipField.getDescribe().getReferenceTo();
            if (references == null || references.isEmpty()) {
                throw new AuraHandledException(
                    'Relationship "' + part + '" does not reference another object.'
                );
            }
            currentType = references[0];
        }
    }

    private static Schema.SObjectField findRelationshipField(
        Map<String, Schema.SObjectField> fields,
        String relationshipName
    ) {
        for (Schema.SObjectField fieldToken : fields.values()) {
            Schema.DescribeFieldResult describe = fieldToken.getDescribe();
            if (describe.getType() != Schema.DisplayType.REFERENCE) {
                continue;
            }
            if (describe.getRelationshipName() == relationshipName) {
                return fieldToken;
            }
        }
        return null;
    }

    private static void markJobFailed(Id jobId, String errorMessage) {
        if (jobId == null) {
            return;
        }
        try {
            Pending_PDF_Generation__c job = new Pending_PDF_Generation__c(
                Id = jobId,
                Status__c = 'Failed',
                Error_Message__c = truncateError(errorMessage)
            );
            if (Schema.sObjectType.Pending_PDF_Generation__c.isUpdateable()) {
                update job;
            }
        } catch (Exception ignore) {
            // Best-effort failure marking; original exception is rethrown by caller.
        }
    }

    private static String truncateError(String message) {
        if (message == null) {
            return 'Unknown error.';
        }
        Integer maxLen = 32000;
        return message.length() <= maxLen ? message : message.substring(0, maxLen);
    }
}
