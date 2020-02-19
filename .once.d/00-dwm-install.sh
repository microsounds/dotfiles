#!/usr/bin/env sh
# git-submodule is ill-suited for installing suckless software
# git doesn't allow commits that contain pre-written .git/configs either

VER='6.2'

echo "$0"
cd ~/.config/dwm
git init
git remote add origin 'https://git.suckless.org/dwm'
if git fetch --tags origin master; then
	git checkout "$VER"
	for f in patches/*; do # do not undo patches
		patch -N < $f; rm -f *.rej
	done
	sudo make install -j $(grep -c 'proc' /proc/cpuinfo)
fi