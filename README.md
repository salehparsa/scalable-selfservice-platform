# scalable-selfservice-platform

Self-service platform where each product team gets an isolated IAM role and its own
S3 buckets, from one Terraform module. Onboarding team #301 changes no platform code:
it adds one name to `teams.yaml` and one generated folder.

```
bootstrap/                      one-time, applied by an admin: state bucket + CI identity
modules/team_infrastructure/    the platform module (buckets + team role)
live/root.hcl                   shared Terragrunt config: backend, provider, team.yaml -> inputs
live/team-<name>/terragrunt.hcl generated, identical for every team (never edited)
live/team-<name>/team.yaml      the only file a team edits
teams.yaml                      registry of team names
scripts/                        sync-teams, changed-teams, run-teams, offboard-team, authorize-destroy
.github/workflows/               checks, plan, deploy, offboard
```

- **State isolation:** each team has its own state file,
  `s3://<prefix>-tfstate-<account>/team-<name>/terraform.tfstate`, with its own S3 lock file.
- **Access isolation:** each team role can only reach its own buckets. Its IAM policy
  names only those bucket ARNs, and each bucket policy denies object access to every
  other principal.

## Onboarding a team

1. Add the name to `teams.yaml`.
2. Run `make teams`. It creates `live/team-<name>/` with the generated `terragrunt.hcl` and a
   starter `team.yaml`.
3. Fill in `team.yaml` (owner, cost center, buckets with explicit `public`/`private`
   visibility) and open a PR. **plan** shows the plan for that team only. Merging it
   **deploys** the team automatically.

## CI/CD

Four workflows, split by what they are allowed to do:

| Workflow | Trigger | What it does | AWS |
|---|---|---|---|
| **checks** (`checks.yml`) | every PR and push to `main` | Non-Terraform checks: `make check-teams`, change-detection tests (`make test-ci`), shellcheck, actionlint | no |
| **plan** (`plan.yml`) | pull requests | `make validate`, module tests (`make test-module`), change detection, `terragrunt plan` per changed team, `plan -destroy` per team removed from `teams.yaml` | read only |
| **deploy** (`deploy.yml`) | push to `main` (automatic); *Run workflow* re-applies every team | `make validate`, module tests, change detection, `terragrunt apply` per changed team. **Never destroys.** | yes |
| **offboard** (`offboard.yml`) | manual only (*Run workflow*) | Approver gate, destroy of one team, then a bot PR deleting its folder | yes |

Destroying lives in its own workflow on purpose, as a safety net: no merge or deploy can
ever remove a team's resources. Only an approver running **offboard** can.

> **Side note: why not GitHub's own reviewer approval?**
> The natural choice is a GitHub environment with *Required reviewers*: the destroy job would
> pause until a named reviewer clicks *Approve*. This repository is kept **private** on the
> GitHub **Free** plan, and there environments exist but have no protection rules, so required
> reviewers aren't available. They need GitHub Pro/Team, or a public repository. The manual
> *Run workflow* plus `scripts/authorize-destroy.sh` stands in for it. Once reviewers are
> available, add them to the `offboarding` environment, which **offboard** already uses; no
> code change is needed.

### How the pipeline knows what changed

`scripts/changed-teams.sh <base> <head>` compares two commits. The shared
`.github/actions/detect-changes` action runs it in **plan** and **deploy** and writes the
result to the job summary:

- **plan** compares with the PR base.
- **deploy** compares with the commit of the last *successful* **deploy** run, read from the
  Actions history (`gh run list`). No tag or extra state is stored. So:
  - A failed deploy is retried by the next merge.
  - If GitHub replaces a queued deploy with a newer one, the newer one still covers its changes.
  - With no successful deploy yet, every team is selected.
  - Running **deploy** manually (*Run workflow*) re-applies every team, e.g. after fixing a
    failure or enabling `AWS_CI_ENABLED`.

