import { LightningElement, api, wire } from 'lwc';
import { getRecord, notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { getListRecordsByName } from 'lightning/uiListsApi';
import { NavigationMixin } from 'lightning/navigation';
import recordDisposition from '@salesforce/apex/OmnishiftAction.recordDisposition';
import personAccountsEnabled from '@salesforce/apex/OmnishiftAction.personAccountsEnabled';
import saveDraft from '@salesforce/apex/OmnishiftAction.saveDraft';
import sendDraft from '@salesforce/apex/OmnishiftAction.sendDraft';
import liveEmailEnabled from '@salesforce/apex/OmnishiftAction.liveEmailEnabled';
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
    'Omnishift_Compliance_Reason__c',
    'Omnishift_Draft_Subject__c',
    'Omnishift_Draft_Body__c',
    'Omnishift_Disposition__c',
    'Omnishift_Disposition_Reason__c',
    'Omnishift_Scored_On__c',
    'Omnishift_Run_Id__c'
];

// The advisor picks when to come back. recordDisposition takes the date, so the
// choice is written in the same transaction as the disposition.
const SNOOZE_PRESETS = [
    { label: 'Tomorrow', value: '1' },
    { label: 'In 3 days', value: '3' },
    { label: 'Next week', value: '7' },
    { label: 'In 2 weeks', value: '14' },
    { label: 'In a month', value: '30' },
    { label: 'Pick a date', value: 'custom' }
];

const DISPOSITIONS = [
    { key: 'Approved and sent', label: 'Approve & send' },
    { key: 'Edited before send', label: 'Edit first' },
    { key: 'Call logged', label: 'Log call' },
    { key: 'Snoozed', label: 'Not now' },
    { key: 'Wrong person', label: 'Wrong person' }
];

// Local calendar days throughout. Round-tripping through Date.parse on an ISO
// string reads it as UTC midnight, which lands on the wrong day west of Greenwich.
function isoOf(d) {
    const p = (n) => String(n).padStart(2, '0');
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}
function daysFromToday(n) {
    const d = new Date();
    d.setHours(0, 0, 0, 0);
    d.setDate(d.getDate() + n);
    return d;
}
function fromIso(iso) {
    const [y, m, d] = String(iso).split('-').map(Number);
    return new Date(y, m - 1, d);
}

export default class OmnishiftPanel extends NavigationMixin(LightningElement) {
    @api recordId;
    @api objectApiName;

    record;
    error;
    isSaving = false;
    showDraft = false;
    isEditing = false;
    editedSubject;
    editedBody;
    wasEdited = false;
    liveEmail = false;
    personAccounts = false;

    showSnooze = false;
    snoozeChoice = '7';
    snoozeCustomIso;

    // Snapshot, not a live read: the point of the queue walk is that the advisor
    // keeps their place, and dispositioned records drop straight out of the list.
    queueSnapshot;
    queueUnavailable = false;
    justDispositioned = false;

    get fieldList() {
        const obj = this.objectApiName || 'Lead';
        // IsPersonAccount only exists on Contact; requesting it on Lead would error,
        // so it is only added for Contact.
        // Contact.IsPersonAccount only exists in an org with Person Accounts on.
        // Asking for it anywhere else fails the whole getRecord, which surfaced as
        // a field-level-security error that had nothing to do with the cause.
        const extra =
            obj === 'Contact' && this.personAccounts ? ['Contact.IsPersonAccount'] : [];
        // The lookup's own displayValue comes back null for a User lookup, which
        // put a raw 005... id on screen where the advisor's name belongs. Ask for
        // the spanning field instead.
        extra.push(`${obj}.Omnishift_Recommended_Owner__r.Name`);
        return OMNISHIFT_FIELDS.map((f) => `${obj}.${f}`).concat(extra);
    }

    @wire(personAccountsEnabled)
    wiredPersonAccounts({ data }) {
        if (data !== undefined) this.personAccounts = data;
    }

    @wire(liveEmailEnabled)
    wiredLiveEmail({ data }) {
        if (data !== undefined) this.liveEmail = data;
    }

