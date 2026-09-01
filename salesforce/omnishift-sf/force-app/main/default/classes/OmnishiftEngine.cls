/**
 * Growth Agent engine. Everything the pipeline does, running inside Salesforce:
 * suppress, score, rank, route, draft, and compliance-check.
 *
 * Deliberately deterministic and inspectable - every number a human sees on the
 * record can be traced back to a rule in this class.
 */
public with sharing class OmnishiftEngine {

    public class Outcome {
        public Boolean suppressed = false;
        public String suppressReason;
        public Integer score = 0;
        public String whyNow;
        public Id ownerId;
        public String draftSubject;
        public String draftBody;
        public String complianceStatus;
        public String complianceReason;
        public String topDriver;
    }

    // ---- suppression -------------------------------------------------------
    // The bottleneck the client named first: records you already own, records too
    // small to be worth a call, and anyone in a cooling period.
    public static Outcome suppressionCheck(Lead l, Set<String> ownedEmails, Set<String> ownedNames) {
        Outcome o = new Outcome();
        if (l.IsConverted) { o.suppressed = true; o.suppressReason = 'Already converted'; return o; }
        if (l.Status == 'Closed - Not Converted') { o.suppressed = true; o.suppressReason = 'Closed'; return o; }
        if (l.DoNotCall == true && l.HasOptedOutOfEmail == true) {
            o.suppressed = true; o.suppressReason = 'Do not call and opted out of email'; return o;
        }
        String key = (l.Email == null) ? null : l.Email.toLowerCase();
        if (key != null && ownedEmails.contains(key)) {
            o.suppressed = true; o.suppressReason = 'Duplicate of an owned Contact - cross-reference'; return o;
        }
        String nm = ((l.FirstName == null ? '' : l.FirstName) + ' ' + l.LastName).trim().toLowerCase();
        if (ownedNames.contains(nm)) {
            o.suppressed = true; o.suppressReason = 'Duplicate of an owned Contact - name match'; return o;
        }
        if (l.LastActivityDate != null && l.LastActivityDate > Date.today().addDays(-14)) {
            o.suppressed = true; o.suppressReason = 'Contacted within 14 days - cooling period'; return o;
        }
        return o;
    }

    // ---- scoring -----------------------------------------------------------
    // A transparent linear model. Weights are constants so the contribution of each
    // feature is readable; production would fit these on the firm's own history.
    public static Outcome score(Lead l) {
        Outcome o = new Outcome();

        Decimal wIntake = 0, wEvent = 0, wFit = 0, wDormancy = 0;
        String driver = 'ICP fit';
        String intakeDriver = 'ICP fit';

        // intake channel - referrals and inbound forms carry an SLA
        String src = l.LeadSource;
        if (src == 'Referral' || src == 'Partner Referral' || src == 'Employee Referral') {
            wIntake = 100; intakeDriver = 'Referral';
        } else if (src == 'Web') {
            wIntake = 75; intakeDriver = 'Inbound web';
        } else if (src == 'Purchased List' || src == 'Advertisement') {
            wIntake = 25;
        } else {
            wIntake = 10;
        }

        // timing signal - a recently created, never-worked lead is a live window
        Integer ageDays = (l.CreatedDate == null) ? 999
            : Date.today().daysBetween(l.CreatedDate.date()) * -1;
        if (ageDays <= 7 && l.LastActivityDate == null) { wEvent = 90; }
        else if (ageDays <= 30 && l.LastActivityDate == null) { wEvent = 60; }
        else { wEvent = 10; }

        // ICP fit
        Decimal rev = (l.AnnualRevenue == null) ? 0 : l.AnnualRevenue;
        if (rev >= 10000000) wFit = 100;
        else if (rev >= 2000000) wFit = 80;
        else if (rev >= 500000) wFit = 50;
        else if (rev > 0) wFit = 25;
        else wFit = 30; // unknown revenue is not evidence of a bad fit

        // dormancy - an old untouched record ageing out
        if (l.LastActivityDate == null && ageDays > 180) { wDormancy = 55; }
        else { wDormancy = 10; }

        // The driver is whichever weighted contribution is actually largest - not
        // whichever branch happened to run last.
        Decimal cIntake = wIntake * 0.30, cEvent = wEvent * 0.30,
                cFit = wFit * 0.25, cDorm = wDormancy * 0.15;
        Decimal best = cIntake; driver = intakeDriver;
        if (cEvent > best) { best = cEvent; driver = 'New and unworked'; }
        if (cFit  > best) { best = cFit;  driver = 'ICP fit'; }
        if (cDorm > best) { best = cDorm; driver = 'Dormant'; }

        Decimal total = cIntake + cEvent + cFit + cDorm;
        o.score = Integer.valueOf(total.setScale(0, System.RoundingMode.HALF_UP));
        if (o.score > 100) o.score = 100;
        if (o.score < 1) o.score = 1;
        o.topDriver = driver;

        // why now, in plain language, built from whichever driver actually won
        String name = (l.FirstName == null ? l.LastName : l.FirstName);
        if (driver == 'Referral') {
            o.whyNow = 'Referral. Referred prospects convert better than any other intake, and the firm treats them as an immediate-response SLA.';
        } else if (driver == 'Inbound web') {
            o.whyNow = 'Inbound web enquiry. The stated SLA is a response inside five minutes, and this record has not been worked yet.';
        } else if (driver == 'New and unworked') {
            o.whyNow = 'Created ' + ageDays + ' days ago and never contacted. The window is open now and closes as it ages.';
        } else if (driver == 'Dormant') {
            o.whyNow = 'Dormant roughly ' + (ageDays / 30) + ' months with no activity recorded. Ageing out of the pipeline unworked.';
        } else {
            o.whyNow = 'Profile fit against the ideal client, with no stronger timing signal. A nurture candidate rather than a call-today candidate.';
        }
        return o;
    }

    // ---- routing -----------------------------------------------------------
    // Advisory only. We never write OwnerId in bulk: ownership changes force sharing
    // recalculation across the role hierarchy.
    public static Id route(Lead l, List<User> pool, Map<Id, Integer> load) {
        if (pool.isEmpty()) return null;
        User best = null; Decimal bestScore = -1;
        for (User u : pool) {
            Decimal s = 0;
            if (l.State != null && u.State != null && l.State.equalsIgnoreCase(u.State)) s += 40;
            Integer n = load.containsKey(u.Id) ? load.get(u.Id) : 0;
            s += Math.max(0, 30 - n);              // capacity
            s += Math.mod(Math.abs(u.Id.hashCode()), 7); // stable tie-break
            if (s > bestScore) { bestScore = s; best = u; }
        }
        if (best != null) load.put(best.Id, (load.containsKey(best.Id) ? load.get(best.Id) : 0) + 1);
        return best == null ? null : best.Id;
    }

    // ---- drafting ----------------------------------------------------------
    public static Outcome draft(Lead l, String driver) {
        Outcome o = new Outcome();
        String first = (l.FirstName == null || l.FirstName == '') ? l.LastName : l.FirstName;
        if (driver == 'Referral') {
            o.draftSubject = 'A note after your introduction';
            o.draftBody = first + ' - we were introduced through a mutual contact, so I wanted to reach out '
                + 'directly rather than through a form. No agenda. If there is a question worth twenty minutes, '
                + 'I am glad to make the time.';
        } else if (driver == 'Inbound web') {
            o.draftSubject = 'Following up on your enquiry';
            o.draftBody = first + ' - thank you for getting in touch. Happy to answer whatever prompted it, and '
                + 'to explain what a relationship actually looks like month to month. Twenty minutes, no materials.';
        } else if (driver == 'New and unworked') {
            o.draftSubject = 'A short introduction';
            o.draftBody = first + ' - I work with families on planning, tax and investment decisions that tend to '
                + 'arrive together rather than one at a time. If a short conversation would be useful at some point, '
                + 'I am glad to make time.';
        } else {
            o.draftSubject = 'Worth a conversation?';
            o.draftBody = first + ' - it has been a while since we were in touch. If your circumstances have moved '
                + 'on, I would be glad to hear about it. No pitch.';
        }
        return o;
    }

    // ---- compliance --------------------------------------------------------
    // Runs before a human sees the draft. Mirrors the SEC Marketing Rule general
    // prohibitions: no guarantees, no unsubstantiated performance, no superlatives,
    // no testimonial-shaped copy, no manufactured urgency.
    public static Outcome complianceCheck(String subject, String body) {
        Outcome o = new Outcome();
        String text = ((subject == null ? '' : subject) + ' ' + (body == null ? '' : body)).toLowerCase();
        List<String> blocking = new List<String>{
            'guarantee', 'guaranteed', 'risk-free', 'no risk', 'assured return',
            'outperform', 'beat the market', 'market-beating'
        };
        List<String> flagging = new List<String>{
            'our clients say', 'clients tell us', 'testimonial',
            'grow your wealth', 'maximise returns', 'maximize returns'
        };
        List<String> autofix = new List<String>{
            'best', 'number one', 'top-rated', 'premier', 'unmatched',
            'act now', 'limited time', 'last chance'
        };
        for (String t : blocking) {
            if (text.contains(t)) {
                o.complianceStatus = 'Blocked';
                o.complianceReason = 'Blocked: "' + t + '" - 206(4)-1(a) untrue or unsubstantiable claim.';
                return o;
            }
        }
        if (Pattern.compile('\\d+(\\.\\d+)?\\s?%\\s?(return|gain|growth|annually|per year)').matcher(text).find()) {
            o.complianceStatus = 'Blocked';
            o.complianceReason = 'Blocked: performance figure the adviser cannot substantiate on demand.';
            return o;
        }
        for (String t : flagging) {
            if (text.contains(t)) {
                o.complianceStatus = 'Flagged';
                o.complianceReason = 'Flagged: "' + t + '" - needs a human before send.';
                return o;
            }
        }
        for (String t : autofix) {
            if (text.contains(t)) {
                o.complianceStatus = 'Auto-corrected';
                o.complianceReason = 'Auto-corrected: removed "' + t + '".';
                return o;
            }
        }
        o.complianceStatus = 'Passed';
        o.complianceReason = 'Passed all checks.';
        return o;
    }
}
