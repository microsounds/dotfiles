#!/usr/bin/env sh

# git_status.sh v0.4
# returns repo name, ⎇ branch name, and status indicators in the form '±repo:branch*'
# '-e' double-escapes ANSI escape codes for use in shell prompts
# '-n' strips color output

# colors
clean='\e[1;32m'
staged='\e[1;33m'
dirty='\e[1;31m'
alt='\e[1;36m'
reset='\e[0m'

data="$(git status -b --porcelain 2> /dev/null)"
if [ $? -eq 0 ]; then
	# repo name
	repo="$(git rev-parse --show-toplevel)"
	# branch info
	info="$(echo "$data" | head -1 | \
	        sed -e 's/ahead /+/' -e 's/behind /-/' | tr '#.,[] ' '\n' | grep .)"
	for f in $(echo "$info" | head -1); do
		case $f in
			# detached head mode
			HEAD) branch="$(cut -c -7 "$repo/.git/HEAD")";;
			# no commits yet
			No) [ ! -z "$(ls "$repo/.git/refs/heads")" ] && branch="$f" || branch="<init>";;
			*) # normal mode
				branch="$f" # obtain upstream info if it exists
				if [ $(echo "$info" | wc -l) -ge 3 ]; then
					# ignores stupid branch names (eg. '+1')
					for g in $(echo "$info" | tail -n +3); do
						case $g in \+* | -*) ups="$ups $g";; esac
					done
				fi
		esac
	done
	# index/work-tree state
	color="$clean" # default
	state="$(echo "$data" | tail -n +2 | cut -c -2)"
	[ ! -z "$(echo "$state" | cut -c 1 | tr -d '? ')" ] && color="$staged" && bits="$bits+"
	[ ! -z "$(echo "$state" | cut -c 2 | tr -d '? ')" ] && color="$dirty" && bits="$bits*"
	echo "$state" | grep -q '?' && color="$dirty" && bits="$bits%" # untracked files
	echo "$state" | grep -q 'U' && branch="<!>$branch" # merge conflict
	[ -f "$repo/.git/refs/stash" ] && bits="^$bits" # stash exists
	if [ ! -z "$1" ]; then for f in $(echo "${1#-}" | sed 's/./& /g'); do case $f in
		e) color="\[$color\]" && alt="\[$alt\]" && reset="\[$reset\]";;
		n) unset color alt reset;;
	esac; done; fi
	echo "$color±${repo##*/}:$branch$bits$alt$ups$reset"
fi
