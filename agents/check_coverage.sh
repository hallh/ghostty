#!/bin/bash

set -e

# Parse command line arguments
skip_tests=false
show_help=false
test_filter=""
compare_main=false

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
        -m|--compare-main)
            compare_main=true
            shift
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
    echo "  -m, --compare-main     Compare against main branch instead of workspace changes"
    echo "  -h, --help             Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                           # Run all tests with coverage"
    echo "  $0 --skip-tests              # Skip tests, analyze existing coverage"
    echo "  $0 --filter \"terminal\"       # Run only tests matching 'terminal'"
    echo "  $0 -f config --skip-tests    # Skip tests, but show filter would be 'config'"
    echo "  $0 --compare-main            # Check changed/added files vs main branch"
    echo "  $0 -m -s                     # Compare vs main, skip tests"
    echo ""
    exit 0
fi

echo "Checking code formatting..."
if ! zig fmt --check . >/dev/null 2>&1; then
    echo "❌ Code formatting check failed. Please run 'zig fmt .' to fix formatting issues."
    exit 1
fi
echo "✅ Code formatting check passed."

echo "Run build..."
if ! zig build >/dev/null 2>&1; then
    echo "❌ Build failed. Please run 'zig build' to fix build issues."
    exit 1
fi
echo "✅ Build passed."

if [ "$skip_tests" = false ]; then
    # Create temporary file to capture output
    test_output_file=$(mktemp)
    
    if [ -n "$test_filter" ]; then
        echo "Running coverage tests (filtered: '$test_filter')..."
        echo "Command: zig build test -Dtest-coverage -Dtest-filter=\"$test_filter\""
        
        # Run the command and capture both stdout and stderr
        set +e  # Temporarily disable exit on error
        zig build test -Dtest-coverage -Dtest-filter="$test_filter" > "$test_output_file" 2>&1
        test_exit_code=$?
        set -e  # Re-enable exit on error
    else
        echo "Running coverage tests..."
        echo "Command: zig build test -Dtest-coverage"
        
        # Run the command and capture both stdout and stderr
        set +e  # Temporarily disable exit on error
        zig build test -Dtest-coverage > "$test_output_file" 2>&1
        test_exit_code=$?
        set -e  # Re-enable exit on error
    fi
    
    # Always show some output so user knows what happened
    echo "Test command completed with exit code: $test_exit_code"
    
    if [ $test_exit_code -ne 0 ]; then
        echo ""
        echo "❌ Tests failed with exit code $test_exit_code"
        echo ""
        echo "=== Test output ==="
        cat "$test_output_file"
        echo "=== End test output ==="
        
        # Clean up temp file before exiting
        rm -f "$test_output_file"
        exit $test_exit_code
    else
        echo "✅ Tests passed successfully"
        # Show last few lines of output for confirmation
        echo ""
        echo "=== Last 10 lines of test output ==="
        tail -n 10 "$test_output_file"
        echo "=== End test output ==="
    fi
    
    # Clean up temp file
    rm -f "$test_output_file"
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

if [ "$compare_main" = true ]; then
    echo "Analyzing coverage gaps in files changed vs main branch..."
else
    echo "Analyzing coverage gaps in changed files..."
fi
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
    local compare_against_main="$2"
    
    # Check if file is untracked (new file)
    if git ls-files --others --exclude-standard | grep -q "^${file}$"; then
        # For untracked files, all lines are "changed"
        if [ -f "$file" ]; then
            wc -l < "$file" | xargs seq 1
        fi
        return
    fi
    
    if [ "$compare_against_main" = true ]; then
        # Try different comparison strategies for compare-main mode
        if git show main:"$file" >/dev/null 2>&1; then
            # File exists in main, compare against it
            git diff -U0 main -- "$file" | grep '^@@' | while IFS= read -r line; do
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
        else
            # File doesn't exist in main (new file), all lines are changed
            if [ -f "$file" ]; then
                wc -l < "$file" | xargs seq 1
            fi
        fi
    else
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
    fi
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
if [ "$compare_main" = true ]; then
    # Get all files that differ from main: committed changes + staged + unstaged + untracked
    committed_files=$(git diff --name-only main...HEAD --diff-filter=AM | grep -E '\.(zig|c|cpp|h)$' | grep '^src/' || true)
    staged_files=$(git diff --name-only --cached | grep -E '\.(zig|c|cpp|h)$' | grep '^src/' || true)
    unstaged_files=$(git diff --name-only | grep -E '\.(zig|c|cpp|h)$' | grep '^src/' || true)
    untracked_files=$(git ls-files --others --exclude-standard | grep -E '\.(zig|c|cpp|h)$' | grep '^src/' || true)
    
    # Combine all file lists and remove duplicates
    modified_files=$(printf "%s\n%s\n%s\n%s\n" "$committed_files" "$staged_files" "$unstaged_files" "$untracked_files" | grep -v '^$' | sort -u || true)
    files_description="changed/added source files vs main branch"
else
    modified_files=$(git diff --name-only --diff-filter=M | grep -E '\.(zig|c|cpp|h)$' | grep '^src/' || true)
    files_description="modified source files"
fi

if [ -z "$modified_files" ]; then
    echo "No $files_description found."
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
    changed_lines=$(get_changed_lines "$file" "$compare_main")
    
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
