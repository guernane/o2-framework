# o2-framework

A command-line framework for managing O2Physics builds and analysis
workflows, both on a local workstation and on an HPC cluster (CIMENT /
`dahu.ciment`), for the ALICE PWGJE (jet physics) working group.

## Related repositories

| Repository | Purpose |
|---|---|
| [`guernane/o2-framework`](https://github.com/guernane/o2-framework) | This repository: build orchestration, workflow execution, HPC deployment |
| [`guernane/analyses`](https://github.com/guernane/analyses) | Analysis configuration and user task source code (PWGJE) |
| [`guernane/O2Physics`](https://github.com/guernane/O2Physics) | Fork of the ALICE O2Physics codebase (`dev` branch) |

Together, these three repositories constitute the complete, versioned state
of the project. Ephemeral build artefacts (compiled binaries, container
images, downloaded data) are deliberately excluded from version control and
are regenerated locally as described in [Section 4](#4-provisioning-a-new-machine).

---

## 1. Command reference

All commands are invoked through the `o2` entry point (a symlink to
`o2.sh`), made available in the shell via `o2rc` sourced from `~/.bashrc`.
Full usage for any command is available via `o2 help <command>`.

### 1.1 `o2 build`
Manages the O2Physics build: GitHub fork synchronisation, Apptainer sandbox
construction, aliBuild compilation, and incremental ninja rebuilds.
```bash
o2 build                       # incremental build
o2 build --rebuild-tasks       # sync user tasks (analyses/) and rebuild
o2 build --commit "message"    # commit and push the O2Physics fork
```

### 1.2 `o2 run`
Executes a DPL analysis workflow, either locally or on the HPC cluster.
```bash
o2 run <workflow> <production> [--runs <run_numbers>] [--mode alien|local]
o2 run test LHC25f3 --runs 544013
```

### 1.3 `o2 merge`
Merges `AnalysisResults.root` output across all completed job groups for a
given workflow and production.
```bash
o2 merge <workflow> <production>
```

### 1.4 `o2 status`
Reports the state of configured analyses, HPC job queues, and the validity
of the ALICE Grid authentication token.

### 1.5 `o2 deploy`
Synchronises the framework to the HPC cluster and, optionally, triggers a
remote build.
```bash
o2 deploy --sync-only     # synchronisation only
o2 deploy --build-only    # trigger remote build (assumes prior sync)
o2 deploy                 # both steps
```

### 1.6 `o2 analyses` *(local workstation only)*
Manages the analysis registry (`analyses/analyses.json`): enabling or
disabling individual analyses and their constituent tasks.
```bash
o2 analyses --list
o2 analyses --enable <workflow>
o2 analyses --disable <workflow>
```

### 1.7 `o2 sync` *(local workstation only)*
Verifies that the local O2Physics commit matches the commit deployed on the
HPC cluster, and reports the status of the most recent remote build.
```bash
o2 sync
```

### 1.8 `o2 backup` *(local workstation only)*
Commits and pushes outstanding local changes in `o2-framework` and
`analyses` to their respective GitHub repositories. `O2Physics` is
deliberately excluded, as its working copy is managed by aliBuild's
`MIRROR` alternate-object-path mechanism, which is incompatible with
generic external git operations; use `o2 build --commit` for that
repository instead.
```bash
o2 backup                    # auto-generated commit message (timestamp)
o2 backup "description of changes"
```

### 1.9 `o2 export` *(local workstation only, requires the GitHub CLI, `gh`)*
Produces a shareable snapshot of the project by cloning fresh copies of the
selected repositories directly from GitHub — guaranteeing that the export
reflects what is actually backed up, rather than the local working copy —
and bundling them into a single `.tar.gz` archive. This is primarily
intended for transferring the current state of the codebase to a
collaborator or an AI coding assistant without requiring direct repository
access.

Any file committed and pushed to GitHub is automatically included in
subsequent exports; no maintenance of this script is required when new
files are added to the tracked repositories.

```bash
o2 export                                          # default: O2Physics limited to PWGJE and Common
o2 export --repos "o2-framework,analyses"          # exclude O2Physics entirely
o2 export --o2physics-paths "PWGJE,PWGCF,Common"   # custom top-level subset
o2 export --o2physics-paths "ALL"                  # full O2Physics source
o2 export --analyses-paths "test"                  # a single workflow only
o2 export --keep-artifacts                         # retain output/ and bookkeeping/
o2 export ~/Desktop/snapshot.tar.gz                # custom output path
```

---

## 2. Directory layout

```
~/alice/
├── o2.sh, o2, o2rc, o2_config.sh, get_aod.sh, alice_o2.def   ← this repository
├── lib/                                                       ← this repository
├── analyses/            ← separate repository (guernane/analyses)
├── sw/O2Physics/         ← separate repository (guernane/O2Physics, fork)
├── sandbox/, sw/ (excl. O2Physics)   ← regenerated by `o2 build`
├── fakehome/             ← automatic mirror of ~/.globus; never version-controlled
├── data/, tmp/, logs/    ← regenerable or purgeable run artefacts
└── rescue/               ← safety net for rebuild conflicts
```

Files and directories outside version control are either (a) regenerable
build products, (b) transient run artefacts, or (c) machine-local secrets
(grid certificate, decrypted key). None of these should be committed to any
repository.

---

## 3. Known reproducibility limitations

- The initial commit of this repository contains the GitHub personal
  access token in plaintext, within `o2_config.sh`. Should this
  repository's visibility ever change from private to public, the token
  must be regenerated beforehand, or the git history rewritten.
- Synchronisation of `analyses/` to the HPC cluster currently requires an
  explicit `o2 deploy --sync-only` invocation; the cluster does not
  otherwise stay automatically consistent with the local working copy. An
  architectural revision (`o2 run --hpc`, eliminating the need for
  `analyses/` to reside on the cluster at all) is planned but not yet
  implemented.
- The OAR project allocation and HPC storage quota are administered by
  CIMENT and are not represented anywhere in this repository.

---

## 4. Provisioning a new machine

This section documents every step required to reproduce a fully functional
installation from an empty machine — that is, everything that is *not*
captured by version control, because it constitutes either a manual,
external, or credential-dependent procedure.

### 4.1 Local workstation

**Clone the repositories**
```bash
git clone git@github.com:guernane/o2-framework.git ~/alice
cd ~/alice
git clone git@github.com:guernane/analyses.git analyses
```

**Source the shell integration**
```bash
echo 'source ~/alice/o2rc' >> ~/.bashrc
source ~/.bashrc
```

**Generate a GitHub personal access token**
- Navigate to https://github.com/settings/personal-access-tokens
- Create a fine-grained token scoped to `Contents` (read/write) and
  `Metadata` (read-only) on the `guernane/O2Physics` repository
- Insert the resulting value into `~/alice/o2_config.sh` under
  `O2_GITHUB_TOKEN`
- This value must never be transcribed elsewhere; treat it as a credential
  at all times

**Obtain the ALICE Grid certificate**
- Follow the CERN Certificate Authority procedure described at
  https://alice-doc.github.io/alice-analysis-tutorial/
- Place `usercert.pem` and `userkey.pem` in `~/.globus/` — the user's
  actual home directory, *not* `~/alice/fakehome/.globus/`
- `~/alice/fakehome/.globus/` is an automatically managed mirror,
  regenerated from `~/.globus/` on every invocation (see `lib/common.sh`);
  it must never be populated manually, and its contents must not be
  treated as authoritative

**Build the sandbox and O2Physics**

A single command handles both the construction of the Apptainer sandbox
(from `alice_o2.def`, if not already present) and the subsequent aliBuild
compilation of O2Physics. This step is computationally expensive and may
take several hours.
```bash
cd ~/alice
o2 build
```

### 4.2 HPC cluster (CIMENT / dahu.ciment)

**Account and storage allocation**
Requesting a CIMENT account and access to the relevant OAR project
(currently `pr-alice_hic_btagging`) is an administrative procedure external
to this framework. Confirm the storage quota under
`/bettik/<user>/alice` before proceeding.

**Non-interactive SSH access from the workstation**
```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_dahu
ssh-copy-id -i ~/.ssh/id_ed25519_dahu.pub guernanr@dahu.ciment
```
Append to `~/.ssh/config` on the local workstation:
```
Host dahu.ciment
    User guernanr
    IdentityFile ~/.ssh/id_ed25519_dahu
```

**Deploy the framework to the cluster**

Note that this step, like all remote-facing operations, is initiated
*from the local workstation*; the cluster is never operated on directly
during routine use.
```bash
o2 deploy --sync-only
```

**Transfer the grid certificate to the cluster**
```bash
ssh guernanr@dahu.ciment mkdir -p ~/.globus
scp ~/.globus/usercert.pem ~/.globus/userkey.pem guernanr@dahu.ciment:~/.globus/
ssh guernanr@dahu.ciment chmod 400 ~/.globus/userkey.pem
```

**Decrypt the private key for non-interactive batch use**

OAR-submitted jobs execute without an interactive terminal and therefore
cannot supply a passphrase; the private key must be decrypted once, in
advance, on the cluster.
```bash
ssh guernanr@dahu.ciment
cd ~/.globus
openssl rsa -in userkey.pem -out userkey_nopass.pem   # passphrase requested once
chmod 400 userkey_nopass.pem
mv userkey.pem userkey_orig.pem.bak
mv userkey_nopass.pem userkey.pem
```
The resulting file is highly sensitive: its possession is equivalent to the
holder's grid identity. Verify that `~/.globus` carries `700` permissions
and that this file is never copied off the cluster.

**Trigger the remote build**

As with deployment, the build is triggered from the local workstation, not
by an interactive session on the login node.
```bash
o2 deploy --build-only
```

### 4.3 Verification
```bash
o2 sync                              # expect "IN SYNC"
o2 run test LHC25f3 --runs 544013    # end-to-end smoke test
```
