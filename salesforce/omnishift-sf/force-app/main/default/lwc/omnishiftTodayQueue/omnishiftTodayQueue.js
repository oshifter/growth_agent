import { LightningElement, wire } from 'lwc';
import { getListRecordsByName } from 'lightning/uiListsApi';
import { NavigationMixin } from 'lightning/navigation';

// Reads the Growth Agent - Today list view directly. No Apex: getListRecordsByName is
// a standard wire adapter, so the queue respects sharing and field-level security.
export default class OmnishiftTodayQueue extends NavigationMixin(LightningElement) {
    records;
    error;

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
    wiredList({ data, error }) {
        if (data) {
            this.records = (data.records && data.records.records) || [];
            this.error = undefined;
        } else if (error) {
            this.error = error;
            this.records = undefined;
        }
    }

    get isLoading() {
        return !this.records && !this.error;
    }
    get hasError() {
        return Boolean(this.error);
    }
    get isEmpty() {
        return Boolean(this.records) && this.records.length === 0;
    }
    get hasRows() {
        return Boolean(this.records) && this.records.length > 0;
    }
    get count() {
        return this.records ? this.records.length : 0;
    }
    get headline() {
        const n = this.count;
        return n === 1 ? 'Today you should work 1 person' : `Today you should work ${n} people`;
    }

    get rows() {
        if (!this.records) return [];
        return this.records.map((r) => {
            const f = r.fields;
            const v = (k) =>
                f[k] ? (f[k].displayValue !== null && f[k].displayValue !== undefined ? f[k].displayValue : f[k].value) : '';
            const status = f.Omnishift_Compliance_Status__c
                ? f.Omnishift_Compliance_Status__c.value
                : null;
            const rank = f.Omnishift_Rank__c ? f.Omnishift_Rank__c.value : null;
            return {
                id: r.id,
                rank: rank === null ? '--' : String(rank).padStart(2, '0'),
                name: v('Name'),
                company: v('Company'),
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
        });
    }

    handleOpen(event) {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: event.currentTarget.dataset.id, objectApiName: 'Lead', actionName: 'view' }
        });
    }
}