| Change | What runs |
|---|---|
| A team edits files under `live/team-<name>/` | plan (PR) / apply (merge) for **that team only** |
| Name added to `teams.yaml` | plan / apply for the new team |
| `modules/`, `live/root.hcl`, `.terraform-version`, `.terragrunt-version` | plan / apply for **every** team |
| Name removed from `teams.yaml` | `plan -destroy` on the PR; after merge, the summary asks an approver to run **offboard** |
| Anything else (docs, README) | nothing |

The selected teams become a matrix, one job per team. Beyond 200 teams several teams share
a job, so a platform-wide change stays under GitHub's 256-job matrix limit. Run
`make changed-teams BASE=origin/main` to see locally what CI would select.

AWS jobs run only when the repository variable `AWS_CI_ENABLED` is `true`. Without it,
**checks** and the validation and change-detection jobs still run.

### Offboarding

1. **Open a PR** that removes the team from `teams.yaml`. Leave `live/team-<name>/`, because the
   destroy needs its config. `make check-teams` reports the folder as *pending offboarding*,
   and **plan** shows every resource that will be deleted.
2. **Merge.** **deploy** applies nothing for the removed team and its summary lists it as
   pending offboarding.
3. **Run offboard:** *Actions → offboard → Run workflow* on `main`, and type the team name in
   both boxes (**team** and **confirm**). The `authorize` job refuses the run unless all of these hold:
   - you are in `DESTROY_APPROVERS`
   - the two names match
   - the team is no longer in `teams.yaml`
   - its folder still exists

   Then `destroy` runs `scripts/offboard-team.sh`:
   1. Sets `force_destroy` on the team's buckets.
   2. Destroys everything (buckets are emptied, including all versions).
   3. Checks the state is empty, then deletes the state file. It stays recoverable as a
      noncurrent version for 90 days.
4. **Merge the bot's PR.** `cleanup-pr` opens *chore: remove offboarded team <name>*, which
   deletes the folder. Merging it triggers no apply.

