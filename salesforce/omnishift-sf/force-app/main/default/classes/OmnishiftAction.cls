/**
 * Closes the loop on a recommendation.
 *
 * The panel used to write the disposition and stop there, which meant an
 * approved draft left no trace on the record and a snoozed lead came back the
 * next morning. Everything a disposition implies now happens in one
 * transaction: the audit activity, the next action date, and the queue exit.
 */
public with sharing class OmnishiftAction {

    public class ActionException extends Exception {}

        private static String recordDispositionImpl(Id recordId, String disposition, String reason,
                                           String subject, String body, Date snoozeUntil) {
        if (recordId == null || String.isBlank(disposition)) {
            throw new ActionException('A record and a disposition are both required.');
        }

        String sObj = recordId.getSObjectType().getDescribe().getName();
        if (sObj != 'Lead' && sObj != 'Contact') {
            throw new ActionException('The Growth Agent only dispositions Leads and Contacts.');
        }

        SObject rec = Schema.getGlobalDescribe().get(sObj).newSObject(recordId);
        rec.put('Omnishift_Disposition__c', disposition);
        // Nothing else records when the advisor acted. LastModifiedDate cannot
        // stand in for it, because the nightly run rewrites that on every record.
        rec.put('Omnishift_Dispositioned_On__c', Datetime.now());
        if (String.isNotBlank(reason)) rec.put('Omnishift_Disposition_Reason__c', reason);

        // The next action date is what the Today queue filters on, so it is the
        // field that decides whether this record comes back tomorrow.
        if (disposition == 'Snoozed') {
            // The advisor knows when to come back better than a constant does. A
            // week is only the fallback when they express no preference.
            Date returnOn = (snoozeUntil != null && snoozeUntil > Date.today())
                ? snoozeUntil
                : Date.today().addDays(7);
            rec.put('Omnishift_Next_Action_Date__c', returnOn);
        } else if (disposition == 'Wrong person') {
            rec.put('Omnishift_Next_Action_Date__c', null);
        } else {
            rec.put('Omnishift_Next_Action_Date__c', null);
        }

        List<Task> log = new List<Task>();
        if (disposition == 'Approved and sent' || disposition == 'Edited before send') {
            log.add(buildTask(recordId, sObj, 'Email',
                String.isBlank(subject) ? 'Growth Agent outreach' : subject,
                buildBody(disposition, body)));
        } else if (disposition == 'Call logged') {
            log.add(buildTask(recordId, sObj, 'Call', 'Growth Agent call',
                String.isBlank(reason) ? 'Call logged from the Growth Agent panel.' : reason));
        }

        if (!log.isEmpty()) {
            if (!Schema.sObjectType.Task.isCreateable()) {
                throw new ActionException('You do not have permission to log activities.');
            }
            insert log;
        }

        if (!canUpdate(sObj)) {
            throw new ActionException('You do not have permission to update this record.');
        }
        update rec;

        if (disposition != 'Snoozed') return 'Logged as ' + disposition.toLowerCase();
        Date shown = (snoozeUntil != null && snoozeUntil > Date.today())
            ? snoozeUntil : Date.today().addDays(7);
        return 'Snoozed until ' + shown.format();
    }

    private static Task buildTask(Id recordId, String sObj, String type, String subject, String body) {
        Task t = new Task(
            Subject      = subject,
            Description  = body,
            Type         = type,
            Status       = 'Completed',
            Priority     = 'Normal',
            ActivityDate = Date.today(),
            OwnerId      = UserInfo.getUserId()
        );
        // WhoId takes both Lead and Contact ids. WhatId does not accept a Lead,
        // which is the same constraint that rules EmailMessage out here.
        t.WhoId = recordId;
        return t;
    }

    private static String buildBody(String disposition, String body) {
        String prefix = disposition == 'Edited before send'
            ? 'Sent from the Growth Agent panel, edited by the advisor before sending.\n\n'
            : 'Sent from the Growth Agent panel, approved as drafted.\n\n';
        return prefix + (String.isBlank(body) ? '' : body);
    }

    private static Boolean canUpdate(String sObj) {
        Map<String, Schema.SObjectField> f = Schema.getGlobalDescribe().get(sObj)
            .getDescribe().fields.getMap();
        return f.get('Omnishift_Disposition__c').getDescribe().isUpdateable()
            && f.get('Omnishift_Next_Action_Date__c').getDescribe().isUpdateable();
    }

    /**
     * Persists an advisor's edit to the draft.
     *
     * Compliance re-runs here rather than only on the nightly text: the whole
     * point of an editable draft is that a human can put something in it that
     * the generated template never would.
     */
        private static Map<String, Object> saveDraftImpl(Id recordId, String subject, String body) {
        assertSupported(recordId);
        if (String.isBlank(subject) || String.isBlank(body)) {
            throw new ActionException('A draft needs both a subject and a body.');
        }

        OmnishiftEngine.Outcome c = OmnishiftEngine.complianceCheck(subject, body);
        // Auto-correct hands back cleaned text; take it so what is stored is what
        // was checked.
        String finalSubject = (c.draftSubject != null) ? c.draftSubject : subject;
        String finalBody    = (c.draftBody    != null) ? c.draftBody    : body;

        String sObj = recordId.getSObjectType().getDescribe().getName();
        SObject rec = Schema.getGlobalDescribe().get(sObj).newSObject(recordId);
        rec.put('Omnishift_Draft_Subject__c', finalSubject);
        rec.put('Omnishift_Draft_Body__c', finalBody);
        rec.put('Omnishift_Compliance_Status__c', c.complianceStatus);
        rec.put('Omnishift_Compliance_Reason__c', c.complianceReason);
        // Tells the nightly run to leave this draft alone.
        rec.put('Omnishift_Draft_Edited__c', true);
        update rec;

        return new Map<String, Object>{
            'subject'    => finalSubject,
            'body'       => finalBody,
            'status'     => c.complianceStatus,
            'reason'     => c.complianceReason,
            'blocked'    => c.complianceStatus == 'Blocked'
        };
    }

    /**
     * Sends the draft, or records it without sending when live email is off.
     *
     * Omnishift_Config__mdt.Send_Live_Email__c is false everywhere until the firm
     * has settled archiving and deliverability, so the default behaviour is to
     * produce the audit trail without putting anything in a prospect's inbox.
     */
        private static String sendDraftImpl(Id recordId, String subject, String body, Boolean wasEdited) {
        assertSupported(recordId);

        // Never send text that has not just been checked. An advisor can edit in a
        // violation between the nightly run and the click.
        OmnishiftEngine.Outcome c = OmnishiftEngine.complianceCheck(subject, body);
        if (c.complianceStatus == 'Blocked') {
            throw new ActionException('Cannot send. ' + c.complianceReason);
        }
        String outSubject = (c.draftSubject != null) ? c.draftSubject : subject;
        String outBody    = (c.draftBody    != null) ? c.draftBody    : body;

        Boolean live = liveEmailEnabled();
        String disposition = (wasEdited == true) ? 'Edited before send' : 'Approved and sent';

        if (live) {
            Messaging.SingleEmailMessage m = new Messaging.SingleEmailMessage();
            m.setTargetObjectId(recordId);     // accepts Lead and Contact
            m.setSaveAsActivity(true);         // Salesforce writes the activity itself
            m.setSubject(outSubject);
            m.setPlainTextBody(outBody);
            m.setTreatTargetObjectAsRecipient(true);
            List<Messaging.SendEmailResult> res =
                Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ m }, false);
            if (!res.isEmpty() && !res[0].isSuccess()) {
                String why = res[0].getErrors().isEmpty()
                    ? 'unknown error' : res[0].getErrors()[0].getMessage();
                throw new ActionException('Salesforce refused the send: ' + why);
            }
            recordDispositionImpl(recordId, disposition, null, null, null, null);
            return 'Sent to the prospect and logged.';
        }

        // Not live: recordDisposition writes the Task that is the audit trail.
        recordDispositionImpl(recordId, disposition, null, outSubject, outBody, null);
        return 'Recorded as ' + disposition.toLowerCase()
             + '. Live email is off in this org, so nothing left Salesforce.';
    }

    @AuraEnabled(cacheable=true)
    public static Boolean liveEmailEnabled() {
        Omnishift_Config__mdt cfg = Omnishift_Config__mdt.getInstance('Default');
        return cfg != null && cfg.Send_Live_Email__c == true;
    }

    private static void assertSupported(Id recordId) {
        if (recordId == null) throw new ActionException('A record is required.');
        String sObj = recordId.getSObjectType().getDescribe().getName();
        if (sObj != 'Lead' && sObj != 'Contact') {
            throw new ActionException('The Growth Agent only works Leads and Contacts.');
        }
    }

    // ---- entry points ------------------------------------------------------
    // AuraHandledException can only be thrown from an Aura or Visualforce
    // context, which made the rules above impossible to exercise from a test or
    // from anonymous Apex. The logic raises ActionException; only these three
    // wrappers translate it into something the UI can display.

    @AuraEnabled
    public static String recordDisposition(Id recordId, String disposition, String reason,
                                           String subject, String body, Date snoozeUntil) {
        try {
            return recordDispositionImpl(recordId, disposition, reason, subject, body, snoozeUntil);
        } catch (ActionException e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static Map<String, Object> saveDraft(Id recordId, String subject, String body) {
        try {
            return saveDraftImpl(recordId, subject, body);
        } catch (ActionException e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static String sendDraft(Id recordId, String subject, String body, Boolean wasEdited) {
        try {
            return sendDraftImpl(recordId, subject, body, wasEdited);
        } catch (ActionException e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @TestVisible
    private static String sendDraftForTest(Id recordId, String subject, String body, Boolean edited) {
        return sendDraftImpl(recordId, subject, body, edited);
    }
    @TestVisible
    private static Map<String, Object> saveDraftForTest(Id recordId, String subject, String body) {
        return saveDraftImpl(recordId, subject, body);
    }
    @TestVisible
    private static String dispositionForTest(Id recordId, String d, String r, String s2, String b) {
        return recordDispositionImpl(recordId, d, r, s2, b, null);
    }
    @TestVisible
    private static String snoozeForTest(Id recordId, Date until) {
        return recordDispositionImpl(recordId, 'Snoozed', null, null, null, until);
    }

    /**
     * Whether this org has Person Accounts turned on.
     *
     * Contact.IsPersonAccount only exists when it does. The panel was asking for
     * it on every Contact, so getRecord failed on all of them and reported a
     * field-level-security problem that was not the cause.
     */
    @AuraEnabled(cacheable=true)
    public static Boolean personAccountsEnabled() {
        return OmnishiftEngine.personAccountsEnabled();
    }
}
