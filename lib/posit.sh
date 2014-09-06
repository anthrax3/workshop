# Dispatches commands to other posit_(command|option) functions
posit () ( dispatch posit "$@" )

# Global option defaults
posit_files="*.test.sh"  # File name pattern for test files
posit_mode="tiny"        # Reporting mode to be used
posit_shell="sh"         # Shell used to tiny the isolated tests
posit_fast="-1"          # Fails fast. Use -1 to turn off
posit_silent="-1"        # Displays full stacks. Use -1 to turn off
posit_timeout="3s"

# Displays help
posit_command_help ()
{
	cat <<-HELP
	   Usage: posit [option_list...] [command]
	          posit help, -h, --help [command]  Displays help for command.

	Commands: run  [path]  Runs tests on the specified path.
	          list [path]  Lists the tests on the specified path.

	 Options: --report  [mode]    Changes the output mode.
	          --shell   [shell]   Changes the shell used for tests.
	          --files   [pattern] Inclusion pattern for test file lookup
	          --timeout [time]    Timeout for each single test
	          --fast,   -f        Stops on the first failed test.
	          --silent, -s        Don't collect stacks, just run them.

	   Modes: tiny   Uses a single line for the results.
	          spec   A complete report with the test names and statuses.
	          trace  The spec report including stack staces of failures.
	          cov    A code coverage report for the tests.

	HELP
}

# Option handlers
posit_option_help    () ( posit_command_help )
posit_option_h       () ( posit_command_help )
posit_option_shell   () ( posit_shell="$1";   shift && dispatch posit "$@" )
posit_option_files   () ( posit_files="$1";   shift && dispatch posit "$@" )
posit_option_timeout () ( posit_timeout="$1"; shift && dispatch posit "$@" )
posit_option_report  () ( posit_mode "$1" &&  shift && dispatch posit "$@" )
posit_option_f       () ( posit_fast="1";              dispatch posit "$@" )
posit_option_fast    () ( posit_fast="1";              dispatch posit "$@" )
posit_option_s       () ( posit_silent="1";            dispatch posit "$@" )
posit_option_silent  () ( posit_silent="1";            dispatch posit "$@" )

posit_     () ( echo "No command provided. Try 'posit --help'";return 1 )
poit_call_ () ( echo "Call '$1' invalid. Try 'poit --help'"; return 1)

# Lists tests in the specified target path
posit_command_list ()
{
	([ -f "$1" ] && posit_listfile "$1") ||
	([ -d "$1" ] && posit_listdir  "$1")
}

# Run tests for the specified target path
posit_command_run ()
{
	posit_command_list "$1" | # Lists all tests for the path
	posit_process "$1"      | # Processes the tests
	posit_all_${posit_mode}   # Post-processes the output
}

# Sets a reporting mode
posit_mode () 
{
	command -v "posit_unit_$1" 1>/dev/null 2>/dev/null

	if [ $? = 0 ]; then
		export posit_mode=$1
	else
		echo "Invalid mode '$1', try 'posit --help'." 1>&2
		return 1
	fi
}

# Run tests from a STDIN list
posit_process ()
{
	mode="$posit_mode"
	target="$1"
	passed_count=0
	total_count=0
	last_file=""
	current_file=""
	skipped_count="0"

	# Each line should have a file and a test function on that file
	while read test_parameters; do
		total_count=$((total_count+1))
		results= # Resets the results variable

		# Detects when tests should skip
		if [ "$skipped_count" -gt "0" ]; then
			skipped_count=$((skipped_count+1))
			posit_unit_$mode $test_parameters 3 "$results"
			continue
		fi

		# Stores the current test file name
		current_file="$(echo "$test_parameters" | sed 's/ .*//')"
		# Runs a test and stores results
		results="$(: | posit_exec_$mode $test_parameters)"
		# Stores the returned code
		returned=$?

		# Displays a header when the file changes
		[ "$current_file" != "$last_file" ] &&
		posit_head_$mode "$current_file"

		# Run the customized report
		posit_unit_$mode $test_parameters "$returned" "$results"

		if [ $returned = 0 ]; then
			passed_count=$((passed_count+1))
		elif [ "$posit_fast" = "1" ];then
			# Starts skipping if fail fast was enabled
			skipped_count=1
		fi

		last_file="$current_file"
	done

	# Display results counter
	posit_count_$mode $passed_count $total_count $skipped_count
	
	if [ "$passed_count" != "$total_count" ]; then
		return 1
	fi
}


