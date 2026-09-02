@isTest
private class OmnishiftEngineTest {

    @isTest static void referralScoresHigherThanColdList() {
        Lead ref  = new Lead(LastName='A', Company='A Co', LeadSource='Referral', AnnualRevenue=5000000);
        Lead cold = new Lead(LastName='B', Company='B Co', LeadSource='Purchased List', AnnualRevenue=5000000);
        insert new List<Lead>{ ref, cold };
        ref  = [SELECT Id, FirstName, LastName, LeadSource, AnnualRevenue, CreatedDate, LastActivityDate, State FROM Lead WHERE Id=:ref.Id];
        cold = [SELECT Id, FirstName, LastName, LeadSource, AnnualRevenue, CreatedDate, LastActivityDate, State FROM Lead WHERE Id=:cold.Id];
        System.assert(OmnishiftEngine.score(ref).score > OmnishiftEngine.score(cold).score,
            'A referral must outrank a purchased-list lead');
    }

    @isTest static void suppressesRecordWeAlreadyOwn() {
        Lead l = new Lead(LastName='Dupe', Company='X', Email='dupe@example.com');
        OmnishiftEngine.Outcome o = OmnishiftEngine.suppressionCheck(
            l, new Set<String>{'dupe@example.com'}, new Set<String>());
        System.assert(o.suppressed, 'A lead matching an owned contact email must be suppressed');
        System.assert(o.suppressReason.contains('cross-reference'));
    }

    @isTest static void complianceBlocksGuaranteeAndPerformance() {
        System.assertEquals('Blocked',
            OmnishiftEngine.complianceCheck('x', 'we guarantee results').complianceStatus);
        System.assertEquals('Blocked',
            OmnishiftEngine.complianceCheck('x', 'we returned 12% annually').complianceStatus);
        System.assertEquals('Flagged',
            OmnishiftEngine.complianceCheck('x', 'our clients say we are great').complianceStatus);
        System.assertEquals('Auto-corrected',
            OmnishiftEngine.complianceCheck('x', 'the best firm around').complianceStatus);
        System.assertEquals('Passed',
            OmnishiftEngine.complianceCheck('A short introduction', 'Happy to make time.').complianceStatus);
    }

    @isTest static void draftsAreCleanByDefault() {
        Lead l = new Lead(FirstName='Ann', LastName='Lee', Company='Lee Co');
        for (String d : new List<String>{'Referral','Inbound web','New and unworked','ICP fit'}) {
            OmnishiftEngine.Outcome o = OmnishiftEngine.draft(l, d);
            System.assertEquals('Passed',
                OmnishiftEngine.complianceCheck(o.draftSubject, o.draftBody).complianceStatus,
                'Our own templates must pass compliance: ' + d);
        }
    }

    @isTest static void batchScoresAndRanks() {
        List<Lead> ls = new List<Lead>();
        for (Integer i = 0; i < 20; i++) {
            ls.add(new Lead(LastName='L'+i, Company='C'+i,
                LeadSource = (Math.mod(i,2)==0 ? 'Referral' : 'Purchased List'),
                AnnualRevenue = 1000000 * i));
        }
        insert ls;
        Test.startTest();
        Database.executeBatch(new OmnishiftEngineBatch(), 200);
        Test.stopTest();
        Integer scored = [SELECT COUNT() FROM Lead WHERE Omnishift_Score__c > 0];
        System.assert(scored > 0, 'The batch must score leads');
        Integer ranked = [SELECT COUNT() FROM Lead WHERE Omnishift_Rank__c = 1];
        System.assertEquals(1, ranked, 'Exactly one lead holds rank 1');
    }

    @isTest static void runNowReturnsAJobId() {
        Test.startTest();
        String jobId = OmnishiftEngineBatch.runNow();
        Test.stopTest();
        System.assertNotEquals(null, jobId);
    }

    @isTest static void schedulerRuns() {
        Test.startTest();
        System.schedule('OmnishiftTest', '0 0 2 * * ?', new OmnishiftEngineSchedule());
        Test.stopTest();
    }

