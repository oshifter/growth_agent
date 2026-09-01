@isTest
private class OmnishiftActionTest {

    private static Lead newLead() {
        Lead l = new Lead(FirstName='Ada', LastName='Byron', Company='Analytical Engines',
                          Email='ada@example.com', Status='Open - Not Contacted',
                          Omnishift_Next_Action_Date__c = Date.today());
        insert l;
        return l;
    }

    @isTest static void approvedSendLogsAnEmailTaskAndLeavesTheQueue() {
        Lead l = newLead();
        Test.startTest();
        String msg = OmnishiftAction.recordDisposition(l.Id, 'Approved and sent', null,
                                                       'A note after your introduction', 'Hello Ada,');
        Test.stopTest();

        Task t = [SELECT Subject, Type, Status, WhoId, Description FROM Task WHERE WhoId = :l.Id];
        System.assertEquals('Email', t.Type, 'An approved send should log an email activity.');
        System.assertEquals('Completed', t.Status);
        System.assertEquals('A note after your introduction', t.Subject);
        System.assert(t.Description.contains('approved as drafted'), 'The log should say it was unedited.');

        Lead after = [SELECT Omnishift_Disposition__c, Omnishift_Next_Action_Date__c FROM Lead WHERE Id = :l.Id];
        System.assertEquals('Approved and sent', after.Omnishift_Disposition__c);
        System.assertEquals(null, after.Omnishift_Next_Action_Date__c, 'A handled lead must leave the queue.');
        System.assert(msg.contains('approved and sent'));
    }

    @isTest static void editedSendIsDistinguishableInTheAuditLog() {
        Lead l = newLead();
        OmnishiftAction.recordDisposition(l.Id, 'Edited before send', null, 'Subject', 'Body');
        Task t = [SELECT Description FROM Task WHERE WhoId = :l.Id];
        System.assert(t.Description.contains('edited by the advisor'),
                      'Compliance needs to see that a human changed the draft.');
    }

    @isTest static void snoozePushesTheDateSevenDaysOut() {
        Lead l = newLead();
        Test.startTest();
        String msg = OmnishiftAction.recordDisposition(l.Id, 'Snoozed', 'Not now', null, null);
        Test.stopTest();
        Lead after = [SELECT Omnishift_Next_Action_Date__c, Omnishift_Disposition_Reason__c
                      FROM Lead WHERE Id = :l.Id];
        System.assertEquals(Date.today().addDays(7), after.Omnishift_Next_Action_Date__c);
        System.assertEquals('Not now', after.Omnishift_Disposition_Reason__c);
        System.assertEquals(0, [SELECT COUNT() FROM Task WHERE WhoId = :l.Id],
                            'Snoozing is not an outreach and must not log one.');
        System.assert(msg.startsWith('Snoozed until'));
    }

    @isTest static void callLoggedCreatesACallTask() {
        Lead l = newLead();
        OmnishiftAction.recordDisposition(l.Id, 'Call logged', 'Left a voicemail', null, null);
        Task t = [SELECT Type, Description FROM Task WHERE WhoId = :l.Id];
        System.assertEquals('Call', t.Type);
        System.assertEquals('Left a voicemail', t.Description);
    }

    @isTest static void wrongPersonDropsOutWithoutLoggingOutreach() {
        Lead l = newLead();
        OmnishiftAction.recordDisposition(l.Id, 'Wrong person', 'Different Ada', null, null);
        Lead after = [SELECT Omnishift_Next_Action_Date__c FROM Lead WHERE Id = :l.Id];
        System.assertEquals(null, after.Omnishift_Next_Action_Date__c);
        System.assertEquals(0, [SELECT COUNT() FROM Task WHERE WhoId = :l.Id]);
    }

    @isTest static void contactsAreDispositionedToo() {
        Contact c = new Contact(FirstName='Grace', LastName='Hopper', Email='grace@example.com');
        insert c;
        OmnishiftAction.recordDisposition(c.Id, 'Approved and sent', null, 'Hello', 'Body');
        System.assertEquals(1, [SELECT COUNT() FROM Task WHERE WhoId = :c.Id]);
    }

    @isTest static void unsupportedObjectIsRejected() {
        Account a = new Account(Name='Acme');
        insert a;
        try {
            OmnishiftAction.recordDisposition(a.Id, 'Approved and sent', null, 's', 'b');
            System.assert(false, 'An Account should not be dispositionable.');
        } catch (Exception e) {
            System.assert(true);
        }
    }

    @isTest static void blankDispositionIsRejected() {
        Lead l = newLead();
        try {
            OmnishiftAction.recordDisposition(l.Id, '', null, null, null);
            System.assert(false, 'A blank disposition should not be accepted.');
        } catch (Exception e) {
            System.assert(true);
        }
    }
}
