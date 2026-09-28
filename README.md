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
scripts/                        sync-teams, changed-teams, run-teams, offboard-team
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
   visibility) and open a PR. CI plans only that team. After merge, an allow-listed user
   runs the deploy, which applies it.

## CI/CD (`.github/workflows/terraform.yml`)

### Flow

| Event | What happens | Touches AWS |
|---|---|---|
| Pull request | static checks, then `plan` / `plan-destroy` for the teams the PR changes | read only |
| Merge (push to `main`) | static checks, and a job summary of what is **pending** since the last deploy | no |
| **Run workflow** (manual, `workflow_dispatch`) | the deploy: `authorize` → `apply` / `offboard` for everything since the last deploy → move the `deployed/main` tag | yes |

Merging never changes infrastructure; the approval step is a manual run by an allow-listed
user (see [Guard rails](#pipeline)). The `deployed/main` tag marks the last commit that
deployed successfully. A failed deploy leaves it in place, so the next run retries the same
teams.

> **Side note: why not GitHub's own reviewer approval?**
> The natural choice is GitHub environments with *Required reviewers*: the `apply` and
> `offboard` jobs would pause until a named reviewer clicks *Approve*. This repository is
> kept **private** on the GitHub **Free** plan, and there environments exist but have no
> protection rules, so required reviewers aren't available. They need GitHub Pro/Team, or a
> public repository. The manual *Run workflow* plus `scripts/authorize-deploy.sh` stands in
> for it. Once reviewers are available, add them to the `production` and `offboarding`
> environments; the workflow already uses both, so no code change is needed.

### How the pipeline knows what changed

`scripts/changed-teams.sh <base> <head>` compares two commits. The base is the PR base for
pull requests, and the `deployed/main` tag for merges and deploys (no tag yet selects
every team). The workflow only acts on its output:

| Change | What runs |
|---|---|
| A team edits files under `live/team-<name>/` | plan (PR) / apply (deploy) for **that team only** |
| Name added to `teams.yaml` | plan / apply for the new team |
| `modules/`, `live/root.hcl`, `.terraform-version`, `.terragrunt-version` | plan / apply for **every** team |
| Name removed from `teams.yaml` | plan-destroy (PR) / **offboarding** (deploy) for that team |
| Anything else (docs, README) | nothing |

The selected teams become a matrix, one job per team. Beyond 200 teams several teams share
a job, so a platform-wide change stays under GitHub's 256-job matrix limit. Run
`make changed-teams BASE=origin/main` to see locally what CI would select.

### Jobs

| Job | When | What it does |
|---|---|---|
| `static` | every run | `make validate` (teams in sync, `team.yaml` fields, fmt, module validate), `make test-ci`, shellcheck, actionlint. No AWS needed. |
| `changes` | every run | `changed-teams.sh`; writes the selection to the job summary |
| `plan` | PR | `terragrunt plan` per selected team, output in the job summary |
| `plan-destroy` | PR | `terragrunt plan -destroy` per removed team, so the reviewer sees what will be deleted |
| `authorize` | deploy | `scripts/authorize-deploy.sh`: the run must come from `main`, be started by a user in `DEPLOY_ALLOWED_ACTORS`, and have `allow_offboard` ticked if any team would be destroyed |
| `apply` | deploy, after `authorize` | applies per team; recorded as a deployment to the `production` environment |
| `offboard` | deploy, after `authorize` | destroys removed teams one at a time; recorded as a deployment to the `offboarding` environment |
| `mark-deployed` | deploy, if every apply/offboard succeeded | moves the `deployed/main` tag to the deployed commit |
| `cleanup-pr` | after a successful `offboard` | opens a PR deleting the offboarded `live/team-<name>/` folders |

The AWS jobs run only when the repository variable `AWS_CI_ENABLED` is `true`. Without
it, the static checks and change detection still run.

### Offboarding

1. **Open a PR** that removes the team from `teams.yaml`. Leave `live/team-<name>/`, because the
   destroy needs its config. `make check-teams` reports the folder as *pending offboarding*,
   and `plan-destroy` lists every resource that will be deleted.
2. **Merge, then deploy.** In *Actions → terraform → Run workflow*, tick **allow_offboard**
   and run it on `main`. Without the tick, `authorize` stops the run and lists the teams that
   would be destroyed. `offboard` then runs `scripts/offboard-team.sh` for each team:
   1. Sets `force_destroy` on the team's buckets.
   2. Destroys everything (buckets are emptied, including all versions).
   3. Checks the state is empty, then deletes the state file. It stays recoverable as a
      noncurrent version for 90 days.
3. **Merge the cleanup PR** that `cleanup-pr` opens. It deletes the folder and triggers no Terraform run.

The offboarding safety checks are listed under [Guard rails](#guard-rails).

### AWS authentication

Static access keys of the `github-ci` IAM user (created by `bootstrap/`) are stored as GitHub
secrets. That user can only assume `github-ci-terraform-role`, which holds the Terraform
permissions and returns 1-hour credentials. OIDC is the better option, but this free-tier account
has no GitHub OIDC identity provider. See `bootstrap/README.md` for the migration path.

## Guard rails

Every rule below is enforced in code. The "Where" column says which check fails first.

### Team configuration

| Rule | Where |
|---|---|
| Team names are 1-15 chars (`a-z`, `0-9`, `-`, not starting/ending with `-`), unique, and not reserved (`tfstate`, `github`, `ci`, `admin`, `platform`, `root`) | `make check-teams`, module |
| Every name in `teams.yaml` has a folder, and every generated `terragrunt.hcl` is unmodified | `make check-teams` |
| `team.yaml` must set `owner`, `cost_center`, at least one bucket, `trusted_principal_arns` and `tags.ManagedBy: terraform` | `make check-teams`, module |
| Every bucket declares `visibility: public` or `private`. There is no default, so a missing or other value fails | `make check-teams`, module |
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
| No AWS job runs unless `static` passes (validation, tests, lint) | workflow `needs:` |
| PRs only plan, and merging never touches AWS. Applies and destroys run only from a manual **Run workflow** | workflow |
| A deploy must run from `main` and be started (or re-run) by a login in `DEPLOY_ALLOWED_ACTORS`. Matching is exact and case-insensitive; an unset variable denies everyone | `authorize-deploy.sh` |
| Only one deploy runs at a time; the `deployed/main` tag moves only when every apply and offboard succeeded | workflow |
| A team only plans or applies when its own folder or the platform code changed (see the change-detection table) | `changed-teams.sh` |
| Team folder names are validated before use and only passed to the shell through `env:`, so a folder like `team-$(cmd)` is rejected, never executed | `changed-teams.sh`, workflow |
| AWS jobs are skipped unless `AWS_CI_ENABLED` is `true`; PRs from forks never receive secrets | workflow, GitHub |
| PR runs are superseded by newer pushes; `main` runs are never cancelled or dropped. Each team's S3 lock file serialises overlapping runs (10-minute lock timeout) | workflow, `live/root.hcl` |
| Actions are pinned to commit SHAs, Terragrunt is checksum-verified, and the default token is read-only. Only `mark-deployed` (the tag) and `cleanup-pr` get write access | workflow, `setup-tools` |
| `bootstrap/` is never applied by CI | workflow |

**Limitation of the Free-plan gate:** the allow-list lives in workflow code, not in GitHub's
settings. Anyone with write access could run a modified copy of the workflow from their own
branch, and that copy would get the AWS secrets. Keep write access limited to the allow-listed
users. On GitHub Pro/Team (or a public repository), add *Required reviewers* to the two
environments for a gate enforced by GitHub itself.

### Offboarding safety

| Rule | Where |
|---|---|
| A team's folder must stay until its destroy has run. Removing the name and deleting the folder in the same change is rejected | `changed-teams.sh` |
| At most 3 teams can be removed in one change (`MAX_OFFBOARD`), so an accidental edit to `teams.yaml` can't mass-destroy | `changed-teams.sh` |
| A team that is still in `teams.yaml` is never destroyed | `offboard-team.sh` |
| A deploy that would destroy any team is refused unless `allow_offboard` is ticked; the refusal lists the teams | `authorize-deploy.sh` |
| Destroys run one team at a time | workflow |
| `force_destroy` is only set during offboarding. A normal apply that removes a bucket from `team.yaml` fails while the bucket holds data | `live/root.hcl`, `offboard-team.sh` |
| The state file is only deleted after the state is confirmed empty, and it stays recoverable for 90 days | `offboard-team.sh`, bootstrap lifecycle rule |
| The folder is removed through a reviewed PR, never by a direct push | `cleanup-pr` job |

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
   | `DEPLOY_ALLOWED_ACTORS` | `salehparsa` (comma-separated GitHub logins allowed to run deploys) |

3. **Environments** (*Environments → New environment*): create `production` and
   `offboarding`. `apply` and `offboard` declare them, so every deploy shows up in the
   environment's deployment history. On this private Free-plan repository they have no
   protection rules; approval comes from the manual run and `authorize`. If the repository
   later moves to GitHub Pro/Team or becomes public, add *Required reviewers* to both for an
   extra gate. No workflow change is needed.
4. **Actions** (*Actions → General → Workflow permissions*): keep *Read repository contents*,
   and tick *Allow GitHub Actions to create and approve pull requests* (used by `cleanup-pr`).
5. **Bootstrap** (outside GitHub, once): after pulling changes to `bootstrap/`, re-run
   `cd bootstrap && terraform apply` with admin credentials. CI never applies it. The current
   version adds `s3:DeleteObjectVersion` on team buckets, which offboarding needs.

## Local commands

```sh
make help            # list targets
make teams           # create/refresh team folders from teams.yaml
make validate        # offline checks (no AWS)
make test-ci         # tests for the CI scripts (no AWS)
make lint            # shellcheck + actionlint (brew install shellcheck actionlint)
make plan TEAM=alpha # plan one team (needs AWS credentials)
```

To deploy: *Actions → terraform → Run workflow* on `main`. Tick *allow_offboard* only when
the run should destroy teams removed from `teams.yaml`.