    @isTest static void autoCorrectActuallyRemovesTheTerm() {
        OmnishiftEngine.Outcome c = OmnishiftEngine.complianceCheck(
            'Worth a conversation?', 'Margaret - we are the best firm in Chicago. No pitch.');
        System.assertEquals('Auto-corrected', c.complianceStatus);
        System.assert(c.complianceReason.contains('Re-read'),
            'Stripping a phrase can leave a limping sentence; the advisor must be told: '
            + c.complianceReason);
        System.assertNotEquals(null, c.draftBody,
            'An auto-corrected result must return the corrected text, not null.');
        System.assert(!c.draftBody.toLowerCase().contains('best'),
            'The term the label claims was removed must actually be gone: ' + c.draftBody);
        System.assert(c.draftBody.contains('firm in Chicago'), 'The rest of the sentence must survive.');
        System.assert(!c.draftBody.contains('  '), 'No double spaces left behind: ' + c.draftBody);
    }

    @isTest static void aPassingDraftIsLeftAlone() {
        OmnishiftEngine.Outcome c = OmnishiftEngine.complianceCheck('Hello', 'A plain and honest note.');
        System.assertEquals('Passed', c.complianceStatus);
        System.assertEquals(null, c.draftBody, 'Nothing to correct means nothing returned.');
    }

    @isTest static void complianceReasonDoesNotTouchTheAdvisorsReason() {
        Lead l = new Lead(FirstName='Ada', LastName='Byron', Company='Engines',
                          LeadSource='Referral', Status='Open - Not Contacted',
                          Omnishift_Disposition_Reason__c='Advisor said the timing was wrong');
        insert l;
        Test.startTest();
        OmnishiftEngineBatch.runNow();
        Test.stopTest();
        Lead after = [SELECT Omnishift_Disposition_Reason__c, Omnishift_Compliance_Reason__c
                      FROM Lead WHERE Id = :l.Id];
        System.assertEquals('Advisor said the timing was wrong', after.Omnishift_Disposition_Reason__c,
            'A scoring run must not overwrite what the advisor recorded.');
        System.assertNotEquals(null, after.Omnishift_Compliance_Reason__c,
            'The compliance reason belongs in its own field.');
    }

    @isTest static void aFreshWebEnquirySaysSoEvenWhenTimingWins() {
        Lead l = new Lead(FirstName='Wren', LastName='Ashcombe', Company='Ashcombe Partners',
                          LeadSource='Web', Status='Open - Not Contacted');
        insert l;
        Lead fresh = [SELECT Id, FirstName, LastName, Company, Email, State, Status, LeadSource,
                             AnnualRevenue, DoNotCall, HasOptedOutOfEmail, IsConverted,
                             CreatedDate, LastActivityDate FROM Lead WHERE Id = :l.Id];
        OmnishiftEngine.Outcome o = OmnishiftEngine.score(fresh);
        System.assertEquals('New and unworked', o.topDriver,
            'Timing outweighs web intake for a brand new lead - that is the model.');
        System.assert(o.whyNow.contains('inbound web enquiry'),
            'But the advisor still has to be told it came from a form: ' + o.whyNow);
        System.assert(o.whyNow.contains('five-minute'), o.whyNow);
    }

    @isTest static void aReferralThatLosesOnTimingIsStillNamedAReferral() {
        Lead l = new Lead(FirstName='Soren', LastName='Blackwood', Company='Blackwood Holdings',
                          LeadSource='Partner Referral', Status='Open - Not Contacted',
                          AnnualRevenue=50000000);
        insert l;
        Lead fresh = [SELECT Id, FirstName, LastName, Company, Email, State, Status, LeadSource,
                             AnnualRevenue, DoNotCall, HasOptedOutOfEmail, IsConverted,
                             CreatedDate, LastActivityDate FROM Lead WHERE Id = :l.Id];
        OmnishiftEngine.Outcome o = OmnishiftEngine.score(fresh);
        if (o.topDriver != 'Referral') {
            System.assert(o.whyNow.contains('referral'),
                'A referral must never disappear from the explanation: ' + o.whyNow);
        }
    }

    // ---- Contacts ----------------------------------------------------------
    // The existing-client half. CreatedDate and LastActivityDate are read-only,
    // so the rules that turn on them are exercised through Prospect directly;
    // everything reachable from a real record is exercised on one.

