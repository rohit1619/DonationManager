/**
 * Test coverage for PDFTemplateConfigController.
 */
@IsTest
private class PDFTemplateConfigControllerTest {
    @IsTest
    static void saveTemplate_createsTemplateMappingsAndFile() {
        String tinyPdfBase64 = EncodingUtil.base64Encode(Blob.valueOf('%PDF-1.4 test'));

        List<PDFTemplateConfigController.FieldMappingInput> mappings =
            new List<PDFTemplateConfigController.FieldMappingInput>();
        PDFTemplateConfigController.FieldMappingInput mapping =
            new PDFTemplateConfigController.FieldMappingInput();
        mapping.pdfFieldName = 'AccountName';
        mapping.salesforceFieldPath = 'Name';
        mappings.add(mapping);

        Test.startTest();
        PDFTemplateConfigController.SaveTemplateResult result =
            PDFTemplateConfigController.saveTemplate(
                'Account Letter',
                'Account',
                'account-letter.pdf',
                tinyPdfBase64,
                mappings
            );
        Test.stopTest();

        System.assertNotEquals(null, result.templateId, 'Template Id should be returned');
        System.assertNotEquals(null, result.contentDocumentId, 'ContentDocument Id should be returned');
        System.assertEquals(1, result.mappingCount, 'One mapping should be saved');

        PDF_Template__c template = [
            SELECT Name, Object_API_Name__c, File_Id__c
            FROM PDF_Template__c
            WHERE Id = :result.templateId
        ];
        System.assertEquals('Account Letter', template.Name);
        System.assertEquals('Account', template.Object_API_Name__c);
        System.assertEquals(String.valueOf(result.contentDocumentId), template.File_Id__c);

        Integer mappingCount = [
            SELECT COUNT()
            FROM PDF_Field_Mapping__c
            WHERE PDF_Template__c = :result.templateId
        ];
        System.assertEquals(1, mappingCount);
    }

    @IsTest
    static void saveTemplate_rejectsUnsupportedObject() {
        PDFTemplateConfigController.FieldMappingInput mapping =
            new PDFTemplateConfigController.FieldMappingInput();
        mapping.pdfFieldName = 'Field1';
        mapping.salesforceFieldPath = 'Name';

        Boolean didThrow = false;
        try {
            PDFTemplateConfigController.saveTemplate(
                'Bad Template',
                'Opportunity',
                'bad.pdf',
                EncodingUtil.base64Encode(Blob.valueOf('x')),
                new List<PDFTemplateConfigController.FieldMappingInput>{ mapping }
            );
        } catch (AuraHandledException ex) {
            didThrow = true;
        }
        System.assertEquals(true, didThrow, 'Unsupported object should raise AuraHandledException');
    }

    @IsTest
    static void getSupportedObjects_returnsAccountAndContact() {
        List<Map<String, String>> options = PDFTemplateConfigController.getSupportedObjects();
        System.assertEquals(2, options.size());
        System.assertEquals('Account', options[0].get('value'));
        System.assertEquals('Contact', options[1].get('value'));
    }
}
