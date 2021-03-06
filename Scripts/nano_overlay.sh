#!/usr/bin/env sh

## nano_overlay.sh v0.9 — interactive external overlay for GNU nano
## (c) 2021 microsounds <https://github.com/microsounds>, GPLv3+
##  -h, --help      Displays this message.

# interactive features will call another nano_overlay instance
# call first nano found in $PATH
EDITOR="$0"
ACTUAL_EDITOR='nano'
TEMP_DIR="${XDG_RUNTIME_DIR:-/tmp}"

# utilities
mesg_wipe() { printf '\r' 1>&2; }
mesg_st() { printf '%s%s' "${name:+[$name] }" "$1" 1>&2; } # for prompts
mesg() { mesg_st "$1"; printf '\n' 1>&2; }
quit() { mesg "$1, exiting." 1>&2; exit 1; }
announce() { echo "$@" 1>&2; "$@"; }

derive_parent() {
	# return parent dir if path has
	# ../relative/sub/dirs or is absolute path
	# return '.' if path is in the current dir
	case "$1" in
		*/*)
			path="${1%/*}"
			path="${path:-/}";; # if nothing left, assume '/'
	esac
	echo "${path:-.}"
}

mode_help() {
	$ACTUAL_EDITOR -h
	grep '^##' "$0" | sed 's/^## //'
}

## Search and jump to source code definitions provided by POSIX ctags(1).
##  -e <tag> <#>    If a ctags index file exists in the current or a parent
##  or --ctags      directory, search through it for '<tag>' and open the file
##                  containing it's definition.
##                  If multiple matches are found, specify line number <#>
##                  or 'all' to open all matches at once.

ex_parser() {
	# format: {tag}\t{filename}\t{ex command or line no}{;" extended}
	# follow ex editor commands and rewrite as line numbers
	IFS='	'; while read -r tag file addr; do
		# return 1 if line is malformed
		for f in tag file addr; do
			eval "[ ! -z \"\${$f}\" ]" || return 1
		done
		# absolute filename?
		[ "${file%${file#?}}" = '/' ] || file="$PWD/$file"
		printf '%s\t%s\t' "$tag" "$file"

		# if addr is not numeric, parse as ex command
		case "$addr" in [!0-9]*)
			# start/end delimiter can be one of '/' or '?'
			# delete text not contained within delimited zone
			de="${addr%"${addr#?}"}"
			addr="${addr#*"$de"}"; addr="${addr%"$de"*}"
			# strip optional regex anchors
			[ "${addr%"${addr#?}"}" = '^' ] && addr="${addr#^}"
			[ "${addr#"${addr%?}"}" = '$' ] && addr="${addr%$}"
			# strip escapes for slash \/ => /, backslash \\ => \
			addr="$(echo "$addr" | sed 's,\\/,/,g;s,\\\\,\\,g')"
			# return 2 if command is outdated
			addr="$(fgrep -n "$addr" < "$file")" || return 2;;
		esac
		echo "${addr%%[!0-9]*}"
	done < /dev/stdin
}

mode_ctags() {
	name='ctags'
	# find root directory containing ctags index
	# prefixes all relative filenames found
	while [ ! -z "$PWD" ] && [ ! -f "$PWD/tags" ]; do PWD="${PWD%/*}"; done
	[ ! -z "$PWD" ] ||
		quit 'No index found in this or any parent directories up to /'

	# validate index and get version
	ver="$(fgrep '!_TAG_FILE_FORMAT' < "$PWD/tags" | cut -f2)"
	case "$ver" in 1 | 2);; *) quit 'Index file is invalid'; esac

	[ ! -z "$1" ] || quit 'No tag query given'

	# session persistence
	unset matches
	backup="$TEMP_DIR/.${0##*/}-$name"
	if [ -f "${backup}-cached" ]; then
		read -r prev_query < "${backup}-query"
		read -r prev_hash < "${backup}-hash"
		[ "$prev_query" = "$1" ] &&
		[ "$prev_hash" = "$(md5sum < "$PWD/tags")" ] &&
		matches="$(cat "${backup}-cached")"
	fi

	# discarding previous session
	if [ -z "$matches" ]; then
		# cherry-pick matching lines based on first column
		# case insensitive substring search up to first literal tab
		matches="$(grep -v '^!_TAG_' < "$PWD/tags" | \
			egrep -i "^\\w*${1}\\w*	.*$")"

		# cache results for repeat invocations
		echo "$matches" > "${backup}-cached" &
		echo "$1" > "${backup}-query" &
		md5sum < "$PWD/tags" > "${backup}-hash" &
	fi
	[ ! -z "$matches" ] || quit "No matches found for $1"

	# multiple line match disambiguation
	num="$(echo "$matches" | wc -l)"
	if [ "$num" -gt 1 ]; then
		unset arg_ok
		if [ ! -z "$2" ]; then
			# special case 'all' opens all matching files
			case "$2" in
				all) arg_ok=1;;
			esac
			# if numeric argument is valid integer that's in range,
			# then cherry-pick desired line
			[ "$2" -eq "$2" ] 2> /dev/null &&
				[ "$2" -ge 1 ] && [ "$2" -le "$num" ] && arg_ok=1 &&
				matches="$(echo "$matches" | tail -n "+$2" | head -n 1)"
		fi
		# if no argument is passed, show listing and exit
		if [ -z "$arg_ok" ]; then
			mesg "Specify a match or use 'all' to select all matches." 1>&2
			i=1; echo "$matches" | while read -r line; do
				printf ' %d\t%s\n' "$i" "$line" 1>&2
				i=$((i + 1))
			done && exit 1
		fi
	fi

	# assemble final argument list
	matches="$(echo "$matches" | ex_parser)"
	case $? in
		1) quit "Index file is malformed";;
		2) quit "Index file is outdated";;
	esac
	set --
	for f in $(seq $(echo "$matches" | wc -l)); do
		line="$(echo "$matches" | tail -n "+$f" | head -n 1 | cut -f2-)"
		file="${line%	*}"; pos="${line#*	}"
		set -- "$@" "+$pos" "$file"
	done
	$EDITOR "$@"
}

