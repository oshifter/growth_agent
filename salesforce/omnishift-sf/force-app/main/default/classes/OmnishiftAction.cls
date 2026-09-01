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

    @AuraEnabled
    public static String recordDisposition(Id recordId, String disposition, String reason,
                                           String subject, String body) {
        if (recordId == null || String.isBlank(disposition)) {
            throw new AuraHandledException('A record and a disposition are both required.');
        }

        String sObj = recordId.getSObjectType().getDescribe().getName();
        if (sObj != 'Lead' && sObj != 'Contact') {
            throw new AuraHandledException('The Growth Agent only dispositions Leads and Contacts.');
        }

        SObject rec = Schema.getGlobalDescribe().get(sObj).newSObject(recordId);
        rec.put('Omnishift_Disposition__c', disposition);
        if (String.isNotBlank(reason)) rec.put('Omnishift_Disposition_Reason__c', reason);

        // The next action date is what the Today queue filters on, so it is the
        // field that decides whether this record comes back tomorrow.
        if (disposition == 'Snoozed') {
            rec.put('Omnishift_Next_Action_Date__c', Date.today().addDays(7));
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
                throw new AuraHandledException('You do not have permission to log activities.');
            }
            insert log;
        }

        if (!canUpdate(sObj)) {
            throw new AuraHandledException('You do not have permission to update this record.');
        }
        update rec;

        return disposition == 'Snoozed'
            ? 'Snoozed until ' + Date.today().addDays(7).format()
            : 'Logged as ' + disposition.toLowerCase();
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
}
