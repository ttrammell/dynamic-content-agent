// Lightweight user-confirmation gate for the dynamic-email build. It does nothing but return
// confirmed=true -- its only purpose is to carry require_user_confirmation so the Agentforce
// platform prompts the user to verify before the build proceeds. The agent script flips
// base_buildConfirmed from this output; the actual build then runs deterministically in
// after_reasoning from durable variables. Kept separate from BuildDynamicEmailAction so the
// verification and the (reliable, code-driven) build are cleanly decoupled.
public with sharing class ConfirmBuildAction {

    public class Request {
        // No inputs -- the plan is already assembled in durable agent-script variables.
        @InvocableVariable(label='Ignored')
        public String ignored;
    }

    public class Result {
        @InvocableVariable(label='Confirmed')
        public Boolean confirmed;
    }

    @InvocableMethod(label='Confirm Build' description='Final user confirmation before building the dynamic email. Returns confirmed=true; carries require_user_confirmation so the platform verifies with the user first.')
    public static List<Result> confirm(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result r = new Result();
            r.confirmed = true;
            results.add(r);
        }
        return results;
    }
}