## Open a password protected plaintext file for editing.
##  -f <filename>   Prompts the user for a AES encryption password.
##  or --encrypt    Decrypts file for editing, re-encrypts if file is modified.
##                  Creates file if it doesn't already exist.
##                  If the file exists but isn't encrypted, user will be
##                  prompted to overwrite the original file.
##                  * Scripts can provide the following environment variables
##                    to open the decrypted file using another command.
##                    eg. $EXTERN_EDITOR "$decrypted_file" $EXTERN_ARGS
##                  ** Requires OpenSSL 1.1.1 or later.

# mode_encrypt expected file format
# | [ openssl enc'd data ]
# | [ xz compressed data ]
# V [ plaintext file === ]

# compression settings
xz='xz -T0 -0'

# encryption settings
aes_magic='Salted__'
aes_crypt='openssl enc -aes-256-cbc -pbkdf2'
rsa_crypt='openssl rsautl -pkcs'
rsa_verify='openssl rsa -noout -text'

verify_header() {
	header="$(dd bs="${#1}" count=1)" < /dev/stdin 2> /dev/null
	case "$header" in
		"$1") return 0;;
		*) return 1;;
	esac
}

random_bytes() {
	# openssl chokes on keyfiles that start with NULL bytes
	printf '%b' '!'
	dd bs="$(($1 - 1))" count=1 < /dev/urandom 2> /dev/null
}
random_ascii() {
	{ tr -cd 'a-z0-9' | dd bs="$1" count=1; } < /dev/urandom 2> /dev/null
}

get_response() {
	stty -echo
	read -r res
	stty echo
	echo "$res"
}

prompt_user() {
	while read -r res; do
		case "$(echo "$res" | tr 'A-Z' 'a-z')" in
			y | yes) return 0;;
			n | no) return 1;;
		esac
		mesg_st "Please confirm (yes/no): "
	done
}

