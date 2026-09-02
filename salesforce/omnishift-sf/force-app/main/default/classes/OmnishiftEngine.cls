/**
 * Growth Agent engine. Everything the pipeline does, running inside Salesforce:
 * suppress, score, rank, route, draft, and compliance-check.
 *
 * Deliberately deterministic and inspectable - every number a human sees on the
 * record can be traced back to a rule in this class.
 *
 * It works both halves of the use case. A Lead is somebody the firm wants; a
 * Contact is somebody the firm already has. The rules are the same four
 * dimensions in both cases - intake, timing, fit, dormancy - because a single
 * ranked queue is only defensible if one set of weights produced it.
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

    /**
     * The one shape every rule below operates on.
     *
     * Chosen over dynamic SObject field access because Lead and Contact do not
     * hold the same facts under the same names - there is no AnnualRevenue on a
     * Contact and no MailingState on a Lead - so a dynamic version would still
     * have needed an object test inside every rule, which is exactly the drift a
     * shared engine exists to prevent. Mapping happens once, in fromLead and
     * fromContact. Below that line nothing asks which object it came from; the
     * three places where the meaning genuinely differs test isClient, and they
     * sit next to the prospect branch so the two can be read together.
     */
    public class Prospect {
        public Id recordId;
        public String objectType;
        public String firstName;
        public String lastName;
        public String state;
        public String email;
        public String intakeChannel;
        public Decimal fitValue;          // Lead: the company's revenue. Contact: the account behind the client.
        public String title;              // Contact only - a Lead's title is not reliably populated at intake.
        public Datetime createdDate;
        public Date lastActivityDate;
        public Boolean isClient = false;
        public String closedReason;       // non-null only for a Lead that is out of play
        public Boolean doNotCall = false;
        public Boolean optedOutOfEmail = false;
        public Boolean checkOwnedDuplicates = false;
    }

    /** Scoring needs FirstName, LastName, LeadSource, AnnualRevenue, CreatedDate
     *  and LastActivityDate. Everything else is read through the guards below,
     *  so a caller that only wants a score need not select what only suppression
     *  and routing use. */
    public static Prospect fromLead(Lead l) {
        Prospect p = new Prospect();
        p.recordId = l.Id;
        p.objectType = 'Lead';
        p.firstName = l.FirstName;
        p.lastName = l.LastName;
        p.state = text(l, 'State');
        p.email = text(l, 'Email');
        p.intakeChannel = l.LeadSource;
        p.fitValue = l.AnnualRevenue;
        p.createdDate = l.CreatedDate;
        p.lastActivityDate = l.LastActivityDate;
        p.doNotCall = flag(l, 'DoNotCall');
        p.optedOutOfEmail = flag(l, 'HasOptedOutOfEmail');
        if (flag(l, 'IsConverted')) p.closedReason = 'Already converted';
        else if (text(l, 'Status') == 'Closed - Not Converted') p.closedReason = 'Closed';
        // Only a Lead can be a duplicate of an owned Contact.
        p.checkOwnedDuplicates = true;
        return p;
    }

    /** Scoring needs FirstName, LastName, LeadSource, Title, Account.AnnualRevenue,
     *  CreatedDate and LastActivityDate. The rest is guarded, as on the Lead side. */
    public static Prospect fromContact(Contact c) {
        Prospect p = new Prospect();
        p.recordId = c.Id;
        p.objectType = 'Contact';
        p.firstName = c.FirstName;
        p.lastName = c.LastName;
        p.state = text(c, 'MailingState');
        p.email = text(c, 'Email');
        p.intakeChannel = c.LeadSource;
        p.title = c.Title;
        p.fitValue = accountRevenue(c);
        p.createdDate = c.CreatedDate;
        p.lastActivityDate = c.LastActivityDate;
        p.doNotCall = flag(c, 'DoNotCall');
        p.optedOutOfEmail = flag(c, 'HasOptedOutOfEmail');
        p.isClient = true;
        // A Contact has no converted or closed state, and nothing in the schema
        // marks a departed client, so no Contact is ever suppressed as out of
        // play. That is a gap in the data, not a decision.
        p.closedReason = null;
        p.checkOwnedDuplicates = false;
        return p;
    }

    // Suppression and routing need facts scoring does not - the consent flags,
    // the closed states, the email the duplicate check matches on. Reading those
    // through isSet keeps score(record) callable from a query that selected only
    // what scoring uses, which is how the engine was called before it took
    // Contacts, and stops one shared mapper widening every caller's SELECT list.
    private static Boolean flag(SObject rec, String field) {
        return rec.isSet(field) && rec.get(field) == true;
    }
    private static String text(SObject rec, String field) {
        return rec.isSet(field) ? (String) rec.get(field) : null;
    }
    // The parent is reached through the populated-field map because there is no
    // isSet for a relationship and reading an unqueried one throws.
    private static Decimal accountRevenue(Contact c) {
        SObject a = (SObject) c.getPopulatedFieldsAsMap().get('Account');
        if (a == null || !a.isSet('AnnualRevenue')) return null;
        return (Decimal) a.get('AnnualRevenue');
    }

    /**
     * IsPersonAccount only exists once person accounts are turned on, so naming
     * it in Apex would stop this class compiling in an org where they are off -
     * which is the case here. Callers use this to decide scope, because a person
     * account's contact row is a shadow of the account and the platform refuses
     * DML against it: scoring one would only produce a result with nowhere to go.
     */
    public static Boolean personAccountsEnabled() {
        if (personAccounts == null) {
            personAccounts = Schema.SObjectType.Contact.fields.getMap().containsKey('ispersonaccount');
        }
        return personAccounts;
    }
    private static Boolean personAccounts;

    // ---- suppression -------------------------------------------------------
    // The bottleneck the client named first: records you already own, records too
    // small to be worth a call, and anyone in a cooling period.
    public static Outcome suppressionCheck(Lead l, Set<String> ownedEmails, Set<String> ownedNames) {
        return suppressionCheck(fromLead(l), ownedEmails, ownedNames);
    }
    public static Outcome suppressionCheck(Contact c, Set<String> ownedEmails, Set<String> ownedNames) {
        return suppressionCheck(fromContact(c), ownedEmails, ownedNames);
    }

    public static Outcome suppressionCheck(Prospect p, Set<String> ownedEmails, Set<String> ownedNames) {
        Outcome o = new Outcome();
        if (p.closedReason != null) { o.suppressed = true; o.suppressReason = p.closedReason; return o; }
        // Consent applies to a client exactly as it does to a stranger.
        if (p.doNotCall && p.optedOutOfEmail) {
            o.suppressed = true; o.suppressReason = 'Do not call and opted out of email'; return o;
        }
        // The duplicate rules exist to stop the firm cold-calling somebody it
        // already serves. A Contact is the record they match against, so running
        // them over Contacts would suppress the entire client base against itself.
        if (p.checkOwnedDuplicates) {
            String key = (p.email == null) ? null : p.email.toLowerCase();
            if (key != null && ownedEmails.contains(key)) {
                o.suppressed = true; o.suppressReason = 'Duplicate of an owned Contact - cross-reference'; return o;
            }
            String nm = ((p.firstName == null ? '' : p.firstName) + ' ' + p.lastName).trim().toLowerCase();
            if (ownedNames.contains(nm)) {
                o.suppressed = true; o.suppressReason = 'Duplicate of an owned Contact - name match'; return o;
            }
        }
        // Cooling period. If anything, it matters more for a client: two advisors
        // reaching the same household in a fortnight reads as disorganisation.
        if (p.lastActivityDate != null && p.lastActivityDate > Date.today().addDays(-14)) {
            o.suppressed = true; o.suppressReason = 'Contacted within 14 days - cooling period'; return o;
        }
        return o;
    }

    // ---- scoring -----------------------------------------------------------
    // A transparent linear model. Weights are constants so the contribution of each
    // feature is readable; production would fit these on the firm's own history.
    public static Outcome score(Lead l)    { return score(fromLead(l)); }
    public static Outcome score(Contact c) { return score(fromContact(c)); }

    public static Outcome score(Prospect p) {
        Outcome o = new Outcome();

        Decimal wIntake = 0, wEvent = 0, wFit = 0, wDormancy = 0;
        String driver = 'ICP fit';
        String intakeDriver = 'ICP fit';
        String src = p.intakeChannel;

        Integer ageDays = (p.createdDate == null) ? 999
            : Date.today().daysBetween(p.createdDate.date()) * -1;
        Integer idleDays = (p.lastActivityDate == null) ? ageDays
            : p.lastActivityDate.daysBetween(Date.today());

        // ---- intake channel
        // For a prospect this is how the enquiry arrived, and referrals and
        // inbound forms carry an SLA.
        //
        // A client has no intake channel worth scoring: the door is already open,
        // so grading how they first arrived would be grading history rather than
        // opportunity. What stands in for it is the relationship itself - warmer
        // than any cold channel, cooler than a live referral, hence a flat
        // baseline between the two. The one origin still worth carrying forward
        // is an introduction, because the household that arrived through one is
        // the household most likely to make the next one, and that is the firm's
        // cheapest source of new money.
        if (p.isClient) {
            if (isIntroduction(src)) { wIntake = 100; intakeDriver = 'Referral'; }
            else { wIntake = 70; intakeDriver = 'Existing relationship'; }
        } else if (src == 'Referral' || src == 'Partner Referral' || src == 'Employee Referral') {
            wIntake = 100; intakeDriver = 'Referral';
        } else if (src == 'Web') {
            wIntake = 75; intakeDriver = 'Inbound web';
        } else if (src == 'Purchased List' || src == 'Advertisement') {
            wIntake = 25;
        } else {
            wIntake = 10;
        }

        // ---- timing signal
        // For a prospect: a recently created, never-worked lead is a live window.
        //
        // For a client the creation date is tenure, not an event, so it says
        // nothing about today. The timing signal that does is the review cadence:
        // the firm's stated standard is an annual review, so a relationship past
        // twelve months with nothing recorded against it is late rather than
        // merely quiet, and six months is the warning.
        String eventDriver;
        if (p.isClient) {
            if (idleDays >= 365) { wEvent = 90; }
            else if (idleDays >= 180) { wEvent = 60; }
            else { wEvent = 10; }
            eventDriver = 'Review overdue';
        } else {
            if (ageDays <= 7 && p.lastActivityDate == null) { wEvent = 90; }
            else if (ageDays <= 30 && p.lastActivityDate == null) { wEvent = 60; }
            else { wEvent = 10; }
            eventDriver = 'New and unworked';
        }

        // ---- ICP fit
        // The firm holds no view of a household's investable assets, so corporate
        // revenue is the only proxy either object offers, and both objects climb
        // the same ladder - a Lead and a Contact at a company of the same size
        // have to land on the same rung or the merged ranking means nothing.
        Decimal rev = (p.fitValue == null) ? 0 : p.fitValue;
        if (rev >= 10000000) wFit = 100;
        else if (rev >= 2000000) wFit = 80;
        else if (rev >= 500000) wFit = 50;
        else if (rev > 0) wFit = 25;
        else wFit = p.isClient ? 40 : 30; // unknown revenue is not evidence of a bad fit,
                                          // and less so for somebody already served
        // About a client the firm knows one more thing - what they actually do -
        // and for a household the person's own standing tracks their balance
        // sheet more closely than their employer's turnover does. Blended rather
        // than added, because at any account past ten million the revenue rung is
        // already at the ceiling and an added bonus would separate nobody.
        if (p.isClient) wFit = (wFit * 0.75) + (seniority(p.title) * 0.25);

        // ---- dormancy
        // A prospect ageing out unworked. For a client the same silence is the
        // more expensive failure, so the threshold holds and only the wording
        // changes further down.
        if (p.lastActivityDate == null && ageDays > 180) { wDormancy = 55; }
        else { wDormancy = 10; }

        // The driver is whichever weighted contribution is actually largest - not
        // whichever branch happened to run last.
        Decimal cIntake = wIntake * 0.30, cEvent = wEvent * 0.30,
                cFit = wFit * 0.25, cDorm = wDormancy * 0.15;
        Decimal best = cIntake; driver = intakeDriver;
        if (cEvent > best) { best = cEvent; driver = eventDriver; }
        if (cFit  > best) { best = cFit;  driver = 'ICP fit'; }
        if (cDorm > best) { best = cDorm; driver = 'Dormant'; }

        Decimal total = cIntake + cEvent + cFit + cDorm;
        o.score = Integer.valueOf(total.setScale(0, System.RoundingMode.HALF_UP));
        if (o.score > 100) o.score = 100;
        if (o.score < 1) o.score = 1;
        o.topDriver = driver;

        // why now, in plain language, built from whichever driver actually won
        if (driver == 'Referral') {
            o.whyNow = p.isClient
                ? 'This relationship began with an introduction. Households that arrive that way tend to make introductions themselves, and nobody has asked in a while.'
                : 'Referral. Referred prospects convert better than any other intake, and the firm treats them as an immediate-response SLA.';
        } else if (driver == 'Inbound web') {
            o.whyNow = 'Inbound web enquiry. The stated SLA is a response inside five minutes, and this record has not been worked yet.';
        } else if (driver == 'New and unworked') {
            o.whyNow = 'Created ' + ageDays + ' days ago and never contacted. The window is open now and closes as it ages.';
        } else if (driver == 'Review overdue') {
            o.whyNow = 'Nothing recorded against this relationship for roughly ' + (idleDays / 30)
                + ' months. The firm works to an annual review, so this one is past due.';
        } else if (driver == 'Existing relationship') {
            o.whyNow = 'An existing client with no single urgent signal this week. Cross-sell and planning work is the reason to call, not an event.';
        } else if (driver == 'Dormant') {
            o.whyNow = p.isClient
                ? 'Dormant roughly ' + (ageDays / 30) + ' months with nothing recorded at all. Client relationships rarely announce that they are leaving.'
                : 'Dormant roughly ' + (ageDays / 30) + ' months with no activity recorded. Ageing out of the pipeline unworked.';
        } else {
            o.whyNow = p.isClient
                ? 'The strongest signal here is profile: a senior decision-maker at a substantial account, with no more urgent timing reason. A planning conversation rather than a call today.'
                : 'Profile fit against the ideal client, with no stronger timing signal. A nurture candidate rather than a call-today candidate.';
        }

        // A single top driver hides the rest of the picture. A fresh inbound web
        // enquiry scores lower on intake than it does on recency, so timing wins
        // and the why-now would read "created 2 days ago" for someone who just
        // filled in a form - true, but not the fact the advisor needs. Where a
        // strong intake signal lost, say so alongside the reason that won.
        // "Existing relationship" is never news, so it is not repeated here.
        if (driver != intakeDriver) {
            if (intakeDriver == 'Referral') {
                o.whyNow += p.isClient
                    ? ' The relationship itself began with an introduction.'
                    : ' It also arrived as a referral.';
            } else if (intakeDriver == 'Inbound web') {
                o.whyNow += ' It also arrived as an inbound web enquiry, which carries the five-minute response SLA.';
            }
        }
        return o;
    }

    // The values the firm's data actually carries for "somebody introduced them",
    // across both objects and including the inactive picklist entries still on
    // older records. "Word of mouth" is an introduction without a named referrer,
    // which is weaker evidence but the same mechanism.
    private static Boolean isIntroduction(String src) {
        if (src == null) return false;
        String s = src.toLowerCase();
        return s == 'referral' || s == 'partner referral' || s == 'employee referral'
            || s == 'external referral' || s == 'partner' || s == 'word of mouth';
    }

    // Word boundaries, not substrings: "coordinator" contains "coo" and a
    // warehouse coordinator is not the chief operating officer.
    private static final Pattern PRINCIPAL = Pattern.compile(
        '(?i)\\b(chief|ceo|cfo|coo|cio|cto|president|owner|founder|partner|principal|managing director)\\b');
    private static final Pattern SENIOR = Pattern.compile(
        '(?i)\\b(evp|svp|vp|vice president|director|dean|head)\\b');

    private static Decimal seniority(String title) {
        if (String.isBlank(title)) return 20;
        if (PRINCIPAL.matcher(title).find()) return 100;
        if (SENIOR.matcher(title).find()) return 60;
        return 20;
    }

    // ---- routing -----------------------------------------------------------
    // Advisory only. We never write OwnerId in bulk: ownership changes force sharing
    // recalculation across the role hierarchy.
    public static Id route(Lead l, List<User> pool, Map<Id, Integer> load) {
        return route(fromLead(l), pool, load);
    }
    public static Id route(Contact c, List<User> pool, Map<Id, Integer> load) {
        return route(fromContact(c), pool, load);
    }

    public static Id route(Prospect p, List<User> pool, Map<Id, Integer> load) {
        if (pool.isEmpty()) return null;
        User best = null; Decimal bestScore = -1;
        for (User u : pool) {
            Decimal s = 0;
            if (p.state != null && u.State != null && p.state.equalsIgnoreCase(u.State)) s += 40;
            Integer n = load.containsKey(u.Id) ? load.get(u.Id) : 0;
            s += Math.max(0, 30 - n);              // capacity
            s += Math.mod(Math.abs(u.Id.hashCode()), 7); // stable tie-break
            if (s > bestScore) { bestScore = s; best = u; }
        }
        if (best != null) load.put(best.Id, (load.containsKey(best.Id) ? load.get(best.Id) : 0) + 1);
        return best == null ? null : best.Id;
    }

    // ---- drafting ----------------------------------------------------------
    // A client is not a prospect and must never be written to as if the firm has
    // just met them. Same drivers, different assumed relationship.
    public static Outcome draft(Lead l, String driver)    { return draft(fromLead(l), driver); }
    public static Outcome draft(Contact c, String driver) { return draft(fromContact(c), driver); }

    public static Outcome draft(Prospect p, String driver) {
        Outcome o = new Outcome();
        String first = (p.firstName == null || p.firstName == '') ? p.lastName : p.firstName;
        if (p.isClient) return draftForClient(o, first, driver);

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

    private static Outcome draftForClient(Outcome o, String first, String driver) {
        if (driver == 'Referral') {
            o.draftSubject = 'A thank you, and a thought';
            o.draftBody = first + ' - you came to us through an introduction, and I have never stopped being '
                + 'grateful for it. Nothing is needed from you today. If it would help to walk through the plan '
                + 'before the year turns, I will make the time.';
        } else if (driver == 'Review overdue') {
            o.draftSubject = 'Time we had a review';
            o.draftBody = first + ' - we are past due a proper look at the plan. Nothing is wrong; it has simply '
                + 'been a while, and circumstances move faster than paperwork. Half an hour would cover it.';
        } else if (driver == 'Dormant') {
            o.draftSubject = 'It has been too long';
            o.draftBody = first + ' - I realised how long it has been since we last spoke, and that is on us. '
                + 'If anything has changed at home or at work, I would rather hear it from you than infer it.';
        } else {
            o.draftSubject = 'A conversation worth having';
            o.draftBody = first + ' - planning, tax and estate questions tend to arrive together rather than one '
                + 'at a time, and we only look at part of that today. If there is a corner of it worth opening up, '
                + 'I am glad to make the time.';
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
        // Auto-correct has to actually correct. Returning the untouched text under
        // an "Auto-corrected" label tells a compliance officer a control fired
        // when it did not.
        String fixedSubject = (subject == null) ? '' : subject;
        String fixedBody    = (body == null) ? '' : body;
        List<String> removed = new List<String>();
        for (String t : autofix) {
            if (text.contains(t)) {
                fixedSubject = stripTerm(fixedSubject, t);
                fixedBody    = stripTerm(fixedBody, t);
                removed.add(t);
            }
        }
        if (!removed.isEmpty()) {
            o.complianceStatus = 'Auto-corrected';
            // Removing a phrase can leave the sentence around it limping - "Act now
            // and we can fit this in" becomes "and we can fit this in". The term is
            // genuinely gone, which is what compliance requires, but the advisor
            // still has to read it before it goes anywhere.
            o.complianceReason = 'Auto-corrected: removed "' + String.join(removed, '", "')
                + '". Re-read the sentence it was in before sending.';
            o.draftSubject = fixedSubject;
            o.draftBody = fixedBody;
            return o;
        }
        o.complianceStatus = 'Passed';
        o.complianceReason = 'Passed all checks.';
        return o;
    }

    // Removes a term case-insensitively and tidies the whitespace and article it
    // leaves behind, so "the best firm" becomes "the firm" rather than "the  firm".
    private static String stripTerm(String src, String term) {
        if (String.isBlank(src)) return src;
        String out = Pattern.compile('(?i)\\s*\\b' + Pattern.quote(term) + '\\b')
            .matcher(src).replaceAll('');
        out = out.replaceAll('\\s{2,}', ' ');
        out = out.replaceAll('\\s+([,.;:!?])', '$1');
        return out.trim();
    }
}
