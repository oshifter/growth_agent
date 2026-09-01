import { LightningElement, api, wire } from 'lwc';
import { getRecord, notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import recordDisposition from '@salesforce/apex/OmnishiftAction.recordDisposition';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

// Field API names are identical on Lead and Contact, so we build the qualified list
// from objectApiName at runtime and one component serves both.
const OMNISHIFT_FIELDS = [
    'Omnishift_Score__c',
    'Omnishift_Rank__c',
    'Omnishift_Why_Now__c',
    'Omnishift_Next_Action_Date__c',
    'Omnishift_Recommended_Owner__c',
    'Omnishift_Compliance_Status__c',
    'Omnishift_Draft_Subject__c',
    'Omnishift_Draft_Body__c',
    'Omnishift_Disposition__c',
    'Omnishift_Disposition_Reason__c',
    'Omnishift_Scored_On__c',
    'Omnishift_Run_Id__c'
];

const DISPOSITIONS = [
    { key: 'Approved and sent', label: 'Approve & send' },
    { key: 'Edited before send', label: 'Edit first' },
    { key: 'Call logged', label: 'Log call' },
    { key: 'Snoozed', label: 'Not now' },
    { key: 'Wrong person', label: 'Wrong person' }
];

export default class OmnishiftPanel extends LightningElement {
    @api recordId;
    @api objectApiName;

    record;
    error;
    isSaving = false;
    showDraft = false;

    get fieldList() {
        const obj = this.objectApiName || 'Lead';
        // IsPersonAccount only exists on Contact; requesting it on Lead would error,
        // so it is only added for Contact.
        const extra = obj === 'Contact' ? ['Contact.IsPersonAccount'] : [];
        // The lookup's own displayValue comes back null for a User lookup, which
        // put a raw 005... id on screen where the advisor's name belongs. Ask for
        // the spanning field instead.
        extra.push(`${obj}.Omnishift_Recommended_Owner__r.Name`);
        return OMNISHIFT_FIELDS.map((f) => `${obj}.${f}`).concat(extra);
    }

    @wire(getRecord, { recordId: '$recordId', fields: '$fieldList' })
    wiredRecord({ data, error }) {
        if (data) {
            this.record = data;
            this.error = undefined;
        } else if (error) {
            this.error = error;
            this.record = undefined;
        }
    }

    val(field) {
        const f = this.record && this.record.fields && this.record.fields[field];
        if (!f) return null;
        return f.displayValue !== null && f.displayValue !== undefined
            ? f.displayValue
            : f.value;
    }

    raw(field) {
        const f = this.record && this.record.fields && this.record.fields[field];
        return f ? f.value : null;
    }

    // ---- state -------------------------------------------------------------
    get isLoading() {
        return !this.record && !this.error;
    }
    get hasError() {
        return Boolean(this.error);
    }
    get isScored() {
        return Boolean(this.record && this.raw('Omnishift_Scored_On__c'));
    }
    get notScored() {
        return Boolean(this.record) && !this.isScored;
    }
    get isPersonContact() {
        return Boolean(this.raw('IsPersonAccount'));
    }

    // ---- display -----------------------------------------------------------
    get score() {
        return this.raw('Omnishift_Score__c');
    }
    get rank() {
        const r = this.raw('Omnishift_Rank__c');
        return r === null ? null : String(r).padStart(2, '0');
    }
    get whyNow() {
        return this.val('Omnishift_Why_Now__c');
    }
    get nextActionDate() {
        return this.val('Omnishift_Next_Action_Date__c');
    }
    get recommendedOwner() {
        const rel =
            this.record &&
            this.record.fields &&
            this.record.fields.Omnishift_Recommended_Owner__r;
        const name = rel && rel.value && rel.value.fields && rel.value.fields.Name;
        if (name && name.value) return name.value;
        // Nobody routed to, rather than routed to an id we could not resolve.
        return this.raw('Omnishift_Recommended_Owner__c') ? 'Unresolved user' : 'Unassigned';
    }
    get runId() {
        return this.val('Omnishift_Run_Id__c');
    }
    get scoredOn() {
        return this.val('Omnishift_Scored_On__c');
    }
    get draftSubject() {
        return this.val('Omnishift_Draft_Subject__c');
    }
    get draftBody() {
        return this.val('Omnishift_Draft_Body__c');
    }
    get lastDisposition() {
        return this.val('Omnishift_Disposition__c');
    }
    get dispositionReason() {
        return this.val('Omnishift_Disposition_Reason__c');
    }
    get hasDisposition() {
        return Boolean(this.lastDisposition);
    }

    get complianceStatus() {
        return this.val('Omnishift_Compliance_Status__c') || 'Not checked';
    }
    get complianceIsBlocked() {
        return this.raw('Omnishift_Compliance_Status__c') === 'Blocked';
    }
    get complianceTheme() {
        const s = this.raw('Omnishift_Compliance_Status__c');
        if (s === 'Blocked') return 'slds-theme_error';
        if (s === 'Flagged') return 'slds-theme_warning';
        return 'slds-theme_success';
    }
    get complianceIcon() {
        const s = this.raw('Omnishift_Compliance_Status__c');
        if (s === 'Blocked') return 'utility:error';
        if (s === 'Flagged') return 'utility:warning';
        if (s === 'Auto-corrected') return 'utility:edit';
        return 'utility:success';
    }

    get draftButtonLabel() {
        return this.showDraft ? 'Hide draft' : 'Show draft';
    }

    // Every action carries equal visual weight. Salesforce publishes the opposite as an
    // anti-pattern: send must not outrank edit, so nobody sends AI copy unread.
    get actions() {
        return DISPOSITIONS.map((d) => ({
            ...d,
            // A compliance block stops the send. It must never stop the phone call.
            disabled:
                this.isSaving ||
                (this.complianceIsBlocked && d.key === 'Approved and sent'),
            variant: d.key === 'Wrong person' ? 'destructive-text' : 'neutral'
        }));
    }

    // ---- behaviour ---------------------------------------------------------
    toggleDraft() {
        this.showDraft = !this.showDraft;
    }

    async handleDisposition(event) {
        const disposition = event.currentTarget.dataset.disposition;
        if (this.isPersonContact) {
            this.toast(
                'Person account',
                'Salesforce requires changes to a person account to go through the Account, not the Contact.',
                'warning'
            );
            return;
        }
        this.isSaving = true;
        const reason =
            disposition === 'Wrong person'
                ? 'Marked wrong person from the Omnishift panel.'
                : null;
        try {
            // Apex, not updateRecord: approving has to log the activity and clear
            // the next action date in the same transaction as the disposition,
            // or the lead comes back in tomorrow's queue as though nothing happened.
            const message = await recordDisposition({
                recordId: this.recordId,
                disposition,
                reason,
                subject: this.draftSubject,
                body: this.draftBody
            });
            await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
            this.toast('Recorded', message, 'success');
            this.dispatchEvent(
                new CustomEvent('dispositioned', {
                    detail: { recordId: this.recordId, disposition },
                    bubbles: true,
                    composed: true
                })
            );
        } catch (e) {
            const msg =
                (e && e.body && (e.body.message || JSON.stringify(e.body))) ||
                (e && e.message) ||
                'Unknown error';
            this.toast('Could not save', msg, 'error');
        } finally {
            this.isSaving = false;
        }
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
