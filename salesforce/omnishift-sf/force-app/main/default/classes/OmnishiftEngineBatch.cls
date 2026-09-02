/**
 * The nightly run. Reads leads and clients, suppresses, scores, ranks, routes,
 * drafts and compliance-checks, then writes the results back to the record.
 *
 * Batched at 200 so each chunk stays well inside governor limits, and the ranking
 * is assigned in a finish() pass so it is global rather than per-chunk.
 */
public with sharing class OmnishiftEngineBatch implements Database.Batchable<sObject>, Database.Stateful {

    private Set<String> ownedEmails = new Set<String>();
    private Set<String> ownedNames  = new Set<String>();
    private List<User>  pool        = new List<User>();
    private Map<Id, Integer> load   = new Map<Id, Integer>();
    public  Integer scored = 0;
    public  Integer suppressed = 0;
    private String runId;

    // Both caps are the population this run is willing to look at in one night.
    private static final Integer SCOPE_CAP = 20000;
    private static final Integer RANK_CAP  = 5000;

    public OmnishiftEngineBatch() {
        this.runId = 'run-' + Datetime.now().format('yyyyMMdd-HHmmss');
        // Cross-reference set: who we already own as Contacts.
        for (Contact c : [SELECT Email, FirstName, LastName FROM Contact LIMIT 20000]) {
            if (c.Email != null) ownedEmails.add(c.Email.toLowerCase());
            String nm = ((c.FirstName == null ? '' : c.FirstName) + ' ' + c.LastName).trim().toLowerCase();
            if (nm != '') ownedNames.add(nm);
        }
        // The eligible owners are whoever holds the Growth Agent permission set,
        // not every Standard user. UserType = 'Standard' also matches the
        // platform accounts - Security User, Integration User - and routing a
        // prospect to one of those is worse than not routing it at all.
        Set<Id> eligible = new Set<Id>();
        for (PermissionSetAssignment psa : [
                SELECT AssigneeId FROM PermissionSetAssignment
                WHERE PermissionSet.Name = 'Omnishift_Growth_Agent_User'
                LIMIT 1000]) {
            eligible.add(psa.AssigneeId);
        }
        if (eligible.isEmpty()) eligible.add(UserInfo.getUserId());

        pool = [SELECT Id, Name, State FROM User
                WHERE IsActive = true AND Id IN :eligible
                ORDER BY Name LIMIT 200];
    }

    /**
     * A QueryLocator walks one object, and both ways of covering a second one
     * cost something. Chaining a Contact run out of finish() keeps the locator,
     * but it splits the run across two jobs, so the global rank would have to be
     * assigned by whichever finished last - and a batch cannot be started from a
     * batch inside a test, so the cross-object ranking could never be exercised.
     * Handing back both populations as one iterable keeps a single scored set and
     * a single finish(), at the price of the 50,000-row ceiling an iterable
     * carries. SCOPE_CAP keeps the run under it on purpose rather than by luck.
     */
    public Iterable<sObject> start(Database.BatchableContext bc) {
        List<sObject> scope = new List<sObject>();
        scope.addAll((List<sObject>) [
            SELECT Id, FirstName, LastName, Company, Email, State, Status, LeadSource,
                   AnnualRevenue, NumberOfEmployees, Rating, Industry, DoNotCall,
                   HasOptedOutOfEmail, IsConverted, CreatedDate, LastActivityDate,
                   Omnishift_Draft_Edited__c
            FROM Lead
            WHERE IsConverted = false
            LIMIT :SCOPE_CAP
        ]);
        scope.addAll((List<sObject>) contactScope());
        return scope;
    }

    /**
     * Dynamic only because of IsPersonAccount, which does not exist as a field
     * until person accounts are enabled and so cannot be named in static SOQL
     * that has to compile in an org where they are off. Person accounts are
     * excluded from scope rather than suppressed: the platform rejects DML
     * against a person account's contact row, so a suppression write would fail
     * just as a scoring write would. Their Omnishift fields would have to live on
     * the Account for that half to work at all.
     */
    private List<Contact> contactScope() {
        String soql =
            'SELECT Id, FirstName, LastName, Email, MailingState, Title, LeadSource, '
          + 'AccountId, Account.AnnualRevenue, DoNotCall, HasOptedOutOfEmail, '
          + 'CreatedDate, LastActivityDate, Omnishift_Draft_Edited__c FROM Contact';
        if (OmnishiftEngine.personAccountsEnabled()) soql += ' WHERE IsPersonAccount = false';
        soql += ' LIMIT ' + SCOPE_CAP;
        return (List<Contact>) Database.query(soql);
    }

    public void execute(Database.BatchableContext bc, List<sObject> scope) {
        // Salesforce rejects DML over a list holding more than one object type,
        // so the two go into their own lists all the way to the update.
        List<Lead> leadUpdates = new List<Lead>();
        List<Contact> contactUpdates = new List<Contact>();

        for (sObject rec : scope) {
            Boolean isLead = (rec instanceof Lead);
            OmnishiftEngine.Prospect p = isLead
                ? OmnishiftEngine.fromLead((Lead) rec)
                : OmnishiftEngine.fromContact((Contact) rec);

            // Every Omnishift field carries the same API name on both objects, so
            // the writes below are identical once the shell is the right type.
            sObject u = isLead ? (sObject) new Lead(Id = rec.Id) : (sObject) new Contact(Id = rec.Id);
            u.put('Omnishift_Run_Id__c', runId);
            u.put('Omnishift_Scored_On__c', Datetime.now());

            OmnishiftEngine.Outcome sup = OmnishiftEngine.suppressionCheck(p, ownedEmails, ownedNames);
            if (sup.suppressed) {
                suppressed++;
                u.put('Omnishift_Score__c', 0);
                u.put('Omnishift_Rank__c', null);
                u.put('Omnishift_Why_Now__c', 'Suppressed: ' + sup.suppressReason);
                u.put('Omnishift_Next_Action_Date__c', null);
                u.put('Omnishift_Compliance_Status__c', null);
                u.put('Omnishift_Draft_Subject__c', null);
                u.put('Omnishift_Draft_Body__c', null);
                u.put('Omnishift_Recommended_Owner__c', null);
                if (isLead) leadUpdates.add((Lead) u); else contactUpdates.add((Contact) u);
                continue;
            }

            OmnishiftEngine.Outcome s = OmnishiftEngine.score(p);
            OmnishiftEngine.Outcome d = OmnishiftEngine.draft(p, s.topDriver);
            OmnishiftEngine.Outcome c = OmnishiftEngine.complianceCheck(d.draftSubject, d.draftBody);

            u.put('Omnishift_Score__c', s.score);
            u.put('Omnishift_Why_Now__c', s.whyNow);
            // An advisor's edit outranks the template. Regenerating over the top of
            // it every night silently threw away their work, and made any
            // compliance verdict on an edited draft unstable from one run to the
            // next.
            Boolean edited = rec.get('Omnishift_Draft_Edited__c') == true;
            if (!edited) {
                u.put('Omnishift_Draft_Subject__c', d.draftSubject);
                u.put('Omnishift_Draft_Body__c', d.draftBody);
                u.put('Omnishift_Compliance_Status__c', c.complianceStatus);
            }
            u.put('Omnishift_Compliance_Reason__c', c.complianceReason);
            // The compliance reason used to be written into the disposition reason,
            // so every nightly run overwrote whatever the advisor had recorded.
            if (!edited && c.draftSubject != null) u.put('Omnishift_Draft_Subject__c', c.draftSubject);
            if (!edited && c.draftBody != null) u.put('Omnishift_Draft_Body__c', c.draftBody);
            u.put('Omnishift_Recommended_Owner__c', OmnishiftEngine.route(p, pool, load));
            // Anything scoring 50+ is worth a touch today; the rest get a nurture date.
            u.put('Omnishift_Next_Action_Date__c', (s.score >= 50) ? Date.today() : Date.today().addDays(30));
            scored++;
            if (isLead) leadUpdates.add((Lead) u); else contactUpdates.add((Contact) u);
        }
        if (!leadUpdates.isEmpty()) Database.update(leadUpdates, false);
        if (!contactUpdates.isEmpty()) Database.update(contactUpdates, false);
    }

    public void finish(Database.BatchableContext bc) {
        // Global rank, assigned once the whole population is scored. It has to be
        // one merged ordering across both objects: two records sharing rank 1 is
        // the fastest way to make an advisor stop trusting the queue.
        List<Ranked> all = new List<Ranked>();
        for (Lead l : [
                SELECT Id, Omnishift_Score__c, CreatedDate FROM Lead
                WHERE Omnishift_Score__c > 0 AND IsConverted = false
                ORDER BY Omnishift_Score__c DESC, CreatedDate ASC
                LIMIT :RANK_CAP]) {
            all.add(new Ranked(l.Id, l.Omnishift_Score__c, l.CreatedDate));
        }
        for (Contact c : [
                SELECT Id, Omnishift_Score__c, CreatedDate FROM Contact
                WHERE Omnishift_Score__c > 0
                ORDER BY Omnishift_Score__c DESC, CreatedDate ASC
                LIMIT :RANK_CAP]) {
            all.add(new Ranked(c.Id, c.Omnishift_Score__c, c.CreatedDate));
        }
        all.sort();

        List<Lead> leadRanks = new List<Lead>();
        List<Contact> contactRanks = new List<Contact>();
        Integer i = 1;
        for (Ranked r : all) {
            if (i > RANK_CAP) break;
            if (r.recordId.getSObjectType() == Lead.SObjectType) {
                leadRanks.add(new Lead(Id = r.recordId, Omnishift_Rank__c = i));
            } else {
                contactRanks.add(new Contact(Id = r.recordId, Omnishift_Rank__c = i));
            }
            i++;
        }
        if (!leadRanks.isEmpty()) Database.update(leadRanks, false);
        if (!contactRanks.isEmpty()) Database.update(contactRanks, false);
    }

    private class Ranked implements Comparable {
        private Id recordId;
        private Decimal score;
        private Datetime created;
        private Ranked(Id recordId, Decimal score, Datetime created) {
            this.recordId = recordId; this.score = score; this.created = created;
        }
        public Integer compareTo(Object other) {
            Ranked r = (Ranked) other;
            if (score != r.score) return (score > r.score) ? -1 : 1;
            if (created != r.created) return (created < r.created) ? -1 : 1;
            // Records loaded in the same second are common in a seeded org. With
            // no final tie-break their order is whatever the two queries happened
            // to return, and the same Lead and Contact would swap rank nightly
            // for no reason an advisor could explain.
            return String.valueOf(recordId).compareTo(String.valueOf(r.recordId));
        }
    }

    /** Kick the run off from a button or the developer console. */
    @AuraEnabled
    public static String runNow() {
        Id jobId = Database.executeBatch(new OmnishiftEngineBatch(), 200);
        return jobId;
    }
}
