import { LightningElement, track } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import PDF_LIB from '@salesforce/resourceUrl/pdfLib';
import saveTemplate from '@salesforce/apex/PDFTemplateConfigController.saveTemplate';
import getSupportedObjects from '@salesforce/apex/PDFTemplateConfigController.getSupportedObjects';

export default class PdfTemplateManager extends LightningElement {
    @track templateName = '';
    @track objectApiName = '';
    @track objectOptions = [];
    @track fieldMappings = [];
    @track errorMessage = '';
    @track successMessage = '';
    @track isLibraryLoading = true;
    @track isSaving = false;
    @track selectedFileLabel = 'or drop a fillable PDF';

    pdfLibInitialized = false;
    selectedFileName = '';
    pdfBase64 = '';

    connectedCallback() {
        this.initializeLibrary();
        this.loadObjectOptions();
    }

    get hasDiscoveredFields() {
        return Array.isArray(this.fieldMappings) && this.fieldMappings.length > 0;
    }

    get isSaveDisabled() {
        return (
            this.isSaving ||
            this.isLibraryLoading ||
            !this.templateName ||
            !this.objectApiName ||
            !this.pdfBase64 ||
            !this.hasDiscoveredFields
        );
    }

    async initializeLibrary() {
        this.isLibraryLoading = true;
        this.errorMessage = '';
        try {
            if (!this.pdfLibInitialized) {
                await loadScript(this, PDF_LIB);
                this.pdfLibInitialized = true;
            }
            if (!window.PDFLib || !window.PDFLib.PDFDocument) {
                throw new Error('pdf-lib did not initialize on window.PDFLib.');
            }
        } catch (error) {
            this.errorMessage = this.normalizeError(
                error,
                'Unable to load the pdf-lib static resource.'
            );
        } finally {
            this.isLibraryLoading = false;
        }
    }

    async loadObjectOptions() {
        try {
            const options = await getSupportedObjects();
            this.objectOptions = Array.isArray(options) ? options : [];
            if (!this.objectApiName && this.objectOptions.length > 0) {
                this.objectApiName = this.objectOptions[0].value;
            }
        } catch (error) {
            this.objectOptions = [
                { label: 'Account', value: 'Account' },
                { label: 'Contact', value: 'Contact' }
            ];
            this.errorMessage = this.normalizeError(
                error,
                'Unable to load supported objects; using defaults.'
            );
        }
    }

    handleTemplateNameChange(event) {
        this.templateName = event.target.value;
        this.successMessage = '';
    }

    handleObjectChange(event) {
        this.objectApiName = event.detail.value;
        this.successMessage = '';
    }

    handleMappingChange(event) {
        const pdfFieldName = event.target.dataset.pdfField;
        const value = event.target.value;
        this.fieldMappings = this.fieldMappings.map((row) => {
            if (row.pdfFieldName === pdfFieldName) {
                return {
                    ...row,
                    salesforceFieldPath: value
                };
            }
            return row;
        });
        this.successMessage = '';
    }