    private static Contact client(String first, String last, String source, String title, Id accountId) {
        return new Contact(FirstName=first, LastName=last, Email=first.toLowerCase()+'.'+last.toLowerCase()+'@example.com',
                           LeadSource=source, Title=title, AccountId=accountId,
                           MailingCountry='United States', MailingState='Illinois');
    }

    private static final String CONTACT_FIELDS =
        'Id, FirstName, LastName, Email, MailingState, Title, LeadSource, AccountId, '
      + 'Account.AnnualRevenue, DoNotCall, HasOptedOutOfEmail, CreatedDate, LastActivityDate';

    @isTest static void aClientIsScoredLikeAClientNotAProspect() {
        Account a = new Account(Name='Vexley Holdings', AnnualRevenue=5000000);
        insert a;
        Contact c = client('Greta','Vexley','Purchased List','CFO', a.Id);
        insert c;
        Contact fresh = (Contact) Database.query('SELECT ' + CONTACT_FIELDS + ' FROM Contact')[0];
        OmnishiftEngine.Outcome o = OmnishiftEngine.score(fresh);

        System.assert(o.score > 0, 'A Contact must come out of the engine with a score, not a blank');
        System.assert(!o.whyNow.contains('five-minute'),
            'A client must never be told they filed an inbound enquiry: ' + o.whyNow);
        System.assert(!o.whyNow.contains('never contacted'),
            'A client is not an unworked lead: ' + o.whyNow);
        System.assertNotEquals('New and unworked', o.topDriver,
            'A client has no intake event to be new against; that driver is prospect-only');
    }

    @isTest static void anIntroducedClientOutranksOneOffAList() {
        Account a = new Account(Name='Same Account', AnnualRevenue=5000000);
        insert a;
        Contact introduced = client('Ferris','Ollerton','External Referral','CFO', a.Id);
        Contact listed     = client('Orsola','Blackwood','Purchased List','CFO', a.Id);
        insert new List<Contact>{ introduced, listed };
        Map<Id, Contact> byId = new Map<Id, Contact>(
            (List<Contact>) Database.query('SELECT ' + CONTACT_FIELDS + ' FROM Contact'));
        Integer intro = OmnishiftEngine.score(byId.get(introduced.Id)).score;
        Integer cold  = OmnishiftEngine.score(byId.get(listed.Id)).score;
        System.assert(intro > cold,
            'Same account, same seniority: the household that arrived by introduction must rank higher ('
            + intro + ' vs ' + cold + ')');
        System.assertEquals('Referral', OmnishiftEngine.score(byId.get(introduced.Id)).topDriver,
            'An introduced client is driven by the introduction, not by profile');
    }

    @isTest static void seniorityLiftsFitWhenTheAccountIsTheSame() {
        Account a = new Account(Name='One Account', AnnualRevenue=600000);
        insert a;
        Contact chief = client('Maeve','Netherby','Other','Chief Investment Officer', a.Id);
        Contact staff = client('Piers','Ironwood','Other','Warehouse Coordinator', a.Id);
        insert new List<Contact>{ chief, staff };
        Map<Id, Contact> byId = new Map<Id, Contact>(
            (List<Contact>) Database.query('SELECT ' + CONTACT_FIELDS + ' FROM Contact'));
        System.assert(OmnishiftEngine.score(byId.get(chief.Id)).score
                    > OmnishiftEngine.score(byId.get(staff.Id)).score,
            'Company revenue is the same, so the decision-maker has to be the better fit');
    }

    @isTest static void aClientPastTheAnnualReviewIsCalledOverdue() {
        OmnishiftEngine.Prospect p = new OmnishiftEngine.Prospect();
        p.objectType = 'Contact';
        p.isClient = true;
        p.firstName = 'Niall'; p.lastName = 'Ullswater';
        p.intakeChannel = 'Other';
        p.fitValue = 400000;
        p.createdDate = Datetime.now().addDays(-900);
        p.lastActivityDate = Date.today().addDays(-400);

        OmnishiftEngine.Outcome o = OmnishiftEngine.score(p);
        System.assertEquals('Review overdue', o.topDriver,
            'Thirteen months of silence on a client relationship is the strongest thing on the record');
        System.assert(o.whyNow.contains('annual review'),
            'The advisor has to be told which standard was missed: ' + o.whyNow);
        System.assertEquals('Passed',
            OmnishiftEngine.complianceCheck(
                OmnishiftEngine.draft(p, o.topDriver).draftSubject,
                OmnishiftEngine.draft(p, o.topDriver).draftBody).complianceStatus,
            'The overdue-review template must clear compliance like every other one');
    }

