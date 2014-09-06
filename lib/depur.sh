# Dispatches commands to other depur_ functions
depur () ( dispatch depur "$@" )

# Global option defaults
depur_trace_command=""  # Command to extract file/line info on stacks
depur_filter="basename" # Filter used on file names when showing a stack trace
depur_shell="sh"        # Shell used as interpreter

# Provides help
depur_command_help ()
{
	cat <<-HELP
	   Usage: depur [option_list...] [command]
	          depur help, -h, --help [command]  Displays help for command.

	Commands: run    [command] Runs and traces the given command.
	          tracer           Gets a tracer command for a shell.
	          format           Formats a stack trace from stdin.
	          coverage         Formats a trace from stdin into
	                           code coverage results.

	 Options: --shell [shell]  Changes the shell used for debugging.
	          --short, -s      Displays only the basename for paths.
	          --full,  -f      Displays complete paths for the trace.
	HELP
}

# Options
depur_option_f     () ( export depur_filter="echo";     dispatch depur "$@" )
depur_option_full  () ( export depur_filter="echo";     dispatch depur "$@" )
depur_option_s     () ( export depur_filter="basename"; dispatch depur "$@" )
depur_option_short () ( export depur_filter="basename"; dispatch depur "$@" )
depur_option_shell () ( export depur_shell="$1"; shift; dispatch depur "$@" )

depur_      () ( echo "No command provided. Try 'depur --help'"; return 1 )
depur_call_ () ( echo "Call '$1' invalid. Try 'depur --help'"; return 1)

# Runs a command and displays its stack trace
depur_command_run ()
{
	# Sets a tracer and run the command on a shell with -x
	PS4="$(depur_command_tracer "$depur_shell")" $depur_shell -x $@ 2>&1
}

# Sets and returns the tracer command to be used on PS4 prompts
depur_command_tracer ()
{
	if [ -z "$depur_trace_command" ]; then
		export depur_trace_command="$(depur_get_tracer "$1")"
	fi

	echo "$depur_trace_command"
}

# Parses a stack from the stdin and outputs its code coverage report
depur_command_coverage ()
{
	# Should contain a list of files and lines covered
	unsorted="$(depur_clean)"
	# Gets an unique list of files
	covered_files="$(echo "$unsorted" | cut -d"	" -f1 | sort | uniq)"

	# Loop all files listed in the stack
	for file in $covered_files; do
		file="$(echo "$file")"
		if [ ! -z "$file" ] && [ -f $file ]; then
			cat $file | depur_covfile "$file" "$unsorted"
			echo ""
		fi
	done
}

# Formats a stack into columns
depur_command_format ()
{
	echo ""
	# Removes the first line
	sed '1d' | 
	# Displays the stack in aligned columns
	awk 'BEGIN {FS=OFS="\t"}
	           { printf "        %-4s %-20s %-30s\n", $1, $2, $3}'
	echo ""
}

# Processes the code coverage for one file
depur_covfile ()
{
	file="$1"
	unsorted="$2"
	total_lines=0
	covered_lines=0
	traced_lines=0

	cat <<-FILEHEADER

		### $file

	FILEHEADER

	# Gets lines that were covered only for this file
	thisfile="$(echo "$unsorted" | grep "^$file")"

	while IFS='' read -r file_line; do
		total_lines=$((total_lines+1))
		# Full line text
		line="$(printf "%s\n" "$file_line" | tr '`' ' ')"
		# Number of matches on this line
		matched="$(echo "$thisfile"         |
			sed -n "/	$total_lines$/p" | 
			wc -l                       | 
			sed "s/[	 ]*//")"

		if [ $matched -gt 0 ]; then
			covered_lines="$((covered_lines+1))"
		fi
		# Formatted number of matched lines <tab> the file line
		covline="$(depur_covline "$total_lines" "$line" "$matched")"
		traced="$(echo "$covline" | 
			grep "^  \`-"     |
			wc -l             | 
			sed "s/[	 ]*//")"
		if [ $traced -gt 0 ]; then
			traced_lines=$((traced_lines+1))
		fi
		echo "$covline"
	done

	valid_lines=$(( total_lines - traced_lines ))

	if [ $valid_lines -gt 0 ]; then
		per=$((100*covered_lines/valid_lines))
	else
		per=0
	fi

	filename="$(basename "$file")"
	totals="$covered_lines/$valid_lines"

	echo ""
	echo "Total: $filename has $totals lines covered (${per}%)."
	IFS= # Restore separator
}


# Cleans up a coverage line before displaying it
depur_covline ()
{
	lineno="$1"          # Current line number on file
	line="$2"            # Full line text
	matched="$3"         # How many cover matches
	ws="[	 ]*"         # Pattern to look for whitespace
	alnum="[a-zA-Z0-9_]" # Pattern to look for alnum

	# Ignore comment lines
	if [ -z "$(echo "$line" | sed "/^${ws}#/d")" ]                 ||
	# Ignore lines with only a '{'
	   [ -z "$(echo "$line" | sed "/^${ws}{${ws}$/d")" ]           ||
	# Ignore lines with only a '}'
	   [ -z "$(echo "$line" | sed "/^${ws}}${ws}$/d")" ]           ||
	# Ignore lines with only a 'fi'
	   [ -z "$(echo "$line" | sed "/^${ws}fi${ws}$/d")" ]          ||
	# Ignore lines with only a 'done'
	   [ -z "$(echo "$line" | sed "/^${ws}done${ws}$/d")" ]        ||
	# Ignore lines with only a 'else'
	   [ -z "$(echo "$line" | sed "/^${ws}else${ws}$/d")" ]        ||
	# Ignore lines with only a function declaration
	   [ -z "$(echo "$line" | sed "/^${ws}${alnum}*${ws}()${ws}$/d")" ] ||
	# Ignore blank lines
	   [ -z "$(echo "$line" | sed "/^${ws}$/d")" ]; then
		echo "> \`-	$line\`  "
		return
	fi

	echo "> \`$matched	${line}\`"
}

# Cleans up a stack
depur_clean ()
{
	# Remove non-stack lines (stack lines start with +) 
	sed '/^[^+]/d'  |
	# Gets only the file:lineno column
	cut -d"	" -f2   | 
	# Removes empty lines and lines without file names,
	# change the : into a tab.
	sed '/^:/d;   /^[	 ]*$/d;   s/:/	/' 
}

# Returns the command tracer without caching it
depur_get_tracer ()
{
	shell="$1"
	filter="${depur_filter}"

	$shell <<-EXTERNAL 2>/dev/null
	if [ z"\$BASH_VERSION" != z ]; then
		echo "+	\\\$($filter \"\\\${BASH_SOURCE}\"):\\\${LINENO:-0}	"
	elif [ z"\$(echo "\$KSH_VERSION" | sed -n '/93/p')" != z ]; then
		echo "+	\\\$($filter \"\\\${.sh.file}\"):\\\${LINENO:-0}	"
	elif [ z"\$ZSH_VERSION" != z ]; then
		echo "+	\\\$($filter \\\${(%):-%x:%I})	"
	else
		echo "+	:\\\${LINENO:-0}	" # Fallback
	fi
	EXTERNAL
}