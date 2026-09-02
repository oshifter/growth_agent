import { LightningElement, wire } from 'lwc';
import { getListRecordsByName } from 'lightning/uiListsApi';
import { NavigationMixin } from 'lightning/navigation';

const LIST_LABEL = 'Growth Agent - Today';
// A wire that has still not answered after this long deserves to be described.
// Silent waiting is the failure mode this component exists to make visible.
const SLOW_MS = 8000;

// Reads the Growth Agent - Today list view directly. No Apex: getListRecordsByName is
// a standard wire adapter, so the queue respects sharing and field-level security.
export default class OmnishiftTodayQueue extends NavigationMixin(LightningElement) {
    // One explicit state instead of several booleans inferred from each other.
    // A lead once sat in the list view while this component said "nothing due":
    // the response shape had changed and the old code coerced it to an empty
    // array, so a failure and a quiet day rendered identically. Every path below
    // now lands on exactly one named state, and 'empty' is only reachable when
    // the list view genuinely answered with zero rows.
    status = 'loading'; // loading | ready | empty | unreadable | error

    leadRows;
    contactRows;
    leadState;      // undefined until the Lead wire answers
    contactState;   // undefined until the Contact wire answers
    error;
    checkedAt;
    slow = false;
    isRefreshing = false;
    slowTimer;

    connectedCallback() {
        this.slowTimer = setTimeout(() => {
            if (this.status === 'loading') this.slow = true;
        }, SLOW_MS);
    }

    disconnectedCallback() {
        clearTimeout(this.slowTimer);
    }

    @wire(getListRecordsByName, {
        objectApiName: 'Lead',
        listViewApiName: 'Omnishift_Today',
        fields: [
            'Lead.Name',
            'Lead.Company',
            'Lead.Omnishift_Rank__c',
            'Lead.Omnishift_Score__c',
            'Lead.Omnishift_Why_Now__c',
            'Lead.Omnishift_Compliance_Status__c',
            'Lead.Omnishift_Disposition__c'
        ],
        sortBy: ['Lead.Omnishift_Rank__c'],
        pageSize: 25
    })
    wiredLeads(result) {
        const r = this.readList(result);
        this.leadState = r.state;
        this.leadRows = r.rows;
        if (r.state === 'error') this.error = result.error;
        this.settle();
    }

    // Contacts are scored into the same ranking as Leads, so a queue that showed
    // only one of them would silently hide half of what the agent produced.
    // They arrive as a second list view because no report or list type in
    // Salesforce can span both objects.
    @wire(getListRecordsByName, {
        objectApiName: 'Contact',
        listViewApiName: 'Omnishift_Today',
        fields: [
            'Contact.Name',
            'Contact.Account.Name',
            'Contact.Omnishift_Rank__c',
            'Contact.Omnishift_Score__c',
            'Contact.Omnishift_Why_Now__c',
            'Contact.Omnishift_Compliance_Status__c',
            'Contact.Omnishift_Disposition__c'
        ],
        sortBy: ['Contact.Omnishift_Rank__c'],
        pageSize: 25
    })
    wiredContacts(result) {
        const r = this.readList(result);
        this.contactState = r.state;
        this.contactRows = r.rows;
        if (r.state === 'error') this.error = result.error;
        this.settle();
    }

    // One reader for both wires, so neither can drift into treating an
    // unrecognised response as an empty queue.
    readList({ data, error }) {
        if (error) return { state: 'error', rows: undefined };
        if (data === undefined || data === null) return { state: undefined, rows: undefined };
        const rows = Array.isArray(data.records)
            ? data.records
            : Array.isArray(data.records && data.records.records)
            ? data.records.records
            : null;
        if (rows === null) return { state: 'unreadable', rows: undefined };
        return { state: 'ready', rows };
    }

    // The queue is only as trustworthy as its weaker half: if either object
    // failed, say so rather than presenting a partial list as the whole day.
    settle() {
        if (this.leadState === undefined || this.contactState === undefined) return;
        if (this.leadState === 'error' || this.contactState === 'error') {
            this.status = 'error';
        } else if (this.leadState === 'unreadable' || this.contactState === 'unreadable') {
            this.status = 'unreadable';
        } else {
            const total = (this.leadRows || []).length + (this.contactRows || []).length;
            this.error = undefined;
            this.status = total > 0 ? 'ready' : 'empty';
        }
        this.stamp();
    }