mode_encrypt() {
	name='encrypt'

	for f in "$@"; do
		# empty filename?
		[ ! -z "$f" ] || continue
		# file permissions
		for g in "$TEMP_DIR" "$(derive_parent "$f")"; do
			[ ! -w "$g" ] && quit "'$g' is unwritable"
		done

		# create non-colliding filename
		while :; do tmp="$TEMP_DIR/${f##*/}.$(random_ascii 7)"
			[ -f "$tmp" ] || break
		done

		# determine file state
		[ ! -f "$f" ] && state='new' # file doesn't exist yet
		if [ -f "$f" ]; then # is this an encrypted file?
			verify_header "$aes_magic" < "$f" && state='encrypted'
		fi
		# no state: file is plaintext, ask to overwrite when finished

		# obtain encryption password from user
		mesg_st "Password for '$f'${state:+ ($state)}: "
		export pass="$(get_response)" && printf '\n'
		if [ "$state" != 'encrypted' ]; then # verify password
			orig="$pass"
			mesg_st 'Verify password: '
			pass="$(get_response)" && printf '\n'
			[ "$orig" != "$pass" ] && quit 'Passwords do not match'
			unset orig
		fi

		# attempt file unpack
		trap 'rm -rf "$tmp"*' 0 1 2 3 6
		if [ "$state" = 'encrypted' ]; then
			{ $aes_crypt -pass 'env:pass' -d | $xz -d; } < "$f" > "$tmp" ||
				quit 'Invalid password'
			init="$(sha256sum < "$tmp")" # monitor changes
		fi
		[ -z "$state" ] && cat < "$f" > "$tmp" # copy existing file

		# default behavior: open plaintext file with restricted nano
		EDITOR="$EDITOR -R"
		# external script control: announce what is being done
		${EXTERN_EDITOR:+ announce} \
			${EXTERN_EDITOR:-$EDITOR} "$tmp" $EXTERN_ARGS

		# conditionally repack file on file change
		if [ -f "$tmp" ]; then
			if [ -z "$state" ]; then # no state: ask to overwrite original
				mesg_st "Overwrite original file '$f'? (yes/no): "
				prompt_user && state='ok'
			fi
			if [ ! -z "$state" ] && \
				[ "$init" != "$(sha256sum < "$tmp")" ]; then
				{ $xz -z | $aes_crypt -pass 'env:pass' -e; } \
					< "$tmp" > "${tmp}.1" && mv "${tmp}.1" "$f"
			fi
		fi
		unset pass state
	done
}

## Open an SSH RSA key pair protected plaintext file for editing.
##  -j <filename>  Same as above, but uses RSA asymmetric encryption to
##  or --rsa       generate keyfile using the current user's SSH RSA key pair.
##                 User will be prompted for RSA private key passphrase for
##                 decryption if needed.
##                 ** RSA private key must be in legacy PEM format.
##                    Use 'ssh-keygen -p -m pem' to convert to PEM as needed.

# mode_encrypt_rsa expected file format, filenames are significant
# | [ xz compressed data ========== ]
# | [ tar archive ================= ]
# |  | filenames: [ enc ]  [ key ] |
# |                  |        |
# | [ openssl enc'd data ] [ RSA encrypted keyfile ]
# | [ xz compressed data ] [ plain keyfile ======= ]
# V [ plaintext file === ]

mode_encrypt_rsa() {
	name='rsa'

	# RSA keypair constants
	rsa_private="$HOME/.ssh/id_rsa"
	rsa_public="${rsa_private}.pub.pkcs8"

	[ -f "$rsa_private" ] ||
		quit "Expected RSA private key at '$rsa_private'"

	read -r rsa_header < "$rsa_private"
	# on first run, convert existing keys to PEM format
	if [ "$rsa_header" != '-----BEGIN RSA PRIVATE KEY-----' ]; then
		mesg "Converting private key at '$rsa_private' to PEM format."
		announce ssh-keygen -f "$rsa_private" -p -m pem ||
			quit "'$rsa_private' is not a private key"
	fi
	if [ ! -f "$rsa_public" ]; then
		mesg "Creating PKCS8 public PEM key at '$rsa_public'"
		announce ssh-keygen -f "$rsa_private" -e -m pkcs8 > "$rsa_public"
	fi

	# sanity check, obtain key length
	rsa_bits="$($rsa_verify -pubin -in "$rsa_public" \
		| egrep -o '[0-9]+' | head -n 1)"
	[ $rsa_bits -ge 1024 ] && [ $rsa_bits -le 16384 ] ||
		quit "Could not obtain RSA key length for '$rsa_private'"

	for f in "$@"; do
		# empty filename?
		[ ! -z "$f" ] || continue
		# file permissions
		for g in "$TEMP_DIR" "$(derive_parent "$f")"; do
			[ ! -w "$g" ] && quit "'$g' is unwritable"
		done

		# create non-colliding directory name
		while :; do tmp="$TEMP_DIR/${f##*/}.$(random_ascii 7)"
			[ -d "$tmp" ] || break
		done

		# determine file state
		[ ! -f "$f" ] && state='new' # file doesn't exist yet
		if [ -f "$f" ]; then # is this an encrypted file?
			{ $xz -d | tar -xO enc; } < "$f" 2> /dev/null | \
				verify_header "$aes_magic" && state='encrypted'
		fi
		# no state: file is plaintext, ask to overwrite when finished

		# attempt file unpack
		trap 'rm -rf "$tmp"*' 0 1 2 3 6
		mkdir -p "$tmp"
		mkfifo -m 600 "$tmp/pipe"
		if [ "$state" = 'encrypted' ]; then
			mesg_st 'Decrypting... '

			# write decrypted keyfile to pipe
			{	$xz -d | tar -xO key | \
				$rsa_crypt -inkey "$rsa_private" -decrypt ||
					quit 'Invalid private key or key not in PEM format'
			} < "$f" > "$tmp/pipe" &
			{	$xz -d | tar -xO enc | \
				$aes_crypt -pass "file:$tmp/pipe" -d | $xz -d ||
					quit 'Invalid passfile'
			} < "$f" > "$tmp/enc"
			init="$(sha256sum < "$tmp/enc")" # monitor changes
			mesg_wipe
		fi
		[ -z "$state" ] && cat < "$f" > "$tmp/enc" # copy existing file

		# default behavior: open plaintext file with restricted nano
		EDITOR="$EDITOR -R"
		# external script control: announce what is being done
		${EXTERN_EDITOR:+ announce} \
			${EXTERN_EDITOR:-$EDITOR} "$tmp/enc" $EXTERN_ARGS

		# conditionally repack file on file change
		if [ -f "$tmp/enc" ]; then
			if [ -z "$state" ]; then # no state: ask to overwrite original
				mesg_st "Overwrite original file '$f'? (yes/no): "
				prompt_user && state='ok'
			fi
			if [ ! -z "$state" ] && \
				[ "$init" != "$(sha256sum < "$tmp/enc")" ]; then
				mesg_st 'Saving to disk... '

				# create new keyfile to match key length - PKCS1 padding
				# write decrypted keyfile to pipe
				{	random_bytes "$(((rsa_bits / 8) - 11))" \
						| tee "$tmp/pipe" \
						| $rsa_crypt -pubin -inkey "$rsa_public" -encrypt ||
							quit 'Public key not in PEM format'
				} > "$tmp/key" &

				# repack file in place, abort if interrupted
				{	rm "$tmp/enc"
					$xz -z | $aes_crypt -pass "file:$tmp/pipe" -e > "$tmp/enc" ||
						quit 'Interrupted or write error'
				} < "$tmp/enc"
				tar -cC "$tmp" enc key \
					| $xz -z > "$tmp/new" && mv "$tmp/new" "$f"
				mesg_wipe
			fi
		fi
		unset state
	done
}