    async handleFileChange(event) {
        this.errorMessage = '';
        this.successMessage = '';
        this.fieldMappings = [];
        this.pdfBase64 = '';
        this.selectedFileName = '';
        this.selectedFileLabel = 'or drop a fillable PDF';

        const files = event.target.files;
        if (!files || files.length === 0) {
            return;
        }

        const file = files[0];
        if (!file || !file.name || !file.name.toLowerCase().endsWith('.pdf')) {
            this.errorMessage = 'Please upload a valid PDF file.';
            return;
        }

        if (!window.PDFLib || !window.PDFLib.PDFDocument) {
            this.errorMessage = 'PDF library is not ready. Refresh and try again.';
            return;
        }

        this.selectedFileName = file.name;
        this.selectedFileLabel = file.name;
        this.isLibraryLoading = true;

        try {
            const arrayBuffer = await this.readFileAsArrayBuffer(file);
            const pdfDoc = await window.PDFLib.PDFDocument.load(arrayBuffer, {
                ignoreEncryption: true
            });
            const form = pdfDoc.getForm();
            const fields = form.getFields();

            const discovered = [];
            const seen = new Set();

            fields.forEach((field) => {
                let name = '';
                try {
                    name = field.getName();
                } catch (ignore) {
                    name = '';
                }
                if (!name || seen.has(name)) {
                    return;
                }

                const ctorName = field.constructor && field.constructor.name
                    ? field.constructor.name
                    : '';
                const isTextField =
                    ctorName === 'PDFTextField' ||
                    (typeof field.setText === 'function' && typeof field.getText === 'function');

                if (!isTextField) {
                    return;
                }

                seen.add(name);
                discovered.push({
                    pdfFieldName: name,
                    salesforceFieldPath: ''
                });
            });

            if (discovered.length === 0) {
                throw new Error(
                    'No fillable AcroForm text fields were found in the uploaded PDF.'
                );
            }

            this.fieldMappings = discovered;
            this.pdfBase64 = this.arrayBufferToBase64(arrayBuffer);
        } catch (error) {
            this.fieldMappings = [];
            this.pdfBase64 = '';
            this.errorMessage = this.normalizeError(
                error,
                'Unable to inspect the uploaded PDF form fields.'
            );
        } finally {
            this.isLibraryLoading = false;
        }
    }

    async handleSave() {
        this.errorMessage = '';
        this.successMessage = '';

        if (!this.templateName || !this.templateName.trim()) {
            this.errorMessage = 'Template name is required.';
            return;
        }
        if (!this.objectApiName) {
            this.errorMessage = 'Salesforce object selection is required.';
            return;
        }
        if (!this.pdfBase64) {
            this.errorMessage = 'Upload a fillable PDF before saving.';
            return;
        }

        const incomplete = this.fieldMappings.find(
            (row) => !row.salesforceFieldPath || !row.salesforceFieldPath.trim()
        );
        if (incomplete) {
            this.errorMessage =
                'Provide a Salesforce field path for every discovered PDF field.';
            return;
        }

        this.isSaving = true;
        try {
            const result = await saveTemplate({
                templateName: this.templateName.trim(),
                objectApiName: this.objectApiName,
                fileName: this.selectedFileName,
                base64Data: this.pdfBase64,
                mappings: this.fieldMappings.map((row) => ({
                    pdfFieldName: row.pdfFieldName,
                    salesforceFieldPath: row.salesforceFieldPath.trim()
                }))
            });

            this.successMessage =
                'Template saved successfully. Id: ' +
                result.templateId +
                ' (' +
                result.mappingCount +
                ' mappings).';
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'PDF Template Saved',
                    message: 'Configuration and mappings were created successfully.',
                    variant: 'success'
                })
            );
        } catch (error) {
            this.errorMessage = this.normalizeError(
                error,
                'Unable to save the PDF template configuration.'
            );
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Save Failed',
                    message: this.errorMessage,
                    variant: 'error',
                    mode: 'sticky'
                })
            );
        } finally {
            this.isSaving = false;
        }
    }

    readFileAsArrayBuffer(file) {
        return new Promise((resolve, reject) => {
            const reader = new FileReader();
            reader.onload = () => {
                resolve(reader.result);
            };
            reader.onerror = () => {
                reject(new Error('FileReader failed to load the selected PDF.'));
            };
            reader.readAsArrayBuffer(file);
        });
    }

    arrayBufferToBase64(buffer) {
        const bytes = new Uint8Array(buffer);
        const chunkSize = 0x8000;
        let binary = '';
        for (let i = 0; i < bytes.length; i += chunkSize) {
            const chunk = bytes.subarray(i, i + chunkSize);
            binary += String.fromCharCode.apply(null, chunk);
        }
        return btoa(binary);
    }

    normalizeError(error, fallbackMessage) {
        if (!error) {
            return fallbackMessage;
        }
        if (typeof error === 'string') {
            return error;
        }
        if (error.body && error.body.message) {
            return error.body.message;
        }
        if (Array.isArray(error.body) && error.body.length > 0 && error.body[0].message) {
            return error.body[0].message;
        }
        if (error.message) {
            return error.message;
        }
        return fallbackMessage;
    }
}
