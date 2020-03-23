#!/usr/bin/env sh

# xrandr_cycle.sh v0.1
# cycle between connected displays

get_field() { tr ' ' '\t' < '/dev/stdin' | cut -f$1; }
mark_array() { tr '\n' ' ' < '/dev/stdin' | sed "s/$1/\*&/g"; }
DISPLAYS="$(xrandr -q | grep '[^dis]connected')"
PRIMARY="$(echo "$DISPLAYS" | fgrep 'primary' | get_field 1)"
DISPLAYS="$(echo "$DISPLAYS" | get_field 1)"

if [ -z "$PRIMARY" ]; then
	PRIMARY="$(echo "$DISPLAYS" | head -1)"
	echo "No displays are primary, promoting $PRIMARY."
fi

echo "Displays found: $(echo "$DISPLAYS" | mark_array "$PRIMARY")"
i=0; for f in $DISPLAYS; do
	if [ "$f" = "$PRIMARY" ]; then
		SELECT=$(((i + 1) % $(echo "$DISPLAYS" | wc -l)))
		break
	fi
	i=$((i + 1))
done

SELECT="$(echo "$DISPLAYS" | tail -n +$((SELECT + 1)) | head -1)"
echo "Switching to $SELECT."
xrandr --output "$SELECT" --primary --auto
[ "$SELECT" != "$PRIMARY" ] && xrandr --output "$PRIMARY" --off