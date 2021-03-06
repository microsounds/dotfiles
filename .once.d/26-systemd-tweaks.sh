#!/usr/bin/env sh

# collection of systemd tweaks

# limit systemd start/stop job timers to 10 seconds
for f in Start Stop; do
	conf-append "DefaultTimeout${f}Sec=10s" '/etc/systemd/system.conf'
done

# convert hybrid-sleep to act as hibernate+reboot
conf-append 'HybridSleepMode=reboot' '/etc/systemd/sleep.conf'
conf-append 'HibernateDelaySec=0s' '/etc/systemd/sleep.conf'

# allow unprivileged users to view kernel syslog
conf-append 'kernel.dmesg_restrict = 0' '/etc/sysctl.conf'
