#!/usr/bin/env bash
#
# Griffin G-code Flavor Validation Test Suite
#
# Validates OrcaSlicer's Griffin G-code output and optionally compares with CuraEngine.
#
# Usage:
#   ./tests/griffin_gcode_validation.sh [--orca-bin PATH] [--cura-bin PATH] [--compare]
#
# Options:
#   --orca-bin PATH    Path to orca-slicer binary (default: auto-detect in build/)
#   --cura-bin PATH    Path to CuraEngine binary (optional, for cross-comparison)
#   --cura-defs PATH   Path to Cura resources/definitions directory
#   --compare          Enable Cura cross-comparison (requires --cura-bin)
#   --keep-output      Don't delete temporary files after test
#   --verbose          Show full G-code diffs
#
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROFILES_DIR="$PROJECT_DIR/resources/profiles/UltiMaker"

ORCA_BIN=""
CURA_BIN=""
CURA_DEFS=""
COMPARE=false
KEEP_OUTPUT=false
VERBOSE=false

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ── Argument Parsing ──────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case $1 in
        --orca-bin)   ORCA_BIN="$2"; shift 2 ;;
        --cura-bin)   CURA_BIN="$2"; shift 2 ;;
        --cura-defs)  CURA_DEFS="$2"; shift 2 ;;
        --compare)    COMPARE=true; shift ;;
        --keep-output) KEEP_OUTPUT=true; shift ;;
        --verbose)    VERBOSE=true; shift ;;
        -h|--help)
            sed -n '3,13p' "$0"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ── Helper Functions ──────────────────────────────────────────────────────
pass() { ((PASS_COUNT++)); echo -e "  ${GREEN}PASS${NC}: $1"; }
fail() { ((FAIL_COUNT++)); echo -e "  ${RED}FAIL${NC}: $1"; }
skip() { ((SKIP_COUNT++)); echo -e "  ${YELLOW}SKIP${NC}: $1"; }
info() { echo -e "  ${BLUE}INFO${NC}: $1"; }

check_contains() {
    local file="$1" pattern="$2" description="$3"
    if grep -qE "$pattern" "$file" 2>/dev/null; then
        pass "$description"
    else
        fail "$description (pattern '$pattern' not found)"
    fi
}

check_not_contains() {
    local file="$1" pattern="$2" description="$3"
    if grep -qE "$pattern" "$file" 2>/dev/null; then
        fail "$description (unexpected pattern '$pattern' found)"
        if $VERBOSE; then
            echo "    Matches:"
            grep -n "$pattern" "$file" | head -5 | sed 's/^/      /'
        fi
    else
        pass "$description"
    fi
}

check_header_field() {
    local file="$1" field="$2" description="$3"
    if grep -q "^;${field}:" "$file" 2>/dev/null; then
        local value
        value=$(grep "^;${field}:" "$file" | head -1 | sed "s/^;${field}://")
        pass "$description (value: $value)"
    else
        fail "$description (header field ;${field}: not found)"
    fi
}

# ── Generate Test Model ───────────────────────────────────────────────────
generate_test_cube() {
    local output="$1"
    # Generate a simple 20mm cube as ASCII STL
    cat > "$output" << 'STLEOF'
solid cube
  facet normal 0 0 -1
    outer loop
      vertex 0 0 0
      vertex 20 0 0
      vertex 20 20 0
    endloop
  endfacet
  facet normal 0 0 -1
    outer loop
      vertex 0 0 0
      vertex 20 20 0
      vertex 0 20 0
    endloop
  endfacet
  facet normal 0 0 1
    outer loop
      vertex 0 0 20
      vertex 20 20 20
      vertex 20 0 20
    endloop
  endfacet
  facet normal 0 0 1
    outer loop
      vertex 0 0 20
      vertex 0 20 20
      vertex 20 20 20
    endloop
  endfacet
  facet normal 0 -1 0
    outer loop
      vertex 0 0 0
      vertex 20 0 20
      vertex 20 0 0
    endloop
  endfacet
  facet normal 0 -1 0
    outer loop
      vertex 0 0 0
      vertex 0 0 20
      vertex 20 0 20
    endloop
  endfacet
  facet normal 0 1 0
    outer loop
      vertex 0 20 0
      vertex 20 20 0
      vertex 20 20 20
    endloop
  endfacet
  facet normal 0 1 0
    outer loop
      vertex 0 20 0
      vertex 20 20 20
      vertex 0 20 20
    endloop
  endfacet
  facet normal -1 0 0
    outer loop
      vertex 0 0 0
      vertex 0 20 0
      vertex 0 20 20
    endloop
  endfacet
  facet normal -1 0 0
    outer loop
      vertex 0 0 0
      vertex 0 20 20
      vertex 0 0 20
    endloop
  endfacet
  facet normal 1 0 0
    outer loop
      vertex 20 0 0
      vertex 20 0 20
      vertex 20 20 20
    endloop
  endfacet
  facet normal 1 0 0
    outer loop
      vertex 20 0 0
      vertex 20 20 20
      vertex 20 20 0
    endloop
  endfacet
endsolid cube
STLEOF
}

