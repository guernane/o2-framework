#!/bin/bash
# ==============================================================================
# config_input.sh
# Input configuration for the "proxies" analysis workflow.
# Sourced by o2.sh before starting the analysis.
# Variables set here override the global defaults in o2_config.sh.
# CLI arguments always take precedence over these defaults.
# ==============================================================================

# ------------------------------------------------------------------------------
# Default production and runs
# Leave INPUT_PRODUCTION empty to require explicit --production on CLI.
# ------------------------------------------------------------------------------
INPUT_PRODUCTION="LHC25f3"

# Runs to process: comma-separated run numbers or "all"
INPUT_RUNS="544013"

# Maximum AO2D.root files per run (0 = no limit)
# Useful for quick tests before full production run
O2_MAX_FILES=2

# ------------------------------------------------------------------------------
# Data access mode (overrides O2_DATA_MODE from o2_config.sh)
# "local" : download AOD files to scratch before running
# "alien" : read directly from ALICE Grid via alien:// paths
# Comment out to use the global default.
# ------------------------------------------------------------------------------
O2_DATA_MODE="alien"

# ------------------------------------------------------------------------------
# Group size for this analysis (overrides O2_GROUP_SIZE from o2_config.sh)
# Tune based on expected walltime per file for this workflow.
# Comment out to use the global default.
# ------------------------------------------------------------------------------
# O2_GROUP_SIZE=10

# ------------------------------------------------------------------------------
# Metadata (informational — stored in bookkeeping)
# ------------------------------------------------------------------------------
INPUT_SYS="pp"      # collision system: "pp", "PbPb", "pPb"
INPUT_IS_MC=1       # 1 for MC simulation, 0 for real data
INPUT_RUN=3         # LHC Run number: 2, 3