name='overlay'
# overlay command line options
if [ ! -z "$1" ]; then
	# steal switches previously unused by GNU nano 3.x and earlier
	for f in $(echo "$1" | grep '^-' | sed 's/^\-*//'); do
		case $f in
			h | help) mode_help 1>&2 && exit 1;;
			e | ctags) shift && mode_ctags "$@" && exit;;
			f | encrypt) shift && mode_encrypt "$@" && exit;;
			j | rsa) shift && mode_encrypt_rsa "$@" && exit;;
		esac
	done
fi

# housekeeping
# incrementally purge stale entries from filepos_history
for f in "$HOME/.nano" "$XDG_DATA_HOME/nano"; do
	hist="$f/filepos_history"
	[ -f "$hist" ] || continue
	# after 5 minutes of inactivity, drop one line per minute elapsed
	delta=$(($(date '+%s') - $(stat -c '%Y' "$hist")))
	if [ $delta -gt 300 ]; then
		line=$(((delta - 300) / 60))
		{ rm "$hist"; tail -n "+$line" > "$hist"; } < "$hist"
	fi
	break
done &

# housekeeping
# append options/refuse to open certain files
unset seeks opt
for f in "$@"; do case "$f" in
	-*);; # don't act on flags
	+[0-9]*)
		# mode_ctags: avoid creating lockfiles when seeking multiple files
		# the same file might be opened multiple times at different positions
		# open in view-only mode to avoid lockfile warnings on the same file
		# nano versions before 4.8 will ignore this and create lockfiles anyway
		seeks=$((seeks + 1)) && [ "$seeks" -gt 1 ] && opt="${opt}v";;
	*)
		# opening a directory by mistake
		[ -d "$f" ] && quit "'$f' is a directory"
		# force line numbers on large files
		[ -r "$f" ] && [ $(wc -l < "$f") -gt 500 ] && opt="${opt}l"
		# refuse to open if a valid lockfile exists
		lock="$(derive_parent "$f")/.${f##*/}.swp"
		if [ -f "$lock" ]; then
			# remove stale lockfile if pid at bytes 24-27 doesn't exist
			pid=$(dd bs=3 skip=8 count=1 < "$lock" 2> /dev/null | \
				od -t d -A n | tr -d ' ')
			if [ "$pid" -eq "$pid" ] 2> /dev/null; then # valid pid
				! ps -p "$pid" > /dev/null || quit "'$f' already in use"
			fi
			rm -f "$lock"
		fi
esac; done

wait
exec $ACTUAL_EDITOR ${opt:+-$(echo "$opt" | tr -s 'a-z')} "$@"
