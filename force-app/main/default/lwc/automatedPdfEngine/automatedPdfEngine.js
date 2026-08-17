import { LightningElement, api, track } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import PDF_LIB from '@salesforce/resourceUrl/pdfLib';
import getPendingJobs from '@salesforce/apex/BackgroundPdfQueueController.getPendingJobs';
import finalizeJob from '@salesforce/apex/BackgroundPdfQueueController.finalizeJob';
import failJob from '@salesforce/apex/BackgroundPdfQueueController.failJob';

const POLL_INTERVAL_MS = 15000;
const MAX_JOBS_PER_POLL = 1;

export default class AutomatedPdfEngine extends LightningElement {
    /**
     * When true, hides the utility panel chrome (used when embedded in admin UI).
     */
    @api hideChrome = false;

    @track statusMessage = 'Starting PDF engine...';

    pdfLibInitialized = false;
    pollTimerId;
    isProcessing = false;
    isDestroyed = false;

    connectedCallback() {
        this.isDestroyed = false;
        this.bootstrap();
    }

    disconnectedCallback() {
        this.isDestroyed = true;
        this.stopPolling();
    }

    get showChrome() {
        return !this.hideChrome;
    }

    get containerClass() {
        return this.hideChrome ? 'engine-host engine-host_hidden' : 'engine-host';
    }

    async bootstrap() {
        try {
            this.statusMessage = 'Loading pdf-lib...';
            await this.ensurePdfLib();
            this.statusMessage = 'Idle — waiting for pending jobs.';
            this.startPolling();
            await this.processQueue();
        } catch (error) {
            this.statusMessage = this.normalizeError(
                error,
                'Bootstrap failed; retrying on poll interval.'
            );
            // eslint-disable-next-line no-console
            console.error('automatedPdfEngine bootstrap failed', error);
            this.startPolling();
        }
    }

    startPolling() {
        this.stopPolling();
        this.pollTimerId = window.setInterval(() => {
            this.processQueue();
        }, POLL_INTERVAL_MS);
    }

    stopPolling() {
        if (this.pollTimerId) {
            window.clearInterval(this.pollTimerId);
            this.pollTimerId = null;
        }
    }

    async ensurePdfLib() {
        if (this.pdfLibInitialized && window.PDFLib && window.PDFLib.PDFDocument) {
            return;
        }
        await loadScript(this, PDF_LIB);
        if (!window.PDFLib || !window.PDFLib.PDFDocument) {
            throw new Error('pdf-lib failed to expose window.PDFLib.PDFDocument.');
        }
        this.pdfLibInitialized = true;
    }

    async processQueue() {
        if (this.isDestroyed || this.isProcessing) {
            return;
        }

        this.isProcessing = true;
        try {
            await this.ensurePdfLib();
            const jobs = await getPendingJobs({ maxJobs: MAX_JOBS_PER_POLL });
            if (!Array.isArray(jobs) || jobs.length === 0) {
                this.statusMessage = 'Idle — waiting for pending jobs.';
                return;
            }

            for (const job of jobs) {
                if (this.isDestroyed) {
                    break;
                }
                this.statusMessage = 'Processing ' + (job.jobName || job.jobId) + '...';
                await this.processSingleJob(job);
            }
            this.statusMessage = 'Idle — waiting for pending jobs.';
        } catch (error) {
            this.statusMessage = this.normalizeError(error, 'Poll cycle failed.');
            // eslint-disable-next-line no-console
            console.error('automatedPdfEngine poll cycle failed', error);
        } finally {
            this.isProcessing = false;
        }
    }

    async processSingleJob(job) {
        if (!job || !job.jobId) {
            return;
        }

        try {
            if (!job.templateBase64) {
                throw new Error('Job packet is missing templateBase64 content.');
            }
            if (!Array.isArray(job.fieldValues) || job.fieldValues.length === 0) {
                throw new Error('Job packet contains no field values to apply.');
            }

            const templateBytes = this.base64ToUint8Array(job.templateBase64);
            const pdfDoc = await window.PDFLib.PDFDocument.load(templateBytes, {
                ignoreEncryption: true
            });
            const form = pdfDoc.getForm();

            for (const fieldValue of job.fieldValues) {
                if (!fieldValue || !fieldValue.pdfFieldName) {
                    continue;
                }
                try {
                    const textField = form.getTextField(fieldValue.pdfFieldName);
                    textField.setText(
                        fieldValue.fieldValue == null ? '' : String(fieldValue.fieldValue)
                    );
                } catch (fieldError) {
                    throw new Error(
                        'Unable to set PDF field "' +
                            fieldValue.pdfFieldName +
                            '": ' +
                            this.normalizeError(fieldError, 'unknown field error')
                    );
                }
            }

            form.flatten();

            const filledBytes = await pdfDoc.save();
            const outputBase64 = this.uint8ArrayToBase64(filledBytes);
            const outputName =
                (job.templateName ? job.templateName : 'GeneratedPDF') +
                '_' +
                (job.jobName ? job.jobName : String(job.jobId));

            await finalizeJob({
                jobId: job.jobId,
                base64Pdf: outputBase64,
                outputFileName: outputName
            });
        } catch (error) {
            const message = this.normalizeError(error, 'PDF generation failed in browser worker.');
            // eslint-disable-next-line no-console
            console.error('automatedPdfEngine job failed', job.jobId, message);
            try {
                await failJob({ jobId: job.jobId, errorMessage: message });
            } catch (failError) {
                // eslint-disable-next-line no-console
                console.error('automatedPdfEngine failJob callback failed', failError);
            }
        }
    }

    base64ToUint8Array(base64) {
        const binary = window.atob(base64);
        const length = binary.length;
        const bytes = new Uint8Array(length);
        for (let i = 0; i < length; i += 1) {
            bytes[i] = binary.charCodeAt(i);
        }
        return bytes;
    }

    uint8ArrayToBase64(bytes) {
        const chunkSize = 0x8000;
        let binary = '';
        for (let i = 0; i < bytes.length; i += chunkSize) {
            const chunk = bytes.subarray(i, i + chunkSize);
            binary += String.fromCharCode.apply(null, chunk);
        }
        return window.btoa(binary);
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
