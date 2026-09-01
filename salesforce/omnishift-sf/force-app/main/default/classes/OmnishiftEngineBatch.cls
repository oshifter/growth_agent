/**
 * The nightly run. Reads leads, suppresses, scores, ranks, routes, drafts and
 * compliance-checks, then writes the results back to the Lead.
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

    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([
            SELECT Id, FirstName, LastName, Company, Email, State, Status, LeadSource,
                   AnnualRevenue, NumberOfEmployees, Rating, Industry, DoNotCall,
                   HasOptedOutOfEmail, IsConverted, CreatedDate, LastActivityDate
            FROM Lead
            WHERE IsConverted = false
        ]);
    }

    public void execute(Database.BatchableContext bc, List<Lead> scope) {
        List<Lead> updates = new List<Lead>();
        for (Lead l : scope) {
            Lead u = new Lead(Id = l.Id);
            u.Omnishift_Run_Id__c = runId;
            u.Omnishift_Scored_On__c = Datetime.now();

            OmnishiftEngine.Outcome sup = OmnishiftEngine.suppressionCheck(l, ownedEmails, ownedNames);
            if (sup.suppressed) {
                suppressed++;
                u.Omnishift_Score__c = 0;
                u.Omnishift_Rank__c = null;
                u.Omnishift_Why_Now__c = 'Suppressed: ' + sup.suppressReason;
                u.Omnishift_Next_Action_Date__c = null;
                u.Omnishift_Compliance_Status__c = null;
                u.Omnishift_Draft_Subject__c = null;
                u.Omnishift_Draft_Body__c = null;
                u.Omnishift_Recommended_Owner__c = null;
                updates.add(u);
                continue;
            }

            OmnishiftEngine.Outcome s = OmnishiftEngine.score(l);
            OmnishiftEngine.Outcome d = OmnishiftEngine.draft(l, s.topDriver);
            OmnishiftEngine.Outcome c = OmnishiftEngine.complianceCheck(d.draftSubject, d.draftBody);

            u.Omnishift_Score__c = s.score;
            u.Omnishift_Why_Now__c = s.whyNow;
            u.Omnishift_Draft_Subject__c = d.draftSubject;
            u.Omnishift_Draft_Body__c = d.draftBody;
            u.Omnishift_Compliance_Status__c = c.complianceStatus;
            u.Omnishift_Disposition_Reason__c = c.complianceReason;
            u.Omnishift_Recommended_Owner__c = OmnishiftEngine.route(l, pool, load);
            // Anything scoring 50+ is worth a touch today; the rest get a nurture date.
            u.Omnishift_Next_Action_Date__c = (s.score >= 50) ? Date.today() : Date.today().addDays(30);
            scored++;
            updates.add(u);
        }
        if (!updates.isEmpty()) Database.update(updates, false);
    }

    public void finish(Database.BatchableContext bc) {
        // Global rank, assigned once the whole population is scored.
        List<Lead> ranked = [
            SELECT Id, Omnishift_Score__c FROM Lead
            WHERE Omnishift_Score__c > 0 AND IsConverted = false
            ORDER BY Omnishift_Score__c DESC, CreatedDate ASC
            LIMIT 5000
        ];
        List<Lead> toRank = new List<Lead>();
        Integer i = 1;
        for (Lead l : ranked) {
            toRank.add(new Lead(Id = l.Id, Omnishift_Rank__c = i));
            i++;
        }
        if (!toRank.isEmpty()) Database.update(toRank, false);
    }

    /** Kick the run off from a button or the developer console. */
    @AuraEnabled
    public static String runNow() {
        Id jobId = Database.executeBatch(new OmnishiftEngineBatch(), 200);
        return jobId;
    }
}
