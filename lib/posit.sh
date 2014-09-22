# Dispatches commands to other posit_(command|option) functions
posit () ( dispatch posit "${@:-}" )

# Global option defaults
posit_files=".test.sh"  # File name pattern for test files
posit_functions="test_"
posit_mode="tiny"        # Reporting mode to be used
posit_shell="sh"         # Shell used to tiny the isolated tests
posit_fast="-1"          # Fails fast. Use -1 to turn off
posit_silent="-1"        # Displays full stacks. Use -1 to turn off
posit_timeout="3"        # Timeout for each test

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
	          --funcs   [pattern] Inclusion pattern for test function lookup
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
posit_option_f       () ( posit_fast="1";            dispatch posit "${@:-}" )
posit_option_fast    () ( posit_fast="1";            dispatch posit "${@:-}" )
posit_option_s       () ( posit_silent="1";          dispatch posit "${@:-}" )
posit_option_silent  () ( posit_silent="1";          dispatch posit "${@:-}" )
posit_option_shell   () ( posit_shell="$1";   shift; dispatch posit "${@:-}" )
posit_option_files   () ( posit_files="$1";   shift; dispatch posit "${@:-}" )
posit_option_timeout () ( posit_timeout="$1"; shift; dispatch posit "${@:-}" )
posit_option_report  () ( posit_mode="$1";    shift; dispatch posit "${@:-}" )
posit_option_funcs   ()
{
	posit_functions="$1"
	shift
	dispatch posit "${@:-}"
}

posit_      () ( echo "No command provided. Try 'posit --help'";return 1 )
posit_call_ () ( echo "Call '$*' invalid. Try 'posit --help'"; return 1)

# Lists tests in the specified target path
posit_command_list ()
{
	([ -f "$1" ] && posit_listfile "$1") ||
	([ -d "$1" ] && posit_listdir  "$1")
}

# Run tests for the specified target path
posit_command_run ()
{
	posit_command_list "$1"      | # Lists all tests for the path
	"posit_all_${posit_mode}" "$1"   # Processes the tests
}

# Run tests from a STDIN list
posit_process ()
{
	mode="$posit_mode"
	passed_count=0
	total_count=0
	last_file=""
	skipped_count="0"

	# Each line should have a file and a test function on that file
	while read test_parameters; do
		test_file="$(echo "$test_parameters" | cut -d " " -f1)"
		test_func="$(echo "$test_parameters" | cut -d " " -f2)"
		total_count=$((total_count+1))
		results='' # Resets the results variable
		previous_errmode="$(set +o | grep errexit)"
		skipped_return=3

		# Detects when tests should skip
		if [ "$skipped_count" -gt "0" ]; then
			skipped_count=$((skipped_count+1))
			"posit_unit_$mode" "$test_file" "$test_func"\
					   "$skipped_return" "$results"
			continue
		fi

		# Don't exit on errors
		set +e
		# Runs a test and stores results
		results="$(: | "posit_exec_$mode" "$test_file" "$test_func")"
		# Stores the returned code
		returned=$?
		# Restore previous error mode
		$previous_errmode

		# Displays a header when the file changes
		[ "$test_file" != "$last_file" ] &&
		"posit_head_$mode" "$test_file"

		# Run the customized report
		"posit_unit_$mode" "$test_file" "$test_func"\
				   "$returned" "$results"

		if [ $returned = 0 ]; then
			passed_count=$((passed_count+1))
		elif [ "$posit_fast" = "1" ];then
			# Starts skipping if fail fast was enabled
			skipped_count=1
		fi

		last_file="$test_file"
	done

	# Display results counter
	"posit_count_$mode" $passed_count $total_count $skipped_count

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
	test_func="$2"
	filter="$3"
	tracer=""

	# If not silent
	if [ "$posit_silent" = "-1" ]; then
		tracer="$(depur "$filter" tracer "$shell")"  # Set up stack
		test_command="$shell -x"                     # Collect stack
	fi

	# If timeout command is present, use it
	if [ "$posit_timeout" != 0 ] &&
	   command -v timeout 2>/dev/null 1>/dev/null; then

		# Checks if this timeout version uses -t for duration
		if [ z"$(timeout -t0 printf %s 2>&1)" != z"" ]; then
			test_command="timeout $posit_timeout $test_command"
		else
			test_command="timeout -t $posit_timeout $test_command"
		fi
	fi

	# Declares env variables and executes the test in
	# another environment.
	PS4="$tracer"                   \
	POSIT_CMD="$shell"              \
	POSIT_FILE="$test_file"         \
	POSIT_DIR="$test_dir"           \
	POSIT_FUNCTION="$test_func"     \
	$test_command <<-EXTERNAL
		# Compat options for zsh
		setopt PROMPT_SUBST SH_WORD_SPLIT >/dev/null 2>&1 || :

		setup    () ( : )   # Placeholder setup function
		teardown () ( : )   # Placeholder teardown function
		. "\$POSIT_FILE"    # Loads the tested file
		setup               # Calls the setup function
		\$POSIT_FUNCTION && # Calls the tested function
		has_passed=\$?   || # Stores the result from the test
		has_passed=\$?
		teardown            # Calls the teardown function
		exit \$has_passed   # Exits with the test status
	EXTERNAL
}

# Lists test functions for a specified dir
posit_listdir ()
{
	target_dir="$1"

	find "$target_dir" -type f |
	grep "$posit_files"        |
	while read test_file; do
		posit_listfile "$test_file"
	done
}

# Lists test functions in a single file
posit_listfile ()
{
	target_file="$1"
	signature="/^\(${posit_functions}[a-zA-Z0-9_]*\)[	 ]*/p"

	cat "$target_file"  |
	sed -n "$signature" |
	cut -d" " -f1       |
	while read line; do
		echo "$target_file $line"
	done
}

