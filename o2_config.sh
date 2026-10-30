#!/bin/bash
# ==============================================================================
# o2_config.sh
# Central configuration for all O2Physics scripts.
#
# SECURITY:
#   This file contains your GitHub token — keep it private:
#     chmod 600 ~/alice/o2_config.sh
#   Never commit to any git repository:
#     echo "o2_config.sh" >> ~/alice/.gitignore
#
# Directory layout:
#
#   Local machine ($O2_LOCAL_DIR = ~/alice):
#     ~/alice/
#     ├── o2.sh                     ← main control script (in PATH via o2rc)
#     ├── o2_config.sh              ← this file (never synced to HPC)
#     ├── o2rc                      ← shell integration (source in ~/.bashrc)
#     ├── get_aod.sh                ← runs inside container (synced to HPC)
#     ├── lib/                      ← internal modules (synced to HPC)
#     │   ├── common.sh
#     │   ├── build.sh
#     │   ├── run.sh
#     │   ├── merge.sh
#     │   ├── status.sh
#     │   └── deploy.sh
#     ├── logs/
#     ├── sandbox/
#     ├── sw/
#     ├── tmp/
#     ├── fakehome/
#     └── analysis/
#         └── proxies/
#             ├── config_input.sh
#             ├── config_tasks.sh
#             ├── dpl-config.json
#             ├── workflows.yml
#             ├── bookkeeping/
#             └── code/Tasks/
#
#   HPC cluster ($O2_HPC_HOME_DIR, small quota, backed up):
#     ~/alice/
#     ├── o2.sh
#     ├── o2_config.sh              ← sanitized (no GitHub token)
#     ├── o2rc
#     ├── get_aod.sh
#     ├── lib/
#     ├── logs/
#     └── analysis/
#         └── proxies/
#             ├── config_input.sh
#             ├── config_tasks.sh
#             ├── dpl-config.json
#             ├── workflows.yml
#             └── bookkeeping/
#
#   HPC scratch ($O2_HPC_SCRATCH_DIR, large quota, NOT backed up):
#     ├── sandbox/
#     ├── sw/
#     ├── tmp/
#     ├── fakehome/
#     ├── data/
#     └── analysis/
#         └── proxies/
#             └── output/
#                 └── LHC24aj/
#                     ├── group_000/
#                     │   ├── AnalysisResults.root
#                     │   └── filelist.txt
#                     ├── merge/
#                     │   └── AnalysisResults.root
#                     └── status.json
# ==============================================================================

O2_AUTHOR="Guernane"
O2_EMAIL="guernane@lpsc.in2p3.fr"

# ------------------------------------------------------------------------------
# Local machine
# ------------------------------------------------------------------------------
O2_LOCAL_DIR="$HOME/alice"

# ------------------------------------------------------------------------------
# GitHub — fork management (local machine only)
# Fine-grained token: Contents (read/write) + Metadata (read-only)
# Create at: GitHub → Settings → Developer settings → Fine-grained tokens
# ------------------------------------------------------------------------------
O2_GITHUB_USER="guernane"
# Read from ~/.o2_github_token (workstation only, chmod 600). ONE line on purpose:
# lib/deploy.sh blanks every line starting with "O2_GITHUB_TOKEN=" in the config
# it ships to the HPC. Never fatal here (every o2 command sources this file,
# including on the HPC, where the file does not exist): the presence check is
# in _github_api (lib/build.sh), where the token is actually used.
O2_GITHUB_TOKEN=$(cat ~/.o2_github_token 2>/dev/null || true)
O2_DEV_BRANCH="dev"
O2_PHYSICS_COMPONENTS="PWGJE/Tasks"

# ------------------------------------------------------------------------------
# HPC cluster paths
# ------------------------------------------------------------------------------
O2_HPC_HOME_DIR="/home/guernanr/alice"
O2_HPC_SCRATCH_DIR="/bettik/guernanr/alice"

# Set automatically to 1 in the sanitized HPC config — do not change
O2_FORCE_HPC=0

# ------------------------------------------------------------------------------
# Apptainer / aliBuild
# ------------------------------------------------------------------------------
O2_SANDBOX_NAME="sandbox"
O2_DEF_FILE_NAME="alice_o2.def"
O2_PHYSICS_VERSION="O2Physics@master"
O2_ALIBUILD_DEFAULTS="o2"
O2_MEM_PER_JOB=4       # GB of RAM reserved per parallel build job
O2_SHM_MIN_GB=16        # minimum /dev/shm size to use it as TMPDIR

# "sudo"  : sandbox built with root (local machine default)
# ""      : rootless mode (HPC — set automatically in sanitized config)
O2_APPTAINER_SUDO="sudo"

# ------------------------------------------------------------------------------
# Data and analysis
# ------------------------------------------------------------------------------
O2_DATA_MODE="local"    # "local" | "alien"
O2_GROUP_SIZE=10        # AO2D files per OAR job group
ALICE_CERN_USER="guernane"

# ------------------------------------------------------------------------------
# Documentation (o2 docs — local machine only)
# Builds one markdown file from the ALICE O2 analysis-framework documentation.
# ------------------------------------------------------------------------------
O2_DOCS_REPO="https://github.com/AliceO2Group/analysis-framework.git"
# Cache of the light clone (src/) and default output file (alice_o2_docs.md)
O2_DOCS_DIR="$O2_LOCAL_DIR/docs"
# Sections of the repository's docs/ directory to concatenate, in this order.
# 'datamodel' is ~4.5 MB of generated tables: drop it for a readable document
# (or use: o2 docs --exclude datamodel).
O2_DOCS_SECTIONS=(
    gettingstarted basics-tasks basics-usage analysis-tools hyperloop
    advanced-specifics tutorials faq tools troubleshooting datamodel glossary
)

# ------------------------------------------------------------------------------
# OAR (HPC cluster)
# ------------------------------------------------------------------------------
O2_OAR_PROJECT="pr-alice_hic_btagging"
O2_OAR_WALLTIME="06:00:00"
# Cores per group job. Empty = a whole node (/nodes=1). Never inferred from the
# login node. Set e.g. O2_OAR_CORES=16 to request a fixed number of cores.
O2_OAR_CORES=""
O2_OAR_TYPE=""  # set to a valid OAR 3 job type if needed (e.g. besteffort, deploy)
O2_OAR_DEVEL=0

# ------------------------------------------------------------------------------
# Deployment
# o2_config.sh is excluded — a sanitized version is generated automatically.
# ------------------------------------------------------------------------------
O2_HPC_USER="guernanr"
O2_HPC_HOST="dahu.ciment"

O2_DEPLOY_FILES=(
    "o2.sh"
    "o2rc"
    "get_aod.sh"
    "lib"
    "analysis"
)
