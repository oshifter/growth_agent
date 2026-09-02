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
        String msg = OmnishiftAction.dispositionForTest(l.Id, 'Approved and sent', null,
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
        OmnishiftAction.dispositionForTest(l.Id, 'Edited before send', null, 'Subject', 'Body');
        Task t = [SELECT Description FROM Task WHERE WhoId = :l.Id];
        System.assert(t.Description.contains('edited by the advisor'),
                      'Compliance needs to see that a human changed the draft.');
    }

    @isTest static void snoozePushesTheDateSevenDaysOut() {
        Lead l = newLead();
        Test.startTest();
        String msg = OmnishiftAction.dispositionForTest(l.Id, 'Snoozed', 'Not now', null, null);
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
        OmnishiftAction.dispositionForTest(l.Id, 'Call logged', 'Left a voicemail', null, null);
        Task t = [SELECT Type, Description FROM Task WHERE WhoId = :l.Id];
        System.assertEquals('Call', t.Type);
        System.assertEquals('Left a voicemail', t.Description);
    }

    @isTest static void wrongPersonDropsOutWithoutLoggingOutreach() {
        Lead l = newLead();
        OmnishiftAction.dispositionForTest(l.Id, 'Wrong person', 'Different Ada', null, null);
        Lead after = [SELECT Omnishift_Next_Action_Date__c FROM Lead WHERE Id = :l.Id];
        System.assertEquals(null, after.Omnishift_Next_Action_Date__c);
        System.assertEquals(0, [SELECT COUNT() FROM Task WHERE WhoId = :l.Id]);
    }

    @isTest static void contactsAreDispositionedToo() {
        Contact c = new Contact(FirstName='Grace', LastName='Hopper', Email='grace@example.com');
        insert c;
        OmnishiftAction.dispositionForTest(c.Id, 'Approved and sent', null, 'Hello', 'Body');
        System.assertEquals(1, [SELECT COUNT() FROM Task WHERE WhoId = :c.Id]);
    }

    @isTest static void unsupportedObjectIsRejected() {
        Account a = new Account(Name='Acme');
        insert a;
        try {
            OmnishiftAction.dispositionForTest(a.Id, 'Approved and sent', null, 's', 'b');
            System.assert(false, 'An Account should not be dispositionable.');
        } catch (Exception e) {
            System.assert(true);
        }
    }

    @isTest static void blankDispositionIsRejected() {
        Lead l = newLead();
        try {
            OmnishiftAction.dispositionForTest(l.Id, '', null, null, null);
            System.assert(false, 'A blank disposition should not be accepted.');
        } catch (Exception e) {
            System.assert(true);
        }
    }

    @isTest static void savingADraftReRunsCompliance() {
        Lead l = newLead();
        Test.startTest();
        Map<String, Object> r = OmnishiftAction.saveDraftForTest(
            l.Id, 'A quick note', 'Ada - we are the best firm around. Happy to talk.');
        Test.stopTest();
        System.assertEquals('Auto-corrected', r.get('status'),
            'An advisor editing in a superlative must be caught on save.');
        System.assert(!((String) r.get('body')).toLowerCase().contains('best'),
            'The stored body must be the corrected one: ' + r.get('body'));
        Lead after = [SELECT Omnishift_Draft_Body__c FROM Lead WHERE Id = :l.Id];
        System.assertEquals(r.get('body'), after.Omnishift_Draft_Body__c,
            'What is shown back must be what was stored.');
    }

    @isTest static void sendRefusesAViolationTheAdvisorTypedIn() {
        Lead l = newLead();
        Boolean refused = false;
        Test.startTest();
        try {
            OmnishiftAction.sendDraftForTest(l.Id, 'A note', 'We deliver guaranteed returns.', true);
        } catch (OmnishiftAction.ActionException e) {
            refused = true;
            System.assert(e.getMessage().contains('guarantee'), e.getMessage());
        }
        Test.stopTest();
        System.assert(refused, 'A blocked draft must never send, however it got there.');
        System.assertEquals(0, [SELECT COUNT() FROM Task WHERE WhoId = :l.Id],
            'A refused send must not leave an activity claiming it happened.');
    }

    @isTest static void sendWithLiveEmailOffRecordsWithoutDelivering() {
        Lead l = newLead();
        Test.startTest();
        String msg = OmnishiftAction.sendDraftForTest(l.Id, 'A note', 'Ada - happy to talk.', false);
        Test.stopTest();
        System.assert(msg.contains('nothing left Salesforce'), msg);
        Task t = [SELECT Subject, Status FROM Task WHERE WhoId = :l.Id];
        System.assertEquals('A note', t.Subject);
        System.assertEquals('Completed', t.Status);
    }

    @isTest static void anEditedSendIsRecordedAsEdited() {
        Lead l = newLead();
        OmnishiftAction.sendDraftForTest(l.Id, 'A note', 'Ada - happy to talk.', true);
        Lead after = [SELECT Omnishift_Disposition__c FROM Lead WHERE Id = :l.Id];
        System.assertEquals('Edited before send', after.Omnishift_Disposition__c);
    }

    @isTest static void liveEmailIsOffByDefault() {
        System.assertEquals(false, OmnishiftAction.liveEmailEnabled(),
            'No org should deliver email until the firm has switched it on deliberately.');
    }

    @isTest static void snoozeHonoursTheDateTheAdvisorChose() {
        Lead l = newLead();
        Date want = Date.today().addDays(31);
        Test.startTest();
        String msg = OmnishiftAction.snoozeForTest(l.Id, want);
        Test.stopTest();
        Lead after = [SELECT Omnishift_Next_Action_Date__c FROM Lead WHERE Id = :l.Id];
        System.assertEquals(want, after.Omnishift_Next_Action_Date__c,
            'A month means a month, not the seven-day default.');
        System.assert(msg.contains(want.format()), msg);
    }

    @isTest static void snoozeFallsBackToAWeekWhenNoDateIsGiven() {
        Lead l = newLead();
        OmnishiftAction.snoozeForTest(l.Id, null);
        Lead after = [SELECT Omnishift_Next_Action_Date__c FROM Lead WHERE Id = :l.Id];
        System.assertEquals(Date.today().addDays(7), after.Omnishift_Next_Action_Date__c);
    }

    @isTest static void aSnoozeDateInThePastIsIgnored() {
        Lead l = newLead();
        OmnishiftAction.snoozeForTest(l.Id, Date.today().addDays(-5));
        Lead after = [SELECT Omnishift_Next_Action_Date__c FROM Lead WHERE Id = :l.Id];
        System.assertEquals(Date.today().addDays(7), after.Omnishift_Next_Action_Date__c,
            'A past date would put the record straight back on today list.');
    }

    @isTest static void personAccountDetectionMatchesTheOrg() {
        Boolean expected = Schema.SObjectType.Contact.fields.getMap().containsKey('ispersonaccount');
        System.assertEquals(expected, OmnishiftAction.personAccountsEnabled(),
            'The panel decides whether to request IsPersonAccount from this.');
    }
}