    @isTest static void clientDraftsAreCleanAndNeverGreetAClientAsAStranger() {
        OmnishiftEngine.Prospect p = new OmnishiftEngine.Prospect();
        p.isClient = true; p.firstName = 'Thea'; p.lastName = 'Mossgrove';
        for (String d : new List<String>{'Referral','Review overdue','Existing relationship','Dormant','ICP fit'}) {
            OmnishiftEngine.Outcome o = OmnishiftEngine.draft(p, d);
            System.assertEquals('Passed',
                OmnishiftEngine.complianceCheck(o.draftSubject, o.draftBody).complianceStatus,
                'Client templates must pass compliance: ' + d);
            System.assert(!o.draftBody.contains('thank you for getting in touch'),
                'That is the reply to a web form, not a note to a client: ' + d);
            System.assert(!o.draftBody.contains('I work with families on planning'),
                'A client already knows what the firm does: ' + d);
        }
    }

    // ---- Contact suppression ----------------------------------------------

    @isTest static void aClientIsNotSuppressedAsADuplicateOfItself() {
        Contact c = new Contact(FirstName='Dashiell', LastName='Ainsleigh',
                                Email='dashiell.ainsleigh@example.com');
        // Exactly the sets the batch builds: every Contact is in them by construction.
        OmnishiftEngine.Outcome o = OmnishiftEngine.suppressionCheck(
            c,
            new Set<String>{'dashiell.ainsleigh@example.com'},
            new Set<String>{'dashiell ainsleigh'});
        System.assert(!o.suppressed,
            'The duplicate rule matches Leads against owned Contacts. Run over Contacts it '
            + 'would suppress the entire client base against itself: ' + o.suppressReason);
    }

    @isTest static void aClientWhoRefusedBothChannelsIsStillSuppressed() {
        Contact c = new Contact(FirstName='Hollis', LastName='Carrowmore',
                                DoNotCall=true, HasOptedOutOfEmail=true);
        OmnishiftEngine.Outcome o = OmnishiftEngine.suppressionCheck(
            c, new Set<String>(), new Set<String>());
        System.assert(o.suppressed, 'Consent applies to a client exactly as it does to a stranger');
        System.assertEquals('Do not call and opted out of email', o.suppressReason);
    }

    @isTest static void aRecentlyContactedClientIsInTheCoolingPeriod() {
        OmnishiftEngine.Prospect p = new OmnishiftEngine.Prospect();
        p.isClient = true; p.firstName = 'Isolde'; p.lastName = 'Jessamy';
        p.lastActivityDate = Date.today().addDays(-3);
        OmnishiftEngine.Outcome o = OmnishiftEngine.suppressionCheck(
            p, new Set<String>(), new Set<String>());
        System.assert(o.suppressed, 'Two advisors reaching one household in a fortnight is the bug');
        System.assert(o.suppressReason.contains('cooling period'), o.suppressReason);
    }

    @isTest static void theBatchWritesASuppressedClientBackAsSuppressed() {
        Account a = new Account(Name='Suppressed Co', AnnualRevenue=8000000);
        insert a;
        Contact c = client('Kestrel','Yarrowby','External Referral','CFO', a.Id);
        c.DoNotCall = true;
        c.HasOptedOutOfEmail = true;
        insert c;
        Test.startTest();
        OmnishiftEngineBatch.runNow();
        Test.stopTest();
        Contact after = [SELECT Omnishift_Score__c, Omnishift_Rank__c, Omnishift_Why_Now__c,
                                Omnishift_Draft_Body__c, Omnishift_Scored_On__c
                         FROM Contact WHERE Id = :c.Id];
        System.assertEquals(0, after.Omnishift_Score__c,
            'A suppressed client must be written back at zero, not left at yesterday score');
        System.assertEquals(null, after.Omnishift_Rank__c, 'A suppressed client holds no place in the queue');
        System.assertEquals(null, after.Omnishift_Draft_Body__c,
            'No draft may survive on a record the engine has decided not to contact');
        System.assert(after.Omnishift_Why_Now__c.startsWith('Suppressed:'),
            'The advisor has to be told why it dropped out: ' + after.Omnishift_Why_Now__c);
        System.assertNotEquals(null, after.Omnishift_Scored_On__c,
            'A suppressed record was still looked at, and the run has to say so');
    }

