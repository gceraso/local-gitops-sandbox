# Private overlay

Anything specific to your employer, your accounts, or an unreleased project
belongs here rather than in the tracked tree. `private/` is gitignored, so it
cannot be pushed to this repository by accident.

## How it works

`push-gitea.sh` builds the Gitea repository in three passes:

1. copy `git_dir_skel/`
2. copy `$PRIVATE_DIR/git_dir_skel/` over the top
3. render `${VAR}` templates from `config.sh`

Because the overlay is copied second, it can add new paths or replace tracked
ones outright. Mirror the directory layout of `git_dir_skel/` and the file
lands where you expect.

## Getting started

```bash
mkdir -p private/git_dir_skel
cp -R examples/private-overlay/git_dir_skel/. private/git_dir_skel/
./push-gitea.sh
```

## Layout

```
private/
└── git_dir_skel/
    ├── app-of-apps/
    │   └── orchestration/
    │       └── my-thing.yaml          # picked up by the root app-of-apps
    └── workflows/
        └── my-thing/
            └── workflow-template.yaml
```

## Keeping identifiers out of the overlay too

The overlay is untracked, not encrypted, and it is easy to copy a file out of
it into somewhere tracked. Prefer parameters over literals even here:

- Put bucket names, account IDs and ARNs in `config.local.sh` (also
  gitignored), list the variable names in `EXTRA_RENDER_VARS`, and reference
  them as `${MY_BUCKET}` in the manifest:

  ```bash
  # config.local.sh
  MY_BUCKET="acme-prod-state-9f3a2b"
  MY_ACCOUNT="platform"
  EXTRA_RENDER_VARS="MY_BUCKET MY_ACCOUNT"
  ```

  Append to `EXTRA_RENDER_VARS`, not to `RENDER_VARS` — `config.local.sh` is
  sourced before `RENDER_VARS` is built, so appending there would clobber the
  base list.
- Keep credentials in Kubernetes Secrets, referenced by name. Use
  `./refresh-aws-creds.sh PROFILE` to populate one from an SSO session rather
  than writing keys into a manifest.

The included example follows both rules — read
`git_dir_skel/workflows/example-aws-job/workflow-template.yaml`.