The offboarding safety checks are listed under [Guard rails](#offboarding-safety).

### AWS authentication

Static access keys of the `github-ci` IAM user (created by `bootstrap/`) are stored as GitHub
secrets. That user can only assume `github-ci-terraform-role`, which holds the Terraform
permissions and returns 1-hour credentials. OIDC is the better option, but this free-tier account
has no GitHub OIDC identity provider. See `bootstrap/README.md` for the migration path.

## Guard rails

Every rule below is enforced in code. The "Where" column says which check fails first. The
module's rules are covered by its tests (see [Testing](#testing)).

### Team configuration

| Rule | Where |
|---|---|
| Team names are 1-15 chars (`a-z`, `0-9`, `-`, not starting/ending with `-`), unique, and not reserved (`tfstate`, `github`, `ci`, `admin`, `platform`, `root`) | `make check-teams`, module |
| Every name in `teams.yaml` has a folder, and every generated `terragrunt.hcl` is unmodified | `make check-teams` |
| `team.yaml` must set `owner`, `cost_center`, at least one bucket, `trusted_principal_arns` and `tags.ManagedBy: terraform` | module |
| Every bucket declares `visibility: public` or `private`. There is no default, so a missing or other value fails | module |
| Bucket suffixes are unique per team, 1-14 chars; the full bucket name must fit S3's 63-char limit | module |
| Trusted principals must be `:root`, `:role/…` or `:user/…` ARNs. Wildcards, unresolved placeholders and other accounts' `:root` are rejected | module |
| `team.yaml` can only set the fields mapped in `live/root.hcl`. It cannot change `name_prefix`, `team_name` (taken from the folder) or `force_destroy` | `live/root.hcl` |
| Platform tags (`Team`, `Owner`, `CostCenter`, `ManagedBy`, `Project`) always override team tags | module |

### Access

| Rule | Where |
|---|---|
| A team role's IAM policy names only that team's bucket ARNs, and it has no `DeleteObjectVersion`, so teams can't permanently delete versioned data | module (`iam.tf`) |
| Each bucket policy denies object read/write/delete to every principal except the team role. Public buckets keep anonymous reads only | module (`s3.tf`) |
| Non-TLS requests are denied on every bucket; ACLs are disabled; private buckets block all public access | module (`s3.tf`) |
| The CI role can only manage `example-name-gmbh-*` buckets, `-role`s and `-policy`s. It can only attach team policies, can't modify its own identity, and can't change or delete the state bucket | `bootstrap/ci.tf` |
| The `github-ci` user's keys can only assume the CI role | `bootstrap/ci.tf` |

### Pipeline

| Rule | Where |
|---|---|
| Destroys only happen in **offboard**, which only runs manually. **plan** and **deploy** can never destroy a team | workflows |
| **plan** and **deploy** run `make validate` before any AWS job; **checks** runs the script tests and lint on every PR and push | workflows |
| A team only plans or applies when its own folder or the platform code changed (see the change-detection table) | `changed-teams.sh` |
| Team folder names are validated before use and only passed to the shell through `env:`, so a folder like `team-$(cmd)` is rejected, never executed | `changed-teams.sh`, workflows |
| One **deploy** runs at a time and is never cancelled; a deploy only counts as the new baseline when every apply in it succeeded | `deploy.yml` |
| Each team's S3 lock file serialises overlapping runs on the same team (10-minute lock timeout) | `live/root.hcl`, `run-teams.sh` |
| AWS jobs are skipped unless `AWS_CI_ENABLED` is `true`; PRs from forks never receive secrets | workflows, GitHub |
| Actions are pinned to commit SHAs, Terragrunt is checksum-verified, and the default token is read-only. Only **offboard**'s `cleanup-pr` gets write access | workflows, `setup-tools` |
| `bootstrap/` is never applied by CI | workflows |

### Offboarding safety

| Rule | Where |
|---|---|
| **offboard** must run from `main` and be started (or re-run) by a login in `DESTROY_APPROVERS`. Matching is exact and case-insensitive; an unset variable denies everyone | `authorize-destroy.sh` |
| The team name must be typed twice (**team** and **confirm**) and both must match exactly, so a typo can't destroy the wrong team | `authorize-destroy.sh` |
| A team that is still in `teams.yaml` is never destroyed: removing it needs a reviewed, merged PR first | `authorize-destroy.sh`, `offboard-team.sh` |
| A team's folder must stay until it has been destroyed. A PR that removes the name and deletes the folder together fails **plan** | `changed-teams.sh` |
| At most 3 teams can be removed in one PR (`MAX_OFFBOARD`), so an accidental edit to `teams.yaml` can't queue a mass destroy | `changed-teams.sh` |
| One team per **offboard** run, and only one run at a time | `offboard.yml` |
| `force_destroy` is only set during offboarding. A normal apply that removes a bucket from `team.yaml` fails while the bucket holds data | `live/root.hcl`, `offboard-team.sh` |
| The state file is only deleted after the state is confirmed empty, and it stays recoverable for 90 days | `offboard-team.sh`, bootstrap lifecycle rule |
| The folder is removed by a bot PR, never by a direct push | `cleanup-pr` job |

**Limitation of the Free-plan gate:** the approver list lives in workflow code, not in
GitHub's settings. Anyone with write access could run a modified copy of the workflow from
their own branch, and that copy would get the AWS secrets. Keep write access limited to the
approvers. On GitHub Pro/Team (or a public repository), add *Required reviewers* to the
`offboarding` environment for a gate enforced by GitHub itself.

## One-time GitHub setup

All of this is under the repository's **Settings**.

1. **Secrets** (*Secrets and variables → Actions → Secrets*): `AWS_ACCESS_KEY_ID`,
   `AWS_SECRET_ACCESS_KEY`. This is the `github-ci` user's access key; create it in the IAM console
   and paste it straight into GitHub.
2. **Variables** (*Secrets and variables → Actions → Variables*):

   | Name | Value |
   |---|---|
   | `AWS_CI_ROLE_ARN` | output of `cd bootstrap && terraform output -raw ci_role_arn` |
   | `AWS_REGION` | `eu-north-1` |
   | `AWS_CI_ENABLED` | `true` (unset or anything else skips all AWS jobs) |
   | `DESTROY_APPROVERS` | `salehparsa` (comma-separated GitHub logins allowed to run **offboard**) |

3. **Environments** (*Environments → New environment*): create `production` and
   `offboarding`. **deploy** and **offboard** declare them, so every apply and destroy shows up
   in the environment's deployment history. On this private Free-plan repository they have no
   protection rules. If the repository later moves to GitHub Pro/Team or becomes public, add
   *Required reviewers* to `offboarding`. No workflow change is needed.
4. **Actions** (*Actions → General → Workflow permissions*): keep *Read repository contents*,
   and tick *Allow GitHub Actions to create and approve pull requests* (used by `cleanup-pr`).
5. **Bootstrap** (outside GitHub, once): after pulling changes to `bootstrap/`, re-run
   `cd bootstrap && terraform apply` with admin credentials. CI never applies it. The current
   version adds `s3:DeleteObjectVersion` on team buckets, which offboarding needs.

## Testing

Nothing here needs AWS credentials. Run everything with `make test`.

### The module (`make test-module`)

`modules/team_infrastructure/tests/team_infrastructure.tftest.hcl` uses Terraform's built-in
[`terraform test`](https://developer.hashicorp.com/terraform/language/tests). Every `run` is a
`plan`, so nothing is created:

- **Fake credentials:** the AWS provider gets dummy keys, with credential and account checks switched off.
- **Overridden account data:** `override_data` pins the account ID and partition, so names are predictable.
- **Real IAM policies:** the provider still builds the IAM policy JSON locally, so the tests assert on
  the real policies.

| Covered | Runs |
|---|---|
| Naming convention for buckets, role and policy | `names_follow_the_convention` |
| Private buckets block all public access; public buckets allow only a policy-based public read | `private_bucket_blocks_everything`, `public_bucket_allows_policy_read_only` |
| Every bucket denies non-TLS access and object access by anyone but the team role | `every_bucket_denies_non_tls_and_other_principals` |
| The team policy names only the team's own buckets and can't delete object versions | `team_policy_only_names_own_buckets` |
| Platform tags win over team tags; `force_destroy` is off by default | `platform_tags_cannot_be_overridden`, `force_destroy_is_off_by_default` |
| Invalid input is rejected: visibility, duplicate or no buckets, bad or reserved team names, wildcard or foreign-root trust, missing `ManagedBy`, bucket names over 63 chars | `rejects_*` (`expect_failures`) |

```sh
make test-module
# or directly, from the module:
cd modules/team_infrastructure
terraform init -backend=false
terraform test                        # all runs
terraform test -filter=tests/team_infrastructure.tftest.hcl -verbose
```

To add a case, add a `run` block to the test file. Use `assert` for expected behaviour, or
`expect_failures = [var.<name>]` for input that must be rejected.

Omitting `visibility` entirely is a type error, not a validation failure, so `expect_failures`
can't capture it. It's checked by hand: `terragrunt plan` on a `team.yaml` without it fails.

**Not covered: real-AWS integration.** Proving isolation end to end, e.g. that team A's role
gets `AccessDenied` on team B's bucket, needs real resources. That's the job for
[Terratest](https://terratest.gruntwork.io/) (Go), or for `terraform test` with
`command = apply` against a sandbox account. It isn't included, to avoid cost and a Go
toolchain in this project.

### The pipeline (`make test-ci`)

`tests/ci/test-changed-teams.sh` checks `scripts/changed-teams.sh`, the logic that decides
which teams CI plans, applies or reports for destroy. Each case builds a throwaway git repo:
- a team edits its own file
- a module change
- a docs-only change
- a team is added
- a team is removed
- a team is removed together with its folder, which is rejected
- a malicious folder name, which is rejected
- 250 teams stay within the matrix limit

## Local commands

```sh
make help            # list targets
make teams           # create/refresh team folders from teams.yaml
make validate        # offline checks (no AWS)
make test            # module tests + change-detection tests (no AWS)
make lint            # shellcheck + actionlint (brew install shellcheck actionlint)
make plan TEAM=alpha # plan one team (needs AWS credentials)
```

Deploys need no command: merging to `main` runs **deploy**. To destroy a team, follow
[Offboarding](#offboarding).