    // ---- cross-object ranking ----------------------------------------------

    @isTest static void theBatchScoresBothObjectsUnderOneRanking() {
        Account a = new Account(Name='Ranking Co', AnnualRevenue=8000000);
        insert a;
        List<Contact> cs = new List<Contact>();
        for (Integer i = 0; i < 6; i++) {
            cs.add(client('Client'+i, 'Household'+i,
                (Math.mod(i,2)==0 ? 'External Referral' : 'Purchased List'),
                (Math.mod(i,3)==0 ? 'CFO' : 'Analyst'), a.Id));
        }
        insert cs;
        List<Lead> ls = new List<Lead>();
        for (Integer i = 0; i < 6; i++) {
            ls.add(new Lead(FirstName='Prospect'+i, LastName='Enquiry'+i, Company='C'+i,
                LeadSource = (Math.mod(i,2)==0 ? 'Partner Referral' : 'Purchased List'),
                AnnualRevenue = 1000000 * (i + 1)));
        }
        insert ls;

        Test.startTest();
        Database.executeBatch(new OmnishiftEngineBatch(), 200);
        Test.stopTest();

        Integer scoredContacts = [SELECT COUNT() FROM Contact WHERE Omnishift_Score__c > 0];
        Integer scoredLeads    = [SELECT COUNT() FROM Lead    WHERE Omnishift_Score__c > 0];
        System.assertEquals(6, scoredContacts, 'Every eligible Contact must be scored, not just the Leads');
        System.assert(scoredLeads > 0, 'The Lead half must keep working');

        List<Decimal> ranks = new List<Decimal>();
        for (Lead l : [SELECT Omnishift_Rank__c FROM Lead WHERE Omnishift_Rank__c != null]) {
            ranks.add(l.Omnishift_Rank__c);
        }
        Integer contactRanks = 0;
        for (Contact c : [SELECT Omnishift_Rank__c FROM Contact WHERE Omnishift_Rank__c != null]) {
            ranks.add(c.Omnishift_Rank__c);
            contactRanks++;
        }
        System.assertEquals(6, contactRanks, 'Contacts must appear in the ranking, not only in the scoring');
        System.assertEquals(scoredContacts + scoredLeads, ranks.size(),
            'Everything scored must be ranked exactly once');
        Set<Decimal> distinct = new Set<Decimal>(ranks);
        System.assertEquals(ranks.size(), distinct.size(),
            'The rank is a single ordering across both objects - no number may be used twice');
        System.assert(distinct.contains(1), 'The ordering has to start at 1');
        System.assertEquals(ranks.size(), (Integer) collapse(distinct),
            'The ordering must be contiguous from 1, with no gaps left by the merge');
    }

    // Highest rank present, used to prove 1..n is contiguous.
    private static Decimal collapse(Set<Decimal> ranks) {
        Decimal top = 0;
        for (Decimal r : ranks) if (r > top) top = r;
        return top;
    }

    @isTest static void oneRankOneAcrossBothObjects() {
        Account a = new Account(Name='Tie Co', AnnualRevenue=8000000);
        insert a;
        insert client('Rosalind','Wexford','External Referral','CFO', a.Id);
        insert new Lead(FirstName='Soren', LastName='Blackwood', Company='Blackwood Holdings',
                        LeadSource='Partner Referral', AnnualRevenue=50000000);
        Test.startTest();
        OmnishiftEngineBatch.runNow();
        Test.stopTest();
        Integer atOne = [SELECT COUNT() FROM Lead WHERE Omnishift_Rank__c = 1]
                      + [SELECT COUNT() FROM Contact WHERE Omnishift_Rank__c = 1];
        System.assertEquals(1, atOne,
            'A Contact and a Lead must not both be rank 1 - that is the whole point of one queue');
    }
}
