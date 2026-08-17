/**
 * Admin-facing Apex controller for configuring fillable PDF templates.
 * Persists uploaded AcroForm PDFs as ContentVersion records and stores
 * PDF_Template__c / PDF_Field_Mapping__c configuration metadata.
 */
public with sharing class PDFTemplateConfigController {
    private static final Set<String> ALLOWED_OBJECTS = new Set<String>{
        'Account',
        'Contact'
    };

    public class FieldMappingInput {
        @AuraEnabled public String pdfFieldName { get; set; }
        @AuraEnabled public String salesforceFieldPath { get; set; }
    }

    public class SaveTemplateResult {
        @AuraEnabled public Id templateId { get; set; }
        @AuraEnabled public Id contentVersionId { get; set; }
        @AuraEnabled public Id contentDocumentId { get; set; }
        @AuraEnabled public Integer mappingCount { get; set; }
    }

    /**
     * Persists an uploaded PDF template, creates the template record,
     * and inserts the field-mapping child matrix.
     */
    @AuraEnabled
    public static SaveTemplateResult saveTemplate(
        String templateName,
        String objectApiName,
        String fileName,
        String base64Data,
        List<FieldMappingInput> mappings
    ) {
        try {
            validateSaveInputs(templateName, objectApiName, fileName, base64Data, mappings);
            assertCreateAccess();

            String sanitizedObject = objectApiName.trim();
            if (!ALLOWED_OBJECTS.contains(sanitizedObject)) {
                throw new AuraHandledException(
                    'Unsupported object API name. Allowed values: Account, Contact.'
                );
            }

            ContentVersion cv = new ContentVersion();
            cv.Title = String.isBlank(fileName)
                ? templateName.trim()
                : fileName.trim().replaceAll('\\.pdf$', '');
            cv.PathOnClient = String.isBlank(fileName)
                ? (templateName.trim() + '.pdf')
                : fileName.trim();
            if (!cv.PathOnClient.toLowerCase().endsWith('.pdf')) {
                cv.PathOnClient += '.pdf';
            }
            cv.VersionData = EncodingUtil.base64Decode(base64Data);
            cv.IsMajorVersion = true;
            insert cv;

            ContentVersion insertedCv = [
                SELECT Id, ContentDocumentId
                FROM ContentVersion
                WHERE Id = :cv.Id
                WITH SECURITY_ENFORCED
                LIMIT 1
            ];

            PDF_Template__c template = new PDF_Template__c();
            template.Name = templateName.trim();
            template.Object_API_Name__c = sanitizedObject;
            template.File_Id__c = String.valueOf(insertedCv.ContentDocumentId);
            insert template;

            List<PDF_Field_Mapping__c> mappingRows = new List<PDF_Field_Mapping__c>();
            Set<String> seenPdfFields = new Set<String>();

            for (FieldMappingInput mapping : mappings) {
                if (mapping == null) {
                    continue;
                }
                String pdfField = mapping.pdfFieldName == null
                    ? null
                    : mapping.pdfFieldName.trim();
                String sfPath = mapping.salesforceFieldPath == null
                    ? null
                    : mapping.salesforceFieldPath.trim();

                if (String.isBlank(pdfField) || String.isBlank(sfPath)) {
                    continue;
                }
                if (seenPdfFields.contains(pdfField)) {
                    throw new AuraHandledException(
                        'Duplicate PDF field mapping found for: ' + pdfField
                    );
                }
                seenPdfFields.add(pdfField);

                PDF_Field_Mapping__c row = new PDF_Field_Mapping__c();
                row.PDF_Template__c = template.Id;
                row.PDF_Field_Name__c = pdfField;
                row.Salesforce_Field_Path__c = sfPath;
                mappingRows.add(row);
            }

            if (mappingRows.isEmpty()) {
                throw new AuraHandledException(
                    'At least one valid PDF field mapping is required.'
                );
            }

            insert mappingRows;

            SaveTemplateResult result = new SaveTemplateResult();
            result.templateId = template.Id;
            result.contentVersionId = insertedCv.Id;
            result.contentDocumentId = insertedCv.ContentDocumentId;
            result.mappingCount = mappingRows.size();
            return result;
        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (DmlException dmlEx) {
            throw new AuraHandledException(
                'Unable to save PDF template configuration: ' + dmlEx.getDmlMessage(0)
            );
        } catch (Exception ex) {
            throw new AuraHandledException(
                'Unexpected error saving PDF template: ' + ex.getMessage()
            );
        }
    }

    /**
     * Returns supported target objects for the admin combobox.
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getSupportedObjects() {
        List<Map<String, String>> options = new List<Map<String, String>>();
        options.add(new Map<String, String>{ 'label' => 'Account', 'value' => 'Account' });
        options.add(new Map<String, String>{ 'label' => 'Contact', 'value' => 'Contact' });
        return options;
    }

    private static void validateSaveInputs(
        String templateName,
        String objectApiName,
        String fileName,
        String base64Data,
        List<FieldMappingInput> mappings
    ) {
        if (String.isBlank(templateName)) {
            throw new AuraHandledException('Template name is required.');
        }
        if (String.isBlank(objectApiName)) {
            throw new AuraHandledException('Object API name is required.');
        }
        if (String.isBlank(base64Data)) {
            throw new AuraHandledException('PDF file content is required.');
        }
        if (mappings == null || mappings.isEmpty()) {
            throw new AuraHandledException('Field mappings are required.');
        }
        if (String.isNotBlank(fileName) && !fileName.toLowerCase().endsWith('.pdf')) {
            throw new AuraHandledException('Uploaded file must be a PDF.');
        }
    }

    private static void assertCreateAccess() {
        if (!Schema.sObjectType.ContentVersion.isCreateable()) {
            throw new AuraHandledException('Insufficient permission to create ContentVersion.');
        }
        if (!Schema.sObjectType.PDF_Template__c.isCreateable()) {
            throw new AuraHandledException('Insufficient permission to create PDF Template records.');
        }
        if (!Schema.sObjectType.PDF_Field_Mapping__c.isCreateable()) {
            throw new AuraHandledException('Insufficient permission to create PDF Field Mapping records.');
        }
        Map<String, Schema.SObjectField> templateFields = Schema.sObjectType.PDF_Template__c.fields.getMap();
        if (
            !templateFields.get('Object_API_Name__c').getDescribe().isCreateable() ||
            !templateFields.get('File_Id__c').getDescribe().isCreateable()
        ) {
            throw new AuraHandledException('Insufficient field-level access on PDF Template.');
        }
        Map<String, Schema.SObjectField> mappingFields = Schema.sObjectType.PDF_Field_Mapping__c.fields.getMap();
        if (
            !mappingFields.get('PDF_Field_Name__c').getDescribe().isCreateable() ||
            !mappingFields.get('Salesforce_Field_Path__c').getDescribe().isCreateable() ||
            !mappingFields.get('PDF_Template__c').getDescribe().isCreateable()
        ) {
            throw new AuraHandledException('Insufficient field-level access on PDF Field Mapping.');
        }
    }
}