# ── Auto-detect OrcaSlicer Binary ─────────────────────────────────────────
find_orca_binary() {
    if [[ -n "$ORCA_BIN" ]]; then
        if [[ -x "$ORCA_BIN" ]]; then return 0; fi
        echo "ERROR: Specified orca-slicer binary not found: $ORCA_BIN"
        return 1
    fi
    # Search common build locations
    for candidate in \
        "$PROJECT_DIR/build/arm64/src/orca-slicer" \
        "$PROJECT_DIR/build/arm64/src/Release/OrcaSlicer" \
        "$PROJECT_DIR/build/arm64/src/RelWithDebInfo/OrcaSlicer" \
        "$PROJECT_DIR/build/x86_64/src/orca-slicer" \
        "$PROJECT_DIR/build/src/orca-slicer" \
        "$PROJECT_DIR/build/src/Release/OrcaSlicer" \
        "$(command -v orca-slicer 2>/dev/null || true)" \
        "$(command -v OrcaSlicer 2>/dev/null || true)" \
        "/Applications/OrcaSlicer.app/Contents/MacOS/OrcaSlicer" \
        ; do
        if [[ -n "$candidate" && -x "$candidate" ]]; then
            ORCA_BIN="$candidate"
            return 0
        fi
    done
    echo "ERROR: Cannot find orca-slicer binary. Use --orca-bin to specify."
    return 1
}

# ── Main ──────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║      Griffin G-code Flavor Validation Test Suite            ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    # Setup
    if ! find_orca_binary; then exit 1; fi
    info "OrcaSlicer binary: $ORCA_BIN"

    TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/griffin_test.XXXXXX")
    if ! $KEEP_OUTPUT; then
        trap "rm -rf '$TMPDIR'" EXIT
    else
        info "Output directory (kept): $TMPDIR"
    fi

    # Generate test model
    TEST_STL="$TMPDIR/test_cube.stl"
    generate_test_cube "$TEST_STL"
    info "Test model: $TEST_STL"

    # ── Phase 1: Profile Validation ───────────────────────────────────
    echo ""
    echo "━━━ Phase 1: Profile Validation ━━━"

    for printer in "UltiMaker S3" "UltiMaker S5" "UltiMaker S7" "UltiMaker 2+ Connect"; do
        machine_json="$PROFILES_DIR/machine/${printer} 0.4 nozzle.json"
        model_json="$PROFILES_DIR/machine/${printer}.json"

        if [[ -f "$machine_json" ]]; then
            pass "Machine profile exists: ${printer}"

            # Check Griffin flavor
            if grep -q '"gcode_flavor".*"griffin"' "$machine_json"; then
                pass "${printer}: gcode_flavor is griffin"
            else
                fail "${printer}: gcode_flavor is not griffin"
            fi

            # Check Griffin-specific keys
            for key in prime_blob_enable extruder_prime_pos_x machine_nozzle_id; do
                if grep -q "\"$key\"" "$machine_json"; then
                    pass "${printer}: has $key"
                else
                    fail "${printer}: missing $key"
                fi
            done
        else
            fail "Machine profile missing: ${printer}"
        fi

        if [[ -f "$model_json" ]]; then
            pass "Model definition exists: ${printer}"
        else
            fail "Model definition missing: ${printer}"
        fi
    done

    # Check cover images
    for printer in "UltiMaker S3" "UltiMaker S5" "UltiMaker S7" "UltiMaker 2+ Connect"; do
        if [[ -f "$PROFILES_DIR/${printer}_cover.png" ]]; then
            pass "Cover image exists: ${printer}"
        else
            fail "Cover image missing: ${printer}"
        fi
    done

    # Check start gcode doesn't have temperature commands for Griffin printers
    for printer in "UltiMaker S3" "UltiMaker S5" "UltiMaker S7" "UltiMaker 2+ Connect"; do
        machine_json="$PROFILES_DIR/machine/${printer} 0.4 nozzle.json"
        if [[ -f "$machine_json" ]]; then
            if grep -q 'M104\|M109\|M140\|M190' "$machine_json"; then
                fail "${printer}: start gcode contains temperature M-codes (should use header)"
            else
                pass "${printer}: start gcode has no temperature M-codes"
            fi
        fi
    done

    # ── Phase 2: OrcaSlicer G-code Generation ─────────────────────────
    echo ""
    echo "━━━ Phase 2: OrcaSlicer G-code Slicing ━━━"

    ORCA_GCODE="$TMPDIR/orca_griffin.gcode"

    # Merge machine + process settings into a single config for CLI
    MERGED_SETTINGS="$TMPDIR/merged_settings.json"
    python3 -c "