    // Today's ranked order, so the advisor can walk the list without going back
    // to the Home page and hunting for where they were. Always a Lead list view;
    // the nav is hidden on Contact rather than pointed at the wrong object.
    @wire(getListRecordsByName, {
        objectApiName: 'Lead',
        listViewApiName: 'Omnishift_Today',
        fields: ['Lead.Name'],
        sortBy: ['Lead.Omnishift_Rank__c'],
        pageSize: 50
    })
    wiredQueue({ data, error }) {
        if (error) {
            this.queueUnavailable = true;
            return;
        }
        if (!data || this.queueSnapshot) return;
        const rows = Array.isArray(data.records) ? data.records : null;
        if (!rows) {
            this.queueUnavailable = true;
            return;
        }
        this.queueSnapshot = rows.map((r) => ({
            id: r.id,
            name: r.fields && r.fields.Name ? r.fields.Name.value : 'the next record'
        }));
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
    get complianceReason() {
        // The status says what happened; the reason says why. A blocked draft is
        // useless to an advisor without the term that blocked it.
        return this.val('Omnishift_Compliance_Reason__c');
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

    get workingSubject() {
        return this.editedSubject !== undefined ? this.editedSubject : this.draftSubject;
    }
    get workingBody() {
        return this.editedBody !== undefined ? this.editedBody : this.draftBody;
    }
    get sendModeNote() {
        return this.liveEmail
            ? 'Approve and send delivers this to the prospect and logs it on the record.'
            : 'Live email is off in this org. Approve and send records the outreach without delivering it.';
    }

    // ---- today's queue -----------------------------------------------------
    get queueIndex() {
        if (this.objectApiName !== 'Lead' || !this.queueSnapshot) return -1;
        return this.queueSnapshot.findIndex((q) => q.id === this.recordId);
    }
    get inQueue() {
        return this.queueIndex >= 0;
    }
    get queuePosition() {
        return `${this.queueIndex + 1} of ${this.queueSnapshot.length} on today's list`;
    }
    get nextInQueue() {
        const i = this.queueIndex;
        return i >= 0 && this.queueSnapshot[i + 1] ? this.queueSnapshot[i + 1] : null;
    }
    get hasNext() {
        return Boolean(this.nextInQueue);
    }
    get nextLabel() {
        return `Next: ${this.nextInQueue.name}`;
    }
    get atQueueEnd() {
        return this.inQueue && !this.hasNext;
    }
    // Once something has been recorded, moving on is the obvious next step, so
    // it stops competing with the disposition buttons and starts leading.
    get nextVariant() {
        return this.justDispositioned ? 'brand' : 'neutral';
    }

    handleNext() {
        const n = this.nextInQueue;
        if (!n) return;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: n.id, objectApiName: 'Lead', actionName: 'view' }
        });
    }

    handleBackToQueue() {
        this[NavigationMixin.Navigate]({
            type: 'standard__namedPage',
            attributes: { pageName: 'home' }
        });
    }

    // ---- snooze ------------------------------------------------------------
    get snoozeOptions() {
        return SNOOZE_PRESETS;
    }
    get snoozeIsCustom() {
        return this.snoozeChoice === 'custom';
    }
    get todayIso() {
        return isoOf(daysFromToday(0));
    }
    get snoozeDate() {
        if (this.snoozeIsCustom) {
            return this.snoozeCustomIso ? fromIso(this.snoozeCustomIso) : null;
        }
        return daysFromToday(Number(this.snoozeChoice));
    }
    get snoozeIso() {
        const d = this.snoozeDate;
        return d ? isoOf(d) : null;
    }
    get snoozeLabel() {
        const d = this.snoozeDate;
        return d ? d.toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' }) : null;
    }
    get snoozeIsPast() {
        const d = this.snoozeDate;
        return Boolean(d) && isoOf(d) < this.todayIso;
    }
    get snoozeConfirmLabel() {
        return this.snoozeLabel ? `Snooze until ${this.snoozeLabel}` : 'Snooze';
    }
    get snoozeConfirmDisabled() {
        return this.isSaving || !this.snoozeDate || this.snoozeIsPast;
    }

    handleSnoozeChoice(event) {
        this.snoozeChoice = event.detail.value;
    }
    handleSnoozeDate(event) {
        this.snoozeCustomIso = event.detail.value;
    }
    handleCancelSnooze() {
        this.showSnooze = false;
    }

    async handleConfirmSnooze() {
        if (this.snoozeConfirmDisabled) return;
        if (this.isPersonContact) {
            this.toast(
                'Person account',
                'Salesforce requires changes to a person account to go through the Account, not the Contact.',
                'warning'
            );
            return;
        }
        const iso = this.snoozeIso;
        const label = this.snoozeLabel;
        this.isSaving = true;
        try {
            // One write. recordDisposition takes the date now, so the disposition,
            // the reason and the return date land in the same transaction - there
            // is no window where the record is snoozed for a week the advisor
            // never asked for.
            const message = await recordDisposition({
                recordId: this.recordId,
                disposition: 'Snoozed',
                reason: `Snoozed until ${label} from the Growth Agent panel.`,
                subject: null,
                body: null,
                snoozeUntil: iso
            });
            await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
            this.showSnooze = false;
            this.justDispositioned = true;
            this.toast('Snoozed', message, 'success');
            this.dispatchEvent(
                new CustomEvent('dispositioned', {
                    detail: { recordId: this.recordId, disposition: 'Snoozed', until: iso },
                    bubbles: true,
                    composed: true
                })
            );
        } catch (e) {
            this.toast('Could not snooze', this.messageOf(e), 'error');
        } finally {
            this.isSaving = false;
        }
    }

    // ---- behaviour ---------------------------------------------------------
    toggleDraft() {
        this.showDraft = !this.showDraft;
        if (!this.showDraft) this.isEditing = false;
    }

    handleDraftChange(event) {
        const which = event.currentTarget.dataset.field;
        if (which === 'subject') this.editedSubject = event.detail.value;
        else this.editedBody = event.detail.value;
    }

    handleCancelEdit() {
        this.editedSubject = undefined;
        this.editedBody = undefined;
        this.isEditing = false;
    }

    async handleSaveDraft() {
        this.isSaving = true;
        try {
            const res = await saveDraft({
                recordId: this.recordId,
                subject: this.workingSubject,
                body: this.workingBody
            });
            // Compliance may have cleaned the text; show what was actually stored.
            this.editedSubject = res.subject;
            this.editedBody = res.body;
            this.wasEdited = true;
            this.isEditing = false;
            await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
            this.toast(
                res.blocked ? 'Saved, but blocked' : 'Draft saved',
                res.reason,
                res.blocked ? 'warning' : 'success'
            );
        } catch (e) {
            this.toast('Could not save the draft', this.messageOf(e), 'error');
        } finally {
            this.isSaving = false;
        }
    }

    async handleSend() {
        this.isSaving = true;
        try {
            const message = await sendDraft({
                recordId: this.recordId,
                subject: this.workingSubject,
                body: this.workingBody,
                wasEdited: this.wasEdited
            });
            await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
            this.justDispositioned = true;
            this.toast('Done', message, 'success');
        } catch (e) {
            this.toast('Not sent', this.messageOf(e), 'error');
        } finally {
            this.isSaving = false;
        }
    }

    messageOf(e) {
        return (
            (e && e.body && (e.body.message || JSON.stringify(e.body))) ||
            (e && e.message) ||
            'Unknown error'
        );
    }

    async handleDisposition(event) {
        const disposition = event.currentTarget.dataset.disposition;
        // These two are not plain dispositions: one sends, one opens the editor.
        if (disposition === 'Approved and sent') {
            this.showDraft = true;
            return this.handleSend();
        }
        if (disposition === 'Edited before send') {
            this.showDraft = true;
            this.isEditing = true;
            return undefined;
        }
        // A snooze needs a date before it means anything, so this opens the
        // chooser rather than committing a week nobody asked for.
        if (disposition === 'Snoozed') {
            this.showSnooze = true;
            return undefined;
        }
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
                body: this.draftBody,
                snoozeUntil: null
            });
            await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
            this.justDispositioned = true;
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
