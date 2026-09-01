/** Nightly scheduler. System.schedule('Growth Agent', '0 0 2 * * ?', new OmnishiftEngineSchedule()); */
global with sharing class OmnishiftEngineSchedule implements Schedulable {
    global void execute(SchedulableContext sc) {
        Database.executeBatch(new OmnishiftEngineBatch(), 200);
    }
}
