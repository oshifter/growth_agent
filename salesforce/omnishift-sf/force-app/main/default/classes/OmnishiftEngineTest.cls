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
}
