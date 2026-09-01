# Is this actually buildable in Salesforce?

Every claim below was checked against Salesforce's own documentation. Verified means a
doc says so. Test means no doc confirms or excludes it and it needs ten minutes in an org.

## Verified supported

| Thing | Basis |
|---|---|
| LWC on a Lead/Contact record page | `lightning__RecordPage` target with an `objects` restriction is standard |
| LWC on Home and App pages | `lightning__HomePage`, `lightning__AppPage` targets |
| Writing fields from LWC with no Apex | `updateRecord` from `lightning/uiRecordApi` respects FLS and sharing |
| Restricted picklists as training labels | Standard `valueSet` / `restricted` metadata |
| Long Text Area up to 131,072 chars | Documented field limit; we use 32,768 |
| Lookup to User for recommended owner | Standard lookup |
| A queue as a Lead List View in Split View | Split View works in Standard Navigation since Summer '20 |
| Feedback capture with zero Apex | Screen Flow quick action -> Create Records, external system polls |
| Nightly load of ~200k rows | Bulk API 2.0: 10,000 records per batch, 150M records/day |

## Verified NOT possible - and what we do instead

**A draft email cannot live on a Lead.** `EmailMessage.Status = 5 (Draft)` is only valid
when `ParentId` is a Case: "For emails not sent as part of a case, only the status 3
(Sent) is valid." `RelatedToId` accepts 106 objects and Lead is not one of them. The Email
Drafts feature is Case Feed only.

*Instead:* the draft lives in `Omnishift_Draft_Body__c` (Long Text Area) and reaches the
standard Send Email composer through a Lightning email template. Stamp the sent message
`EmailMessage.AutomationType = AiAssisted`, a native Salesforce value meaning
"AI-generated, but sent by human".

**You cannot pre-fill the composer body declaratively.** Predefined field values on a Send
Email quick action support To/CC/BCC only, never Subject or Body.

**Flow's `emailSimple` action cannot be used for review-then-send.** It sends immediately
and documents "Outputs: None" - there is nothing to review and no ID to log.

**Record-triggered flows cannot call out during save.** "Salesforce prevents callouts to
external services from running while a record is saving." Feedback must be written as a
record and collected by polling, or pushed on an async path.

## Constraints that shape the design

**Writing 200k rows to Lead is the real risk, not API limits.** A bulk write executes in
1,000 transaction chunks of 200, each firing every trigger, flow, workflow rule and
validation rule on the object. A full nightly run costs only ~150 API calls against an
Enterprise allocation of 100,000 + 1,000 per licence. Put the nightly scoring write on a
custom object with no automation; keep only a few delta-written fields on Lead.

**Bulk job cap is 150 MB.** With a drafted email on each row, 200k rows is roughly 400 MB,
so the run splits into 4-5 jobs.

**Never write `OwnerId` in bulk.** Ownership changes force sharing recalculation across the
role hierarchy. `Omnishift_Recommended_Owner__c` is advisory; a human accepts it.

**A per-user dashboard tile needs a dynamic dashboard**, and Enterprise allows five in the
whole org. They also cannot be scheduled or subscribed to. A List View filtered to
Owner = Me has none of those ceilings.

**Person accounts.** "You must make any and all changes to a person account through the
account, not the contact." The panel now detects a person contact and refuses the write.

**Financial Services Cloud, if present.** `FinServ__LeadTrigger` fires on all four Lead DML
events with cross-object fan-out. Bulk loads need rollups disabled and serial mode.

**Button valence.** Salesforce publishes this as an anti-pattern: "'send' or 'submit' are
the same color as 'edit' or 'regenerate'" - specifically so users do not send AI-generated
content unread. All action buttons now carry equal weight.

## Needs a real org to settle

1. Does a Long Text Area work as a merge field in a Lightning email template, and do its
   line breaks survive into the HTML body? Nothing documents this either way, and the whole
   drafted-email flow depends on it.
2. Does this org have Financial Services Cloud or Person Accounts?
3. What automation already exists on Lead, and what is its CPU time on a 200-record update?

## Logging the send (verified in the Dev org, 2 Sep 2026)

`EmailMessage` looked like the natural place to record an approved draft, but
two constraints rule it out for this use case:

- `EmailMessage.Status = 'Draft'` is only permitted when the record hangs off a
  Case. The Growth Agent works Leads and Contacts, so there is no Case to
  parent it to.
- `EmailMessage.RelatedToId` does not accept a Lead id at all.

`Task` has neither problem. `Task.WhoId` takes both Lead and Contact ids, which
is exactly the pair the agent works, so `OmnishiftAction` logs a completed Task
with `Type = 'Email'` (or `'Call'`) as the audit record. The description records
whether the advisor sent the draft as written or edited it first, which is the
distinction compliance actually cares about.

One org quirk worth knowing before the TMG deployment: `Task.Type` is not
readable over SOQL in this Dev org because no permission set grants FLS on it.
Apex DML does not enforce field-level security, so the write succeeds and the
value is stored, but any report or list view that surfaces `Type` will need the
field exposed first.

## Deployment ordering (hit during the Dev org build)

A scheduled job holds a lock on its Schedulable class and every class that
class depends on. Once `OmnishiftEngineSchedule` was scheduled, redeploying
`OmnishiftEngine` failed with "This schedulable class has jobs pending or in
progress". The batch job in flight blocked it the same way.

For TMG this means the release order is: abort the schedule, deploy, reschedule.
The alternative is enabling "Allow deployments of components when corresponding
Apex jobs are pending or in progress" in Deployment Settings, which is fine for
a sandbox but worth a conversation before turning on in production.

## Who is eligible to own a recommendation

`UserType = 'Standard'` is not a filter for "advisor". It also matches the
platform accounts - Security User, Integration User, the org's automation user -
and the first routing run duly assigned prospects to them. The pool is now the
set of users holding the `Omnishift_Growth_Agent_User` permission set, which
makes eligibility something TMG administers rather than something the code
guesses at.