    // The timestamp is the proof. An advisor looking at "0 records" can see the
    // queue actually asked, and when.
    stamp() {
        this.slow = false;
        this.checkedAt = new Date().toLocaleTimeString(undefined, {
            hour: '2-digit',
            minute: '2-digit'
        });
    }

    get isLoading() {
        return this.status === 'loading';
    }
    get hasError() {
        return this.status === 'error';
    }
    get isUnreadable() {
        return this.status === 'unreadable';
    }
    get isEmpty() {
        return this.status === 'empty';
    }
    get hasRows() {
        return this.status === 'ready';
    }
    get listLabel() {
        return LIST_LABEL;
    }
    get emptyDetail() {
        return `${LIST_LABEL} returned 0 records at ${this.checkedAt}. The agent runs again tonight.`;
    }

    // Without this an admin has nothing to go on, and the advisor cannot tell a
    // permissions problem from an outage.
    get errorDetail() {
        const e = this.error;
        if (!e) return null;
        const body = e.body;
        let msg;
        if (Array.isArray(body)) msg = body.map((b) => b.message).join('; ');
        else if (body && (body.message || body.errorCode)) msg = body.message || body.errorCode;
        else msg = e.statusText || e.message;
        const code = e.status ? `HTTP ${e.status}` : null;
        return [code, msg].filter(Boolean).join(' - ') || 'The server returned no detail.';
    }

    get count() {
        return this.rows.length;
    }
    get headline() {
        const n = this.count;
        return n === 1 ? 'Today you should work 1 person' : `Today you should work ${n} people`;
    }

    get rows() {
        const map = (r, isLead) => {
            const f = r.fields;
            const v = (k) =>
                f[k]
                    ? f[k].displayValue !== null && f[k].displayValue !== undefined
                        ? f[k].displayValue
                        : f[k].value
                    : '';
            const status = f.Omnishift_Compliance_Status__c
                ? f.Omnishift_Compliance_Status__c.value
                : null;
            const rank = f.Omnishift_Rank__c ? f.Omnishift_Rank__c.value : null;
            // A Contact's firm is on the account it hangs off, not on the record.
            const account =
                f.Account && f.Account.value && f.Account.value.fields
                    ? f.Account.value.fields.Name.value
                    : '';
            return {
                id: r.id,
                objectApiName: isLead ? 'Lead' : 'Contact',
                sortRank: rank === null ? Number.MAX_SAFE_INTEGER : Number(rank),
                rank: rank === null ? '--' : String(rank).padStart(2, '0'),
                name: v('Name'),
                company: isLead ? v('Company') : account,
                kind: isLead ? 'Prospect' : 'Client',
                score: v('Omnishift_Score__c'),
                whyNow: v('Omnishift_Why_Now__c'),
                status: status || 'Not checked',
                done: Boolean(f.Omnishift_Disposition__c && f.Omnishift_Disposition__c.value),
                statusClass:
                    status === 'Blocked'
                        ? 'badge badge_error'
                        : status === 'Flagged'
                        ? 'badge badge_warning'
                        : status === 'Auto-corrected'
                        ? 'badge badge_info'
                        : 'badge badge_success'
            };
        };
        const all = (this.leadRows || [])
            .map((r) => map(r, true))
            .concat((this.contactRows || []).map((r) => map(r, false)));
        // One ranking across both objects, which is how the engine produced it.
        return all.sort((a, b) => a.sortRank - b.sortRank);
    }

    // Checked against the org: neither refreshApex nor RefreshEvent re-provisions
    // getListRecordsByName, so both left this button doing nothing while looking
    // like it worked. A reload does re-read the list view, and the label says so
    // rather than promising a check the component cannot perform.
    handleRetry() {
        this.isRefreshing = true;
        window.location.reload();
    }

    handleOpen(event) {
        // The queue holds both objects now, so the row has to say which one it is.
        // Navigating a Contact id to a Lead page opens nothing.
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: event.currentTarget.dataset.id,
                objectApiName: event.currentTarget.dataset.object,
                actionName: 'view'
            }
        });
    }
}