# Executes a file on a function using an external shell process
posit_external ()
{
	shell="$posit_shell"
	test_command="$posit_shell"
	test_file="$1"
	test_dir="$(dirname "$1")"
	test_function="$2"
	filter="$3"
	tracer=""

	# If not silent
	if [ "$posit_silent" = "-1" ]; then
		tracer="$(depur $filter tracer "$shell")"  # Set up stack
		test_command="$shell -x"                   # Collect stack
	fi

	# If timeout command is present, use it
	if [ command -v timeout 2>/dev/null 1>/dev/null ]; then
		test_command="timeout $posit_timeout $test_command"
	fi

	# Declares env variables and executes the test in
	# another environment.
	PS4="$tracer"                   \
	POSIT_CMD="$shell"              \
	POSIT_FILE="$test_file"         \
	POSIT_DIR="$test_dir"           \
	POSIT_FUNCTION="$test_function" \
	$test_command <<-EXTERNAL
		# Compat options for zsh
		command -v setopt 2>/dev/null >/dev/null && 
		setopt PROMPT_SUBST SH_WORD_SPLIT

		setup    () ( : ) # Placeholder setup function
		teardown () ( : ) # Placeholder teardown function
		. "\$POSIT_FILE"  # Loads the tested file
		setup             # Calls the setup function
		\$POSIT_FUNCTION  # Calls the tested function
		has_passed=\$?    # Stores the result from the test
		teardown          # Calls the teardown function
		exit \$has_passed # Exits with the test status
	EXTERNAL
}

# Lists test functions for a specified dir
posit_listdir ()
{
	target_dir="$1"

	find "$target_dir" -type f -name "$posit_files" |
	while read test_file; do
		posit_listfile "$test_file"
	done
}

# Lists test functions in a single file
posit_listfile ()
{
	target_file="$1"
	signature="/^\(test_[a-zA-Z0-9_]*\)[	 ]*/p"

	cat "$target_file" | sed -n "$signature" | cut -d" " -f1 |
		while read line; do
			echo "$target_file $line"
		done
}


# Single execution for the "tiny" report
posit_exec_tiny () ( posit_external "$1" "$2" "--short" 2>/dev/null )
# Filter for the overall test output on mode "tiny"
posit_all_tiny  () ( cat )
# Header for each file report on mode "tiny"
posit_head_tiny () ( : )
# Report for each unit on mode "tiny"
posit_unit_tiny ()
{
	returned_code="$3"

	([ "$returned_code" = 0 ] && echo -n "." ) || # . for pass
	([ "$returned_code" = 3 ] && echo -n "S" ) || # S for skip
	echo -n "F"                                   # F for failure
}
# Count report for the "tiny" mode
posit_count_tiny ()
{
	passed="$1"
	total="$2"
	skipped="$3"

	([ "$total"   -gt 0 ] && echo -n " $passed/$total passed.") ||
	echo -n "No tests found."

	([ "$skipped" -gt 0 ] && echo -n " $skipped/$total skipped.")
	echo ""
}


# Executes a single test
posit_exec_spec () ( posit_external "$1" "$2" "--short" 2>&1 )
posit_count_spec () ( echo ""; echo -n "Totals:"; posit_count_tiny "$@" )
posit_all_spec () ( cat )
# Reports a test file
posit_head_spec ()
{
	cat <<-FILEHEADER

		### $1

	FILEHEADER
}
# Reports a single unit
posit_unit_spec ()
{
	test_file="$1"
	test_function="$2"
	returned="$3"
	results="$4"
	test_status="fail:"
		
	if [ $returned = 0 ]; then
		test_status="pass:"
	elif [ $returned = 3 ]; then
		test_status="skip:"
	else
		returned=1
	fi

	# Removes the 'test_' from the start of the name
	test_function=${test_function#test_}

	# Displays the test status and humanized test name
	# replacing _ to spaces
	echo "  - $test_status $test_function" | tr '_' ' '

	# Formats a stack trace with the test results
	if [ $returned = 1 ] && [ "$posit_silent" = "-1" ]; then
		echo "$results" | depur format
	fi
}

posit_exec_cov   () ( posit_external "$1" "$2" "--full" 2>&1 )
posit_all_cov    () ( depur coverage )
posit_head_cov   () ( : )
posit_unit_cov   () ( echo "$4" )
posit_count_cov  () ( posit_count_spec "$@" )