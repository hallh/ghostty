#!/bin/bash

set -e

# Parse command line arguments
skip_tests=false
show_help=false
test_filter=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--skip-tests)
            skip_tests=true
            shift
            ;;
        -f|--filter)
            if [[ -z "$2" || "$2" =~ ^- ]]; then
                echo "Error: --filter requires a value"
                show_help=true
                shift
            else
                test_filter="$2"
                shift 2
            fi
            ;;
        -h|--help)
            show_help=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            show_help=true
            shift
            ;;
    esac
done

if [ "$show_help" = true ]; then
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Run coverage tests and analyze coverage gaps in changed files."
    echo ""
    echo "Options:"
    echo "  -s, --skip-tests       Skip running tests, use existing coverage data"
    echo "  -f, --filter PATTERN   Filter tests by pattern (passed to zig build test -Dtest-filter=PATTERN)"
    echo "  -h, --help             Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                           # Run all tests with coverage"
    echo "  $0 --skip-tests              # Skip tests, analyze existing coverage"
    echo "  $0 --filter \"terminal\"       # Run only tests matching 'terminal'"
    echo "  $0 -f config --skip-tests    # Skip tests, but show filter would be 'config'"
    echo ""
    exit 0
fi

echo "Checking code formatting..."
if ! zig fmt --check . >/dev/null 2>&1; then
    echo "❌ Code formatting check failed. Please run 'zig fmt .' to fix formatting issues."
    exit 1
fi
echo "✅ Code formatting check passed."

if [ "$skip_tests" = false ]; then
    if [ -n "$test_filter" ]; then
        echo "Running coverage tests (filtered: '$test_filter')..."
        zig build test -Dtest-coverage -Dtest-filter="$test_filter" 2>/dev/null
    else
        echo "Running coverage tests..."
        zig build test -Dtest-coverage 2>/dev/null
    fi
else
    if [ -n "$test_filter" ]; then
        echo "Skipping test execution (filter '$test_filter' would have been applied), using existing coverage data..."
    else
        echo "Skipping test execution, using existing coverage data..."
    fi
    # Check if cobertura file exists (try both relative paths)
    if [ -f "kcov-output/ghostty-test/cobertura.xml" ]; then
        cobertura_path="kcov-output/ghostty-test/cobertura.xml"
    elif [ -f "../kcov-output/ghostty-test/cobertura.xml" ]; then
        cobertura_path="../kcov-output/ghostty-test/cobertura.xml"
    else
        echo "Error: cobertura.xml not found"
        echo "Expected at: kcov-output/ghostty-test/cobertura.xml (from root) or ../kcov-output/ghostty-test/cobertura.xml (from agents/)"
        echo "Run the script without -s/--skip-tests to generate coverage data first."
        exit 1
    fi
fi

echo "Parsing coverage data..."
# Determine script directory and cobertura path
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "kcov-output/ghostty-test/cobertura.xml" ]; then
    cobertura_path="kcov-output/ghostty-test/cobertura.xml"
    python_script="$script_dir/parse-corbertura.py"
elif [ -f "../kcov-output/ghostty-test/cobertura.xml" ]; then
    cobertura_path="../kcov-output/ghostty-test/cobertura.xml" 
    python_script="./parse-corbertura.py"
else
    echo "Error: cobertura.xml not found"
    exit 1
fi
coverage_output=$(uv run --with tabulate "$python_script" "$cobertura_path")
if [ -n "$test_filter" ]; then
    echo ""
    echo "⚠️  WARNING: Coverage report may be inaccurate!"
    echo "   Only tests matching filter '$test_filter' were executed."
    echo "   Full coverage requires running all tests without filters."
fi
echo ""

echo "Analyzing coverage gaps in changed files..."
echo "=========================================="