import json, sys

machine = json.load(open('$PROFILES_DIR/machine/UltiMaker S5 0.4 nozzle.json'))
common = json.load(open('$PROFILES_DIR/machine/fdm_machine_common.json'))
process = json.load(open('$PROFILES_DIR/process/0.20mm Standard @UltiMaker S5.json'))

# Merge: common < machine < process
merged = {}
for d in [common, machine, process]:
    for k, v in d.items():
        if k not in ('type', 'name', 'inherits', 'from', 'setting_id',
                     'instantiation', 'compatible_printers', 'printer_model',
                     'default_print_profile', 'default_filament_profile'):
            merged[k] = v

json.dump(merged, open('$MERGED_SETTINGS', 'w'), indent=2)
" 2>&1

    info "Slicing with OrcaSlicer (UltiMaker S5 Griffin profile)..."
    if "$ORCA_BIN" \
        --load-settings "$MERGED_SETTINGS" \
        --outputdir "$TMPDIR" \
        --debug 3 \
        --no-check \
        --slice 0 \
        "$TEST_STL" > "$TMPDIR/orca_stdout.log" 2>&1; then
        # Find the generated gcode file
        GENERATED=$(find "$TMPDIR" -name "*.gcode" -newer "$TEST_STL" | head -1)
        if [[ -n "$GENERATED" ]]; then
            mv "$GENERATED" "$ORCA_GCODE"
            pass "OrcaSlicer slicing succeeded"
            info "Output: $ORCA_GCODE ($(wc -l < "$ORCA_GCODE") lines)"
        else
            fail "OrcaSlicer slicing produced no G-code output"
            info "Check log: $TMPDIR/orca_stdout.log"
            # Still try to continue with whatever we can test
        fi
    else
        fail "OrcaSlicer slicing failed (exit code $?)"
        info "Check log: $TMPDIR/orca_stdout.log"
        if $VERBOSE; then
            echo "    Last 20 lines of log:"
            tail -20 "$TMPDIR/orca_stdout.log" 2>/dev/null | sed 's/^/      /'
        fi
    fi

    # ── Phase 3: Griffin Header Validation ─────────────────────────────
    if [[ -f "$ORCA_GCODE" ]]; then
        echo ""
        echo "━━━ Phase 3: Griffin Header Validation ━━━"

        check_contains "$ORCA_GCODE" "^;START_OF_HEADER" "Header starts with ;START_OF_HEADER"
        check_contains "$ORCA_GCODE" "^;END_OF_HEADER" "Header ends with ;END_OF_HEADER"
        check_contains "$ORCA_GCODE" "^;FLAVOR:Griffin" "Header contains ;FLAVOR:Griffin"
        check_contains "$ORCA_GCODE" "^;GENERATOR.NAME:OrcaSlicer" "Header contains ;GENERATOR.NAME:OrcaSlicer"

        check_header_field "$ORCA_GCODE" "HEADER_VERSION" "Header version present"
        check_header_field "$ORCA_GCODE" "GENERATOR.VERSION" "Generator version present"
        check_header_field "$ORCA_GCODE" "TARGET_MACHINE.NAME" "Target machine name present"
        check_header_field "$ORCA_GCODE" "EXTRUDER_TRAIN.0.INITIAL_TEMPERATURE" "Extruder 0 initial temp present"
        check_header_field "$ORCA_GCODE" "EXTRUDER_TRAIN.0.NOZZLE.DIAMETER" "Extruder 0 nozzle diameter present"
        check_header_field "$ORCA_GCODE" "BUILD_PLATE.INITIAL_TEMPERATURE" "Build plate temp present"

        # PRINT.TIME should be a real number, not 0
        PRINT_TIME=$(grep "^;PRINT.TIME:" "$ORCA_GCODE" | head -1 | sed 's/^;PRINT.TIME://')
        if [[ -n "$PRINT_TIME" ]]; then
            # Check it's not literally "0" or empty
            if [[ "$PRINT_TIME" == "0" || "$PRINT_TIME" == "0.00" || -z "$PRINT_TIME" ]]; then
                fail "PRINT.TIME is zero or empty (value: '$PRINT_TIME')"
            else
                pass "PRINT.TIME has real value ($PRINT_TIME seconds)"
            fi
        else
            fail "PRINT.TIME field missing from header"
        fi

        check_header_field "$ORCA_GCODE" "PRINT.GROUPS" "Print groups present"

        # Bounding box
        check_header_field "$ORCA_GCODE" "PRINT.SIZE.MIN.X" "Bounding box MIN.X present"
        check_header_field "$ORCA_GCODE" "PRINT.SIZE.MAX.Z" "Bounding box MAX.Z present"

        # ── Phase 4: Temperature Command Suppression ──────────────────
        echo ""
        echo "━━━ Phase 4: Temperature Command Validation ━━━"

        # Extract the section BEFORE the start gcode marker (auto-injected commands)
        # Griffin should NOT have auto-injected temperature commands
        # Note: Some temperature commands may appear in user's start gcode, but for
        # our simplified start gcode, there should be none at all.
        check_not_contains "$ORCA_GCODE" "^M104 " "No M104 (set hotend temp) in G-code body"
        check_not_contains "$ORCA_GCODE" "^M109 " "No M109 (wait hotend temp) in G-code body"
        check_not_contains "$ORCA_GCODE" "^M140 " "No M140 (set bed temp) in G-code body"
        check_not_contains "$ORCA_GCODE" "^M190 " "No M190 (wait bed temp) in G-code body"

        # ── Phase 5: G-code Command Format ────────────────────────────
        echo ""
        echo "━━━ Phase 5: G-code Command Format ━━━"

        # Acceleration: should use M204 P (not M204 S)
        if grep -q "^M204 " "$ORCA_GCODE"; then
            check_not_contains "$ORCA_GCODE" "^M204 S" "No legacy M204 S acceleration format"
            check_contains "$ORCA_GCODE" "^M204 P" "Uses M204 P acceleration format"
        else
            skip "No M204 commands found (acceleration may not be set)"
        fi

        # No M300 beep or M1 wait
        check_not_contains "$ORCA_GCODE" "^M300 " "No M300 (beep) commands"
        check_not_contains "$ORCA_GCODE" "^M1 \|^M1$" "No M1 (wait for user) commands"

        # No M220 speed override from wipe tower
        check_not_contains "$ORCA_GCODE" "^M220 S" "No M220 (speed override) commands"

        # G280 prime blob
        check_contains "$ORCA_GCODE" "^G280" "G280 prime command present"

        # Start gcode elements
        check_contains "$ORCA_GCODE" "^T0" "T0 tool select in start gcode"
        check_contains "$ORCA_GCODE" "^G28" "G28 home in start gcode"
        check_contains "$ORCA_GCODE" "^G92 E0" "G92 E0 reset extruder in start gcode"

        # Extrusion mode: linear E values (not volumetric)
        # Griffin should NOT have M200 (volumetric enable)
        check_not_contains "$ORCA_GCODE" "^M200 D[1-9]" "No M200 D (volumetric extrusion) - uses linear E"

        # M486 cancel object support
        if grep -q "^M486" "$ORCA_GCODE"; then
            check_contains "$ORCA_GCODE" "^M486 T" "M486 T<count> total object count present"
            pass "M486 cancel object commands present"
        else
            skip "No M486 commands (single object, cancel-object may be disabled)"
        fi

        # ── Phase 6: Structural Integrity ─────────────────────────────
        echo ""
        echo "━━━ Phase 6: Structural Integrity ━━━"

        # Header should come before any G0/G1 moves
        HEADER_END_LINE=$(grep -n "^;END_OF_HEADER" "$ORCA_GCODE" | head -1 | cut -d: -f1)
        FIRST_MOVE_LINE=$(grep -n "^G[01] " "$ORCA_GCODE" | head -1 | cut -d: -f1)
        if [[ -n "$HEADER_END_LINE" && -n "$FIRST_MOVE_LINE" ]]; then
            if (( HEADER_END_LINE < FIRST_MOVE_LINE )); then
                pass "Header ends before first move (line $HEADER_END_LINE < $FIRST_MOVE_LINE)"
            else
                fail "Header ends after first move (line $HEADER_END_LINE >= $FIRST_MOVE_LINE)"
            fi
        else
            skip "Could not determine header/move ordering"
        fi

        # G-code should end with M84 (disable motors) or similar
        LAST_MEANINGFUL=$(grep -n "^[GMT]" "$ORCA_GCODE" | tail -1)
        info "Last G-code command: $LAST_MEANINGFUL"

        # Count total extrusion moves
        EXTRUSION_COUNT=$(grep -c "^G1 .*E" "$ORCA_GCODE" || true)
        info "Total extrusion moves: $EXTRUSION_COUNT"
        if (( EXTRUSION_COUNT > 0 )); then
            pass "G-code contains extrusion moves"
        else
            fail "G-code contains no extrusion moves"
        fi
    fi

    # ── Phase 7: Cura Cross-Comparison (Optional) ─────────────────────
    if $COMPARE; then
        echo ""
        echo "━━━ Phase 7: Cura Cross-Comparison ━━━"

        if [[ -z "$CURA_BIN" || ! -x "$CURA_BIN" ]]; then
            skip "CuraEngine binary not found or not specified (use --cura-bin)"
        elif [[ -z "$CURA_DEFS" || ! -d "$CURA_DEFS" ]]; then
            skip "Cura definitions directory not specified (use --cura-defs)"
        else
            CURA_GCODE="$TMPDIR/cura_griffin.gcode"
            info "Slicing with CuraEngine (Griffin flavor)..."

            # CuraEngine needs CURA_ENGINE_SEARCH_PATH to find extruder definitions
            # The definitions dir typically contains both printer and extruder defs
            EXTRUDERS_DIR="$(dirname "$CURA_DEFS")/extruders"
            if [[ -d "$EXTRUDERS_DIR" ]]; then
                export CURA_ENGINE_SEARCH_PATH="${CURA_DEFS}:${EXTRUDERS_DIR}"
            else
                export CURA_ENGINE_SEARCH_PATH="${CURA_DEFS}"
            fi
            info "CURA_ENGINE_SEARCH_PATH=$CURA_ENGINE_SEARCH_PATH"

            # CuraEngine CLI syntax:
            # CuraEngine slice -j <machine_def.json> -o output.gcode -l model.stl -s key=value
            # Note: CuraEngine cannot evaluate Python expressions in def.json files,
            # so derived settings like infill_sparse_density must be specified as
            # their underlying value (infill_line_distance).
            CURA_DEF="$CURA_DEFS/ultimaker_s5.def.json"
            if [[ ! -f "$CURA_DEF" ]]; then
                # Try alternate paths
                CURA_DEF=$(find "$CURA_DEFS" -name "ultimaker_s5*" -name "*.def.json" 2>/dev/null | head -1)
            fi

            if [[ -n "$CURA_DEF" && -f "$CURA_DEF" ]]; then
                if "$CURA_BIN" slice -v \
                    -j "$CURA_DEF" \
                    -o "$CURA_GCODE" \
                    -s machine_gcode_flavor=Griffin \
                    -g \
                    -e0 \
                    -s material_print_temperature=210 \
                    -s material_bed_temperature=60 \
                    -s default_material_print_temperature=210 \
                    -s default_material_bed_temperature=60 \
                    -s layer_height=0.2 \
                    -s wall_line_count=3 \
                    -s infill_line_distance=4.0 \
                    -s infill_pattern=grid \
                    -l "$TEST_STL" \
                    > "$TMPDIR/cura_stdout.log" 2>&1; then
                    pass "CuraEngine slicing succeeded"
                    info "Cura output: $CURA_GCODE ($(wc -l < "$CURA_GCODE") lines)"
                else
                    fail "CuraEngine slicing failed"
                    info "Check log: $TMPDIR/cura_stdout.log"
                    if $VERBOSE; then
                        echo "    Last 20 lines of log:"
                        tail -20 "$TMPDIR/cura_stdout.log" 2>/dev/null | sed 's/^/      /'
                    fi
                fi
            else
                skip "Cura machine definition for UltiMaker S5 not found in $CURA_DEFS"
            fi

            # Compare headers
            if [[ -f "$CURA_GCODE" && -f "$ORCA_GCODE" ]]; then
                echo ""
                echo "  ── Header Comparison ──"

                ORCA_HEADER="$TMPDIR/orca_header.txt"
                CURA_HEADER="$TMPDIR/cura_header.txt"

                sed -n '/^;START_OF_HEADER/,/^;END_OF_HEADER/p' "$ORCA_GCODE" > "$ORCA_HEADER"
                sed -n '/^;START_OF_HEADER/,/^;END_OF_HEADER/p' "$CURA_GCODE" > "$CURA_HEADER"

                # Compare header fields
                for field in FLAVOR HEADER_VERSION "EXTRUDER_TRAIN.0.INITIAL_TEMPERATURE" \
                             "EXTRUDER_TRAIN.0.NOZZLE.DIAMETER" "BUILD_PLATE.INITIAL_TEMPERATURE"; do
                    ORCA_VAL=$(grep "^;${field}:" "$ORCA_HEADER" 2>/dev/null | sed "s/^;${field}://" || echo "MISSING")
                    CURA_VAL=$(grep "^;${field}:" "$CURA_HEADER" 2>/dev/null | sed "s/^;${field}://" || echo "MISSING")
                    if [[ "$ORCA_VAL" == "$CURA_VAL" ]]; then
                        pass "Header ${field} matches: $ORCA_VAL"
                    else
                        info "Header ${field} differs: Orca='$ORCA_VAL' vs Cura='$CURA_VAL'"
                    fi
                done

                # Compare structural patterns
                echo ""
                echo "  ── Command Pattern Comparison ──"

                for cmd_pattern in "^M104 " "^M109 " "^M140 " "^M190 " "^M204 " "^G280" "^M200 D" "^M486 "; do
                    ORCA_CNT=$(grep -c "$cmd_pattern" "$ORCA_GCODE" 2>/dev/null || echo "0")
                    CURA_CNT=$(grep -c "$cmd_pattern" "$CURA_GCODE" 2>/dev/null || echo "0")
                    CMD_NAME=$(echo "$cmd_pattern" | sed 's/[\^]//g; s/ $//')
                    if [[ "$ORCA_CNT" == "$CURA_CNT" ]]; then
                        pass "${CMD_NAME}: count matches ($ORCA_CNT)"
                    else
                        info "${CMD_NAME}: Orca=$ORCA_CNT vs Cura=$CURA_CNT"
                    fi
                done

                # Check extrusion mode consistency
                ORCA_VOL=$(grep -c "^M200 D[1-9]" "$ORCA_GCODE" 2>/dev/null || echo "0")
                CURA_VOL=$(grep -c "^M200 D[1-9]" "$CURA_GCODE" 2>/dev/null || echo "0")
                if [[ "$ORCA_VOL" == "0" && "$CURA_VOL" == "0" ]]; then
                    pass "Both use linear E values (no M200 volumetric)"
                elif [[ "$ORCA_VOL" == "$CURA_VOL" ]]; then
                    pass "Both use same extrusion mode (volumetric=$ORCA_VOL)"
                else
                    fail "Extrusion mode mismatch: Orca volumetric=$ORCA_VOL, Cura volumetric=$CURA_VOL"
                fi

                if $VERBOSE; then
                    echo ""
                    echo "  ── Full Header Diff ──"
                    diff --color=always "$ORCA_HEADER" "$CURA_HEADER" || true
                fi
            fi
        fi
    fi

    # ── Summary ───────────────────────────────────────────────────────
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    TOTAL=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))
    echo -e "  Results: ${GREEN}${PASS_COUNT} passed${NC}, ${RED}${FAIL_COUNT} failed${NC}, ${YELLOW}${SKIP_COUNT} skipped${NC} (${TOTAL} total)"

    if $KEEP_OUTPUT; then
        echo ""
        echo "  Output files preserved in: $TMPDIR"
        echo "    - $TMPDIR/test_cube.stl"
        [[ -f "$ORCA_GCODE" ]] && echo "    - $ORCA_GCODE"
        [[ -f "${CURA_GCODE:-}" ]] && echo "    - $CURA_GCODE"
    fi
    echo ""

    if (( FAIL_COUNT > 0 )); then
        exit 1
    fi
    exit 0
}

main "$@"
