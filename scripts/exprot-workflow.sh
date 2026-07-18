#!/bin/bash

# n8n Workflow Export Script
# This script lists all workflows and exports them one by one

set -e  # Exit on error

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Configuration
PYTHON_BIN="${PYTHON_BIN:-python3}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPORT_DIR="${SCRIPT_DIR}/../n8n-import/workflows"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
EXPORT_SUBDIR="${EXPORT_DIR}/export_${TIMESTAMP}"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}n8n Workflow Export Script${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Prereqs
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    echo -e "${RED}✗ ${PYTHON_BIN} not found. Set PYTHON_BIN or install python3.${NC}"
    exit 1
fi

# Create export directory
echo -e "${YELLOW}Creating export directory...${NC}"
mkdir -p "${EXPORT_SUBDIR}"
echo -e "${GREEN}✓ Directory created: ${EXPORT_SUBDIR}${NC}"
echo ""

# Get list of workflows
echo -e "${YELLOW}Fetching workflow list...${NC}"
WORKFLOW_LIST_MODE="json"
if ! WORKFLOW_LIST=$(docker compose exec -T n8n n8n list:workflow --output=json 2>/dev/null); then
    echo -e "${RED}✗ Failed to connect to n8n via docker compose${NC}"
    exit 1
fi

if [ -z "$WORKFLOW_LIST" ]; then
    echo -e "${RED}✗ No workflows found or error connecting to n8n${NC}"
    exit 1
fi

if ! printf '%s' "$WORKFLOW_LIST" | "$PYTHON_BIN" -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; then
    echo -e "${YELLOW}! JSON output not available; falling back to text parsing${NC}"
    if ! WORKFLOW_LIST=$(docker compose exec -T n8n n8n list:workflow 2>/dev/null); then
        echo -e "${RED}✗ Failed to connect to n8n via docker compose${NC}"
        exit 1
    fi
    if [ -z "$WORKFLOW_LIST" ]; then
        echo -e "${RED}✗ No workflows found or error connecting to n8n${NC}"
        exit 1
    fi
    WORKFLOW_LIST_MODE="text"
fi

echo -e "${GREEN}✓ Workflows found:${NC}"
if [ "$WORKFLOW_LIST_MODE" = "json" ]; then
    printf '%s' "$WORKFLOW_LIST" | "$PYTHON_BIN" -c 'import json,sys; data=json.load(sys.stdin); [print("id: {} - name: {}".format(wf.get("id"), wf.get("name"))) for wf in data]'
else
    echo "$WORKFLOW_LIST"
fi
echo ""

# Parse workflow IDs and names
# Emit TSV lines: <id>\t<name>
echo -e "${YELLOW}Parsing workflow IDs...${NC}"

read -r -d '' PARSE_JSON_CODE <<'PY' || true
import json, sys
data = json.load(sys.stdin)
for wf in data:
    if wf.get("id"):
        print(f"{wf.get('id')}\t{wf.get('name','')}")
PY

read -r -d '' PARSE_TEXT_CODE <<'PY' || true
import re, sys
seen = set()
for line in sys.stdin:
    raw = line.rstrip("\n")
    if not raw.strip():
        continue
    wf_id = ""; name = ""
    if "|" in raw:
        wf_id, name = raw.split("|", 1)
    else:
        m = re.match(r"^\s*(\d+)\s+(.*)$", raw)
        if m:
            wf_id, name = m.group(1), m.group(2)
        else:
            m = re.search(r"\bid:\s*([A-Za-z0-9_-]+)\b.*?name:\s*(.+)$", raw, re.I)
            if m:
                wf_id, name = m.group(1), m.group(2)
    wf_id = wf_id.strip()
    name = name.strip()
    if wf_id and wf_id not in seen:
        print(f"{wf_id}\t{name}")
        seen.add(wf_id)
PY

if [ "$WORKFLOW_LIST_MODE" = "json" ]; then
    WORKFLOW_TSV=$(printf '%s' "$WORKFLOW_LIST" | "$PYTHON_BIN" -c "$PARSE_JSON_CODE")
else
    WORKFLOW_TSV=$(printf '%s' "$WORKFLOW_LIST" | "$PYTHON_BIN" -c "$PARSE_TEXT_CODE")
fi

if [ -z "$WORKFLOW_TSV" ]; then
    echo -e "${RED}✗ Could not parse workflow IDs${NC}"
    echo -e "${YELLOW}Workflow list output:${NC}"
    echo "$WORKFLOW_LIST"
    exit 1
fi

WORKFLOW_COUNT=$(printf '%s\n' "$WORKFLOW_TSV" | wc -l)
echo -e "${GREEN}✓ Found ${WORKFLOW_COUNT} workflow(s) to export${NC}"
echo ""

# Export each workflow
COUNTER=1
SUCCESS_COUNT=0
FAILED_COUNT=0

echo -e "${BLUE}Starting export...${NC}"
echo ""

while IFS=$'\t' read -r WORKFLOW_ID WORKFLOW_NAME; do
    # Skip empty lines
    [ -z "$WORKFLOW_ID" ] && continue
    
    echo -e "${YELLOW}[$COUNTER/$WORKFLOW_COUNT] Exporting workflow ID: ${WORKFLOW_ID}${NC}"
    
    # Export workflow
    SAFE_NAME=$(printf '%s' "$WORKFLOW_NAME" | "$PYTHON_BIN" -c 'import re,sys; name=sys.stdin.read().strip() or "workflow"; name=re.sub(r"[^A-Za-z0-9._-]+","-", name); name=name.strip("-") or "workflow"; print(name)')
    BASE_NAME="${TIMESTAMP}_${SAFE_NAME}"
    OUTPUT_FILE="${EXPORT_SUBDIR}/${BASE_NAME}.json"
    # Avoid collisions on identical names
    if [ -e "$OUTPUT_FILE" ]; then
        OUTPUT_FILE="${EXPORT_SUBDIR}/${BASE_NAME}_${WORKFLOW_ID}.json"
    fi
    
    # Redirect stdin to avoid consuming the here-string feeding the while loop
    if docker compose exec -T n8n n8n export:workflow --id="${WORKFLOW_ID}" </dev/null > "${OUTPUT_FILE}" 2>/dev/null; then
        FILE_SIZE=$(wc -c < "${OUTPUT_FILE}")
        if [ "$FILE_SIZE" -gt 10 ]; then
            echo -e "${GREEN}  ✓ Successfully exported to: $(basename "${OUTPUT_FILE}") (${FILE_SIZE} bytes)${NC}"
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            echo -e "${RED}  ✗ Export failed - file too small${NC}"
            rm -f "${OUTPUT_FILE}"
            FAILED_COUNT=$((FAILED_COUNT + 1))
        fi
    else
        echo -e "${RED}  ✗ Export failed for workflow ID: ${WORKFLOW_ID}${NC}"
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
    
    echo ""
    COUNTER=$((COUNTER + 1))
done <<< "$WORKFLOW_TSV"

# Summary
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Export Summary${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}✓ Successfully exported: ${SUCCESS_COUNT}${NC}"
if [ $FAILED_COUNT -gt 0 ]; then
    echo -e "${RED}✗ Failed: ${FAILED_COUNT}${NC}"
fi
echo -e "${BLUE}Export location: ${EXPORT_SUBDIR}${NC}"
echo ""

# List exported files
if [ $SUCCESS_COUNT -gt 0 ]; then
    echo -e "${YELLOW}Exported files:${NC}"
    ls -lh "${EXPORT_SUBDIR}"/*.json 2>/dev/null || echo "No files found"
fi

echo ""
echo -e "${GREEN}Done!${NC}"
