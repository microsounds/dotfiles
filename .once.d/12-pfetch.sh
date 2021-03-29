#!/usr/bin/env sh

# install pfetch utility
# cute system information tool

TMP="/tmp/$(tr -cd 'a-z0-9' < /dev/urandom | dd bs=7 count=1 2> /dev/null)"
REPO='https://github.com/dylanaraps/pfetch'

finish() {
	rm -rf "$TMP"
	echo 'Done.'
	exit
}

trap finish 0 1 2 3 6

mkdir -v "$TMP"
if git clone "$REPO" "$TMP" || exit 1; then
	make -C "$TMP" install PREFIX="$HOME/.local"
fi
