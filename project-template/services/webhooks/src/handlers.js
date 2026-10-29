// One function per GitHub event this service subscribes to. Payload shapes:
// https://docs.github.com/webhooks/webhook-events-and-payloads
// Keep handlers idempotent: GitHub can deliver the same event more than once.
export const handlers = {
  ping: ({ payload, log }) => {
    log.info('ping', { hook_id: payload.hook_id, zen: payload.zen });
  },

  push: ({ payload, log }) => {
    log.info('push', {
      repo: payload.repository?.full_name,
      ref: payload.ref,
      commits: payload.commits?.length ?? 0,
    });
    // e.g. start a preview build, sync docs, notify chat
  },

  pull_request: ({ payload, log }) => {
    log.info('pull_request', {
      repo: payload.repository?.full_name,
      action: payload.action,
      number: payload.number,
    });
    // e.g. on "opened": add labels, post a checklist, request reviewers
  },

  issues: ({ payload, log }) => {
    log.info('issues', {
      repo: payload.repository?.full_name,
      action: payload.action,
      number: payload.issue?.number,
    });
  },
};
