#!/bin/bash

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

CONTAINER_NAME="${N8N_CONTAINER:-n8n}"
IMPORT_DIR="${N8N_IMPORT_DIR:-/home/node/import/workflows}"
SUBWORKFLOW_PREFIX="${SUBWORKFLOW_PREFIX:-subW}"
LIST_ONLY=0
IMPORT_ALL=0
AUTO_CONFIRM=0
TARGET_FILE=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Import n8n workflow JSON files from the container import directory one workflow
at a time. Files prefixed with '${SUBWORKFLOW_PREFIX}' are listed and imported
first so sub workflows are available before dependent parent workflows.

Options:
  --file NAME        Import one workflow file by exact filename.
  --all              Import every JSON file sequentially, one at a time.
  --list             List available workflow files and exit.
  --container NAME   Docker container name (default: ${CONTAINER_NAME}).
  --dir PATH         Import directory inside container (default: ${IMPORT_DIR}).
  -y, --yes          Skip confirmation prompt.
  -h, --help         Show this help text.

Examples:
  $(basename "$0")
  $(basename "$0") --list
  $(basename "$0") --file "Service-Worker .json"
  $(basename "$0") --all -y
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --file)
            [ $# -lt 2 ] && { echo "Missing value for --file" >&2; exit 1; }
            TARGET_FILE="$2"
            shift 2
            ;;
        --all)
            IMPORT_ALL=1
            shift
            ;;
        --list)
            LIST_ONLY=1
            shift
            ;;
        --container)
            [ $# -lt 2 ] && { echo "Missing value for --container" >&2; exit 1; }
            CONTAINER_NAME="$2"
            shift 2
            ;;
        --dir)
            [ $# -lt 2 ] && { echo "Missing value for --dir" >&2; exit 1; }
            IMPORT_DIR="$2"
            shift 2
            ;;
        -y|--yes)
            AUTO_CONFIRM=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [ "$IMPORT_ALL" -eq 1 ] && [ -n "$TARGET_FILE" ]; then
    echo -e "${RED}Choose either --file or --all, not both.${NC}" >&2
    exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
    echo -e "${RED}docker is not installed or not in PATH.${NC}" >&2
    exit 1
fi

if ! docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    echo -e "${RED}Container '${CONTAINER_NAME}' was not found.${NC}" >&2
    exit 1
fi

if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" != "true" ]; then
    echo -e "${RED}Container '${CONTAINER_NAME}' is not running.${NC}" >&2
    exit 1
fi

list_workflows() {
    docker exec "$CONTAINER_NAME" sh -lc \
        "cd \"$IMPORT_DIR\" 2>/dev/null && ls -1 *.json 2>/dev/null | sort" || true
}

prioritize_workflows() {
    local workflows=("$@")
    local workflow

    for workflow in "${workflows[@]}"; do
        case "$workflow" in
            "${SUBWORKFLOW_PREFIX}"*)
                printf '%s\n' "$workflow"
                ;;
        esac
    done

    for workflow in "${workflows[@]}"; do
        case "$workflow" in
            "${SUBWORKFLOW_PREFIX}"*)
                ;;
            *)
                printf '%s\n' "$workflow"
                ;;
        esac
    done
}

print_workflows() {
    local workflows=("$@")
    local index=1
    for workflow in "${workflows[@]}"; do
        printf '%2d. %s\n' "$index" "$workflow"
        index=$((index + 1))
    done
}

import_workflow() {
    local workflow_file="$1"

    echo -e "${YELLOW}Importing ${workflow_file}...${NC}"
    if docker exec "$CONTAINER_NAME" n8n import:workflow "--input=${IMPORT_DIR}/${workflow_file}"; then
        echo -e "${GREEN}Imported ${workflow_file}${NC}"
        return 0
    fi

    echo -e "${RED}Failed to import ${workflow_file}${NC}" >&2
    return 1
}

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}n8n Workflow Import Script${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Container:${NC} ${CONTAINER_NAME}"
echo -e "${BLUE}Import dir:${NC} ${IMPORT_DIR}"
echo ""

mapfile -t RAW_WORKFLOWS < <(list_workflows)
mapfile -t WORKFLOWS < <(prioritize_workflows "${RAW_WORKFLOWS[@]}")

if [ "${#WORKFLOWS[@]}" -eq 0 ]; then
    echo -e "${RED}No JSON workflow files found in ${IMPORT_DIR}.${NC}" >&2
    exit 1
fi

if [ "$LIST_ONLY" -eq 1 ]; then
    print_workflows "${WORKFLOWS[@]}"
    exit 0
fi

if [ "$IMPORT_ALL" -eq 1 ]; then
    if [ "$AUTO_CONFIRM" -ne 1 ]; then
        echo -e "${YELLOW}The following workflows will be imported sequentially:${NC}"
        print_workflows "${WORKFLOWS[@]}"
        echo ""
        read -r -p "Continue? [y/N]: " confirm
        case "$confirm" in
            y|Y|yes|YES)
                ;;
            *)
                echo "Cancelled."
                exit 0
                ;;
        esac
    fi

    success_count=0
    fail_count=0
    for workflow in "${WORKFLOWS[@]}"; do
        if import_workflow "$workflow"; then
            success_count=$((success_count + 1))
        else
            fail_count=$((fail_count + 1))
        fi
        echo ""
    done

    echo -e "${BLUE}Summary:${NC} ${success_count} imported, ${fail_count} failed"
    [ "$fail_count" -eq 0 ]
    exit $?
fi

if [ -z "$TARGET_FILE" ]; then
    echo -e "${YELLOW}Available workflow files:${NC}"
    print_workflows "${WORKFLOWS[@]}"
    echo ""
    read -r -p "Select a workflow number to import: " selection
    if ! [[ "$selection" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Selection must be a number.${NC}" >&2
        exit 1
    fi
    if [ "$selection" -lt 1 ] || [ "$selection" -gt "${#WORKFLOWS[@]}" ]; then
        echo -e "${RED}Selection is out of range.${NC}" >&2
        exit 1
    fi
    TARGET_FILE="${WORKFLOWS[$((selection - 1))]}"
fi

found=0
for workflow in "${WORKFLOWS[@]}"; do
    if [ "$workflow" = "$TARGET_FILE" ]; then
        found=1
        break
    fi
done

if [ "$found" -ne 1 ]; then
    echo -e "${RED}Workflow file not found: ${TARGET_FILE}${NC}" >&2
    exit 1
fi

if [ "$AUTO_CONFIRM" -ne 1 ]; then
    read -r -p "Import '${TARGET_FILE}'? [y/N]: " confirm
    case "$confirm" in
        y|Y|yes|YES)
            ;;
        *)
            echo "Cancelled."
            exit 0
            ;;
    esac
fi

import_workflow "$TARGET_FILE"
