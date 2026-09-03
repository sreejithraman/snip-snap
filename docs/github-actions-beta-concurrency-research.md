# Beta workflow concurrency review

Reviewed on 2026-09-02 against the current local versions of `.github/workflows/beta-candidate.yml` and `.github/workflows/beta.yml`.

## Verdict

The split is idiomatic and fits the stated rule: cancel stale test work, but never stop a beta delivery after it starts. No blocking change is needed.

The two workflow-level concurrency groups do the right jobs:

- `beta-candidate-${{ github.ref }}` with `cancel-in-progress: true` keeps only the newest candidate for a ref and cancels an older running candidate. GitHub gives this concurrency group at most one running and one waiting run; a new waiting run replaces the old one. `cancel-in-progress: true` also cancels the running run. [GitHub: Control workflow concurrency](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency)
- `beta-publish-main` with `cancel-in-progress: false` lets one delivery finish while the newest waiting delivery replaces any older waiting delivery. This is the right setting for signing and publishing work that must not stop halfway. [GitHub: Control workflow concurrency](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency)

## `workflow_run` use

The handoff is correct:

- A `completed` `workflow_run` starts regardless of whether the candidate passed, so the job-level check for `github.event.workflow_run.conclusion == 'success'` follows GitHub's documented pattern. Failed and canceled candidates will create a short delivery run whose jobs are skipped; GitHub does not offer a conclusion filter in the trigger. [GitHub: Events that trigger workflows](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_run)
- The `branches: [main]` filter applies to the branch on which the candidate ran. It keeps a manual candidate run on another ref from starting delivery. [GitHub: Events that trigger workflows](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#limiting-your-workflow-to-run-based-on-branches)
- For `workflow_run`, `GITHUB_SHA` and `GITHUB_REF` point to the default branch, not necessarily the tested commit. Checking out `github.event.workflow_run.head_sha` is therefore the right way to rebuild the tested source. The extra comparison with live `refs/heads/main` keeps an older successful candidate from shipping. [GitHub: Events that trigger workflows](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_run)
- The delivery workflow must exist on the default branch before `workflow_run` can start it. This matters only for the first merge that adds this split. [GitHub: Events that trigger workflows](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_run)

## Security

The trust boundary is sound. GitHub warns that a `workflow_run` workflow can gain secrets and write access even when its caller cannot, and says not to run untrusted pull-request code in that workflow. Here, the candidate runs only for `main` pushes or a manual ref, and the delivery trigger narrows the branch to `main`. Delivery checks out that `main` candidate, compares it with live `main`, and runs no repo script unless they match. The candidate workflow has read-only token rights, while the jobs that use release secrets name the protected `apple-release` environment. [GitHub: Events that trigger workflows](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_run), [GitHub: Secure use reference](https://docs.github.com/en/actions/reference/security/secure-use#mitigating-the-risks-of-untrusted-code-checkout)

Environment protection rules run before a job starts, and environment secrets become available only after those rules pass. This makes the unprivileged `prepare` job a good place for the first stale-SHA check. [GitHub: Deployment environments](https://docs.github.com/en/actions/concepts/workflows-and-actions/deployment-environments)

Pinned full commit IDs for `actions/checkout`, `actions/upload-artifact`, and `actions/download-artifact` also follow GitHub's guidance for immutable action references. [GitHub: Secure use reference](https://docs.github.com/en/actions/reference/security/secure-use#using-third-party-actions)

## Edge cases and follow-up

The `prepare` job's live-`main` check is the chosen start boundary. A new push before that check makes the delivery skip. A push after it does not stop the delivery, even if protected signing has not begun. This keeps one clear commit point and honors the rule that an active delivery must finish.

Other known limits:

- A successful rerun or manual run of the candidate can start another delivery when its SHA still matches `main`. That is useful for recovery, but it can publish a new build from the same commit. GitHub notes that `requested` does not fire on a rerun; `completed` does. [GitHub: Events that trigger workflows](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_run)
- The candidate's `paths` filter is reasonable for avoiding a publish loop, but GitHub can miss a matching file when a generated diff exceeds 3,000 files and the match falls outside the first 3,000. This is a rare large-push limit. [GitHub: Workflow syntax, Git diff comparisons](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#git-diff-comparisons)
- GitHub does not promise dispatch order within a concurrency group. The live-main check makes that safe: an older delivery that starts late will skip. [GitHub: Control workflow concurrency](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency)

## Recommendation

Keep the split. The separate concurrency groups, current-commit gate, exact-SHA checkouts, protected release jobs, and two-run release evidence fit the stated rule.