# Function to parse uncovered lines from coverage output
parse_uncovered_lines() {
    local file="$1"
    local uncovered_str="$2"
    
    if [ "$uncovered_str" = "*" ]; then
        echo "all"
        return
    fi
    
    if [ -z "$uncovered_str" ]; then
        echo ""
        return
    fi
    
    # Convert ranges like "40,42,87-88,91-93" to individual line numbers
    echo "$uncovered_str" | tr ',' '\n' | while IFS= read -r range; do
        if [[ "$range" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            # Range like "87-88"
            start=${BASH_REMATCH[1]}
            end=${BASH_REMATCH[2]}
            seq "$start" "$end"
        else
            # Single number like "40"
            echo "$range"
        fi
    done | sort -n
}

# Function to parse changed lines from git diff
get_changed_lines() {
    local file="$1"
    git diff -U0 "$file" | grep '^@@' | while IFS= read -r line; do
        # Parse @@ -old_start,old_count +new_start,new_count @@
        if [[ "$line" =~ @@\ -[0-9]+(,[0-9]+)?\ \+([0-9]+)(,([0-9]+))?\ @@ ]]; then
            new_start=${BASH_REMATCH[2]}
            new_count=${BASH_REMATCH[4]:-1}
            
            # Generate line numbers for the new/changed lines
            if [ "$new_count" -gt 0 ]; then
                seq "$new_start" $((new_start + new_count - 1))
            fi
        fi
    done | sort -n | uniq
}

# Function to check if lines intersect
lines_intersect() {
    local changed_lines="$1"
    local uncovered_lines="$2"
    
    if [ "$uncovered_lines" = "all" ]; then
        echo "yes"
        return
    fi
    
    if [ -z "$uncovered_lines" ] || [ -z "$changed_lines" ]; then
        echo "no"
        return
    fi
    
    # Use grep approach instead of comm to avoid sorting issues
    local intersection=$(echo "$changed_lines" | grep -F -x "$uncovered_lines" 2>/dev/null | head -1)
    if [ -n "$intersection" ]; then
        echo "yes"
    else
        # Try the other way around in case of formatting differences
        local found=false
        while IFS= read -r line; do
            if [ -n "$line" ] && echo "$uncovered_lines" | grep -q "^${line}$"; then
                found=true
                break
            fi
        done <<< "$changed_lines"
        
        if [ "$found" = true ]; then
            echo "yes"
        else
            echo "no"
        fi
    fi
}

# Function to get intersection of lines
get_line_intersection() {
    local changed_lines="$1"
    local uncovered_lines="$2"
    
    if [ "$uncovered_lines" = "all" ]; then
        echo "$changed_lines"
        return
    fi
    
    if [ -z "$uncovered_lines" ] || [ -z "$changed_lines" ]; then
        return
    fi
    
    # Find intersection using grep
    while IFS= read -r line; do
        if [ -n "$line" ] && echo "$uncovered_lines" | grep -q "^${line}$"; then
            echo "$line"
        fi
    done <<< "$changed_lines"
}

# Function to format line ranges for output (similar to parse-corbertura.py)
format_line_ranges() {
    local lines="$1"
    
    if [ -z "$lines" ]; then
        echo ""
        return
    fi
    
    echo "$lines" | sort -n | awk '
    BEGIN { prev = -1; start = -1; ranges = "" }
    {
        if (prev == -1) {
            start = $1
            prev = $1
        } else if ($1 == prev + 1) {
            prev = $1
        } else {
            if (start == prev) {
                if (ranges != "") ranges = ranges ","
                ranges = ranges start
            } else {
                if (ranges != "") ranges = ranges ","
                ranges = ranges start "-" prev
            }
            start = $1
            prev = $1
        }
    }
    END {
        if (start != -1) {
            if (start == prev) {
                if (ranges != "") ranges = ranges ","
                ranges = ranges start
            } else {
                if (ranges != "") ranges = ranges ","
                ranges = ranges start "-" prev
            }
        }
        print ranges
    }'
}

# Get list of modified files from git
modified_files=$(git diff --name-only --diff-filter=M | grep -E '\.(zig|c|cpp|h)$' | grep '^src/' || true)

if [ -z "$modified_files" ]; then
    echo "No modified source files found."
    exit 0
fi

# Create temporary files to store coverage data
coverage_temp=$(mktemp)
echo "$coverage_output" > "$coverage_temp"

has_issues=false

for file in $modified_files; do
    # Get coverage info for this file
    coverage_line=$(grep "^$file " "$coverage_temp" || true)
    
    if [ -z "$coverage_line" ]; then
        echo "⚠️  $file: No coverage data available"
        has_issues=true
        continue
    fi
    
    # Parse coverage line: "src/file.zig    Coverage%    Uncovered"
    coverage_percent=$(echo "$coverage_line" | awk '{print $2}')
    uncovered_str=$(echo "$coverage_line" | awk '{for(i=3;i<=NF;i++) printf "%s%s", $i, (i<NF?" ":""); print ""}')
    
    # Get changed lines for this file
    changed_lines=$(get_changed_lines "$file")
    
    if [ -z "$changed_lines" ]; then
        continue
    fi
    
    # Get uncovered lines
    uncovered_lines=$(parse_uncovered_lines "$file" "$uncovered_str")
    
    # Check for intersection
    intersects=$(lines_intersect "$changed_lines" "$uncovered_lines")
    
    if [ "$intersects" = "yes" ]; then
        has_issues=true
        uncovered_changed_lines=$(get_line_intersection "$changed_lines" "$uncovered_lines")
        formatted_ranges=$(format_line_ranges "$uncovered_changed_lines")
        
        echo "❌ $file ($coverage_percent coverage): Changed lines lacking coverage: $formatted_ranges"
    fi
done

# Clean up
rm -f "$coverage_temp"

if [ "$has_issues" = false ]; then
    echo "✅ All changed lines in modified files have coverage!"
fi

echo ""
echo "Coverage analysis complete."
