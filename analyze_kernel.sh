#!/bin/bash

# ==============================================================================
# Script Name: analyze_kernel.sh
# Description: A unified script to automate the entire CodeQL database creation
#              process for Linux kernel vulnerability analysis. It handles checking
#              out code, configuring the kernel, and creating the database.
#
# Usage: ./analyze_kernel.sh <ver> <commit> <cve> <db_path> <mode> <target> [config]
#
# Arguments:
#   <ver>:    Version choice.
#             '1' for the version BEFORE the fix (commit~1).
#             '2' for the version AFTER the fix (the commit itself).
#
#   <commit>: The full hash of the commit that FIXED the vulnerability.
#
#   <cve>:    The CVE identifier (e.g., CVE-2025-38245). Used for naming.
#
#   <db_path>: The base directory to store the generated database.
#
#   <mode>:   Build mode selection.
#             '1' for Build Mode (compiles the target).
#             '2' for No-Build Mode (analyzes source directly).
#
#   <target>: The analysis target's relative path.
#             - For Mode 1: A .c file, .o file, or module directory.
#             - For Mode 2: A source directory.
#
#   [config]: (Required for Mode 1, Ignored for Mode 2) The kernel CONFIG
#             option to enable (e.g., CONFIG_ATM).
#
# --- Naming Convention ---
#   - Mode 1, Ver 1 (Before Fix): db_YYYY_NNNNN
#   - Mode 1, Ver 2 (After Fix):  db_YYYY_NNNNN_fixed
#   - Mode 2, Ver 1 (Before Fix): db_YYYY_NNNNN_none
#   - Mode 2, Ver 2 (After Fix):  db_YYYY_NNNNN_none_fixed
# ==============================================================================

# Exit immediately if a command exits with a non-zero status.
set -e

# --- 1. Argument Validation ---
if [ "$#" -lt 6 ]; then
    echo "Error: Incorrect number of arguments."
    echo "Usage: $0 <ver> <commit> <cve> <db_path> <mode> <target> [config]"
    exit 1
fi

if ! command -v codeql &> /dev/null; then
    echo "Error: 'codeql' command not found. Please ensure CodeQL is installed and configured in your PATH."
    exit 1
fi

VERSION_CHOICE=$1
COMMIT_HASH=$2
CVE_NAME=$3
DB_BASE_PATH=$4
BUILD_MODE=$5
TARGET_PATH=$6
CONFIG_OPTION=$7

if [[ "$VERSION_CHOICE" != "1" && "$VERSION_CHOICE" != "2" ]]; then
    echo "Error: Invalid version choice '$VERSION_CHOICE'. Must be '1' (before fix) or '2' (after fix)."
    exit 1
fi

if [[ "$BUILD_MODE" != "1" && "$BUILD_MODE" != "2" ]]; then
    echo "Error: Invalid build mode '$BUILD_MODE'. Must be '1' (Build) or '2' (No-Build)."
    exit 1
fi

if [[ "$BUILD_MODE" == "1" && -z "$CONFIG_OPTION" ]]; then
    echo "Error: The [config] argument is required for Build Mode (Mode 1)."
    exit 1
fi

# --- 2. Environment & Naming Setup ---

# Determine target commit
if [ "$VERSION_CHOICE" -eq 1 ]; then
    TARGET_COMMIT="${COMMIT_HASH}~1"
else
    TARGET_COMMIT="${COMMIT_HASH}"
fi

# Format CVE string for the database name
DB_NAME_SUFFIX=$(echo "${CVE_NAME}" | sed -E 's/^cve-//i' | sed 's/-/_/g')

# Determine final database name based on all options
DB_NAME="db_${DB_NAME_SUFFIX}"
if [ "$BUILD_MODE" -eq 2 ]; then
    DB_NAME+="_none"
fi
if [ "$VERSION_CHOICE" -eq 2 ]; then
    DB_NAME+="_fixed"
fi
DB_FULL_PATH="${DB_BASE_PATH}/${DB_NAME}"

echo "=================================================="
echo "Starting Kernel Analysis Workflow"
echo "  CVE Name:          ${CVE_NAME}"
echo "  Fix Commit:        ${COMMIT_HASH}"
echo "  Target Commit:     ${TARGET_COMMIT}"
echo "  Database Path:     ${DB_FULL_PATH}"
echo "=================================================="

# --- 3. Code Checkout & Kernel Prep ---
echo "Step 1/3: Checking out target commit..."
git checkout ${TARGET_COMMIT}

if [ "$BUILD_MODE" -eq 1 ]; then
    echo "\nStep 2/3: Preparing kernel for build..."
    echo "  - Cleaning environment (make mrproper)..."
    make mrproper >/dev/null 2>&1
    echo "  - Generating default config (make defconfig)..."
    make defconfig >/dev/null 2>&1
    echo "  - Enabling specified config: ${CONFIG_OPTION}..."
    ./scripts/config --enable ${CONFIG_OPTION}
    echo "Kernel preparation complete."
else
    echo "\nStep 2/3: Skipping kernel build preparation (No-Build Mode)."
fi


# --- 4. CodeQL Database Creation ---
echo "\nStep 3/3: Creating CodeQL database..."

if [ "$BUILD_MODE" -eq 1 ]; then
    # --- Mode 1: Build Mode ---
    echo "  Mode: Build Mode"
    
    if [[ "${TARGET_PATH}" == *.c ]]; then
        TARGET_OBJECT="${TARGET_PATH%.c}.o"
        MAKE_COMMAND="make LLVM=1 ${TARGET_OBJECT}"
        echo "  Info: Converted input '${TARGET_PATH}' to build target '${TARGET_OBJECT}'"
    elif [[ "${TARGET_PATH}" == *.o ]]; then
        MAKE_COMMAND="make LLVM=1 ${TARGET_PATH}"
    else
        TARGET_DIR=$(echo "${TARGET_PATH}" | sed 's:/*$::')/
        MAKE_COMMAND="make LLVM=1 M=${TARGET_DIR}"
    fi
    echo "  Build Command:     ${MAKE_COMMAND}"
    COMMAND_TO_RUN=(codeql database create --overwrite "${DB_FULL_PATH}" --language=cpp --command="${MAKE_COMMAND}")

else
    # --- Mode 2: No-Build Mode ---
    echo "  Mode: No-Build Mode"
    KERNEL_ROOT=$(pwd)
    SOURCE_ROOT_ABS="${KERNEL_ROOT}/${TARGET_PATH}"

    if [ ! -d "${SOURCE_ROOT_ABS}" ]; then
        echo "Error: The specified source directory does not exist: ${SOURCE_ROOT_ABS}"
        exit 1
    fi
    echo "  Source Directory:  ${SOURCE_ROOT_ABS}"
    COMMAND_TO_RUN=(codeql database create --overwrite "${DB_FULL_PATH}" --language=cpp --source-root="${SOURCE_ROOT_ABS}" --build-mode=none)
fi

# Execute the final constructed command
echo "  Executing CodeQL command..."
"${COMMAND_TO_RUN[@]}"

# Check the exit code of the last command
if [ $? -eq 0 ]; then
    echo -e "\n\e[32m✅ Workflow completed successfully!\e[0m"
    echo "Database saved to: ${DB_FULL_PATH}"
else
    echo -e "\n\e[31m❌ Workflow failed during database creation.\e[0m"
    echo "Please check the error messages, kernel configuration, and command arguments."
fi