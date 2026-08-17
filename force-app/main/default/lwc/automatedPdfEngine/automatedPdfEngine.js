import { LightningElement, track } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import PDF_LIB from '@salesforce/resourceUrl/pdfLib';
import getPendingJobs from '@salesforce/apex/BackgroundPdfQueueController.getPendingJobs';
import finalizeJob from '@salesforce/apex/BackgroundPdfQueueController.finalizeJob';
import failJob from '@salesforce/apex/BackgroundPdfQueueController.failJob';

const POLL_INTERVAL_MS = 5000;
const MAX_JOBS_PER_POLL = 3;

export default class AutomatedPdfEngine extends LightningElement {
    @track statusMessage = 'Starting PDF engine...';
    @track lastError = '';
    @track isBusy = false;

    pdfLibInitialized = false;
    pollTimerId;
    isProcessing = false;
    isDestroyed = false;

    get pollSeconds() {
        return Math.round(POLL_INTERVAL_MS / 1000);
    }

    connectedCallback() {
        this.isDestroyed = false;
        this.bootstrap();
    }

    disconnectedCallback() {
        this.isDestroyed = true;
        this.stopPolling();
    }

    handleProcessNow() {
        this.processQueue(true);
    }

    async bootstrap() {
        try {
            this.statusMessage = 'Loading pdf-lib...';
            await this.ensurePdfLib();
            this.statusMessage = 'Ready — waiting for pending jobs.';
            this.lastError = '';
            this.startPolling();
            await this.processQueue(false);
        } catch (error) {
            const message = this.normalizeError(
                error,
                'Bootstrap failed; retrying on poll interval.'
            );
            this.statusMessage = message;
            this.lastError = message;
            // eslint-disable-next-line no-console
            console.error('automatedPdfEngine bootstrap failed', error);
            this.startPolling();
        }
    }

    startPolling() {
        this.stopPolling();
        this.pollTimerId = window.setInterval(() => {
            this.processQueue(false);
        }, POLL_INTERVAL_MS);
    }

    stopPolling() {
        if (this.pollTimerId) {
            window.clearInterval(this.pollTimerId);
            this.pollTimerId = null;
        }
    }

    resolvePdfLib() {
        const candidates = [
            typeof window !== 'undefined' ? window.PDFLib : null,
            typeof self !== 'undefined' ? self.PDFLib : null,
            typeof globalThis !== 'undefined' ? globalThis.PDFLib : null
        ];
        for (const candidate of candidates) {
            if (candidate && candidate.PDFDocument) {
                return candidate;
            }
        }
        return null;
    }

    async ensurePdfLib() {
        const existing = this.resolvePdfLib();
        if (this.pdfLibInitialized && existing) {
            return existing;
        }
        await loadScript(this, PDF_LIB);
        const loaded = this.resolvePdfLib();
        if (!loaded) {
            throw new Error(
                'pdf-lib loaded but PDFLib.PDFDocument was not found on window/self/globalThis.'
            );
        }
        this.pdfLibInitialized = true;
        return loaded;
    }

    async processQueue(manual) {
        if (this.isDestroyed || this.isProcessing) {
            return;
        }

        this.isProcessing = true;
        this.isBusy = true;
        try {
            const PDFLib = await this.ensurePdfLib();
            const jobs = await getPendingJobs({ maxJobs: MAX_JOBS_PER_POLL });
            if (!Array.isArray(jobs) || jobs.length === 0) {
                this.statusMessage = manual
                    ? 'No pending jobs found.'
                    : 'Ready — waiting for pending jobs.';
                if (manual) {
                    this.dispatchEvent(
                        new ShowToastEvent({
                            title: 'PDF Engine',
                            message: 'No pending jobs in the queue.',
                            variant: 'info'
                        })
                    );
                }
                return;
            }

            let completed = 0;
            for (const job of jobs) {
                if (this.isDestroyed) {
                    break;
                }
                this.statusMessage = 'Processing ' + (job.jobName || job.jobId) + '...';
                const ok = await this.processSingleJob(job, PDFLib);
                if (ok) {
                    completed += 1;
                }
            }

            this.statusMessage =
                'Processed ' + completed + ' of ' + jobs.length + ' job(s). Waiting for more...';
            this.lastError = '';
            if (manual) {
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'PDF Engine',
                        message: 'Processed ' + completed + ' of ' + jobs.length + ' job(s).',
                        variant: completed > 0 ? 'success' : 'warning'
                    })
                );
            }
        } catch (error) {
            const message = this.normalizeError(error, 'Poll cycle failed.');
            this.statusMessage = message;
            this.lastError = message;
            // eslint-disable-next-line no-console
            console.error('automatedPdfEngine poll cycle failed', error);
            if (manual) {
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'PDF Engine Error',
                        message: message,
                        variant: 'error',
                        mode: 'sticky'
                    })
                );
            }
        } finally {
            this.isProcessing = false;
            this.isBusy = false;
        }
    }

    async processSingleJob(job, PDFLib) {
        if (!job || !job.jobId) {
            return false;
        }

        try {
            if (!job.templateBase64) {
                throw new Error('Job packet is missing templateBase64 content.');
            }
            if (!Array.isArray(job.fieldValues) || job.fieldValues.length === 0) {
                throw new Error('Job packet contains no field values to apply.');
            }

            const templateBytes = this.base64ToUint8Array(job.templateBase64);
            const pdfDoc = await PDFLib.PDFDocument.load(templateBytes, {
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
            return true;
        } catch (error) {
            const message = this.normalizeError(error, 'PDF generation failed in browser worker.');
            this.lastError = message;
            // eslint-disable-next-line no-console
            console.error('automatedPdfEngine job failed', job.jobId, message);
            try {
                await failJob({ jobId: job.jobId, errorMessage: message });
            } catch (failError) {
                // eslint-disable-next-line no-console
                console.error('automatedPdfEngine failJob callback failed', failError);
            }
            return false;
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
