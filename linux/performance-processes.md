# CPU, memory, disk I/O, and processes

RHEL 8, 9, and 10. Commands are read-only unless marked `CHANGE`. Some need the `sysstat` package (`iostat`, `mpstat`, `pidstat`, `sar`).

## Quick triage

Run these in order. Together they take under a minute.

```bash
uptime                        # load averages over 1, 5, 15 minutes
vmstat 2 5                    # run queue, memory, swap, I/O wait
mpstat -P ALL 2 3             # per-CPU usage
free -h
iostat -xz 2 3                # per-device I/O
ps -eo pid,user,%cpu,%mem,stat,etime,cmd --sort=-%cpu | head -15
ps -eo pid,user,%cpu,%mem,rss,cmd --sort=-rss | head -15
journalctl -k -b | grep -Ei 'oom|hung task|soft lockup' | tail
```

Load average is the number of runnable tasks plus tasks in uninterruptible sleep (`D` state). A load of 8 on an 8-CPU host is busy, not broken. A high load with idle CPU usually means tasks blocked on I/O or NFS.

## vmstat columns

| Column | Meaning | Concern when |
| --- | --- | --- |
| `r` | Runnable tasks | Consistently above CPU count |
| `b` | Tasks blocked on I/O | Consistently above 0 |
| `si`, `so` | Swap in/out per second | Non-zero for long periods |
| `us`, `sy` | User and system CPU | `sy` high: kernel work, often I/O or many syscalls |
| `wa` | CPU waiting for I/O | High with low `us`: storage bottleneck |
| `st` | Stolen by the hypervisor | Above a few percent: host contention |

## CPU

```bash
top -o %CPU                   # interactive; press 1 for per-CPU, H for threads
pidstat -u 2 5                # per-process CPU over time
pidstat -t -p <pid> 2 5       # per-thread
perf top                      # where CPU time is spent (perf package; needs root)
```

## Memory

```bash
free -h                       # use the "available" column, not "free"
cat /proc/meminfo | grep -Ei 'MemAvailable|Committed_AS|SwapTotal|SwapFree|HugePages_Total'
ps -eo pid,rss,vsz,cmd --sort=-rss | head
smem -tk 2>/dev/null | tail   # proportional set size, if smem is installed
journalctl -k | grep -i 'killed process'   # OOM killer victims
systemd-cgtop                 # memory and CPU by cgroup (service or container)
```

Linux uses free memory for cache. Low "free" with high "available" is normal. Pressure shows as falling "available," swap activity, and OOM kills.

An OOM kill message names the victim and its memory use. The process that triggered the OOM is not always the one killed. A systemd `MemoryMax=` limit or a container limit can OOM-kill inside a cgroup while the host has free memory; `systemctl status <unit>` then shows `Result: oom-kill`.

## Disk I/O

```bash
iostat -xz 2 5                # per device
pidstat -d 2 5                # per process I/O
iotop -o                      # interactive per-process I/O (iotop package)
```

| `iostat -x` field | Meaning |
| --- | --- |
| `r/s`, `w/s` | Read and write operations per second |
| `rkB/s`, `wkB/s` | Throughput |
| `r_await`, `w_await` | Average latency in milliseconds, including queue time |
| `aqu-sz` | Average queue length |
| `%util` | Time the device was busy. Near 100% on a single disk means saturated; less meaningful on SAN and NVMe. |

## Processes

```bash
ps -ef --forest               # process tree
ps -o pid,ppid,user,stat,etime,cmd -p <pid>
pgrep -a nginx                # PIDs and command lines by name
cat /proc/<pid>/status        # state, memory, threads, capabilities
ls -l /proc/<pid>/cwd /proc/<pid>/exe
cat /proc/<pid>/limits        # open files and other limits
ls /proc/<pid>/fd | wc -l     # open file descriptors
lsof -p <pid> | head
strace -f -p <pid> -e trace=network,file -s 200 2>&1 | head -50   # caution: attaches a tracer and slows the process
```

Process states in `ps` `STAT`:

| State | Meaning |
| --- | --- |
| `R` | Running or runnable |
| `S` | Interruptible sleep (normal idle) |
| `D` | Uninterruptible sleep, usually I/O. Cannot be killed until the I/O returns. |
| `Z` | Zombie: exited, parent has not collected it. Fix the parent. |
| `T` | Stopped |

`Too many open files` means the process hit its `nofile` limit. Check `/proc/<pid>/limits`. For a systemd service, raise `LimitNOFILE=` in a drop-in (`CHANGE`), not `/etc/security/limits.conf`, which applies only to login sessions.

Stopping processes:

```bash
kill <pid>                    # CHANGE: SIGTERM, lets the process clean up
kill -9 <pid>                 # CHANGE: SIGKILL, immediate; last resort
systemctl kill --signal=SIGHUP <unit>   # CHANGE: signal a service through systemd
```

Prefer `systemctl stop` or `restart` for services so systemd tracks the state.

## History with sar

`sysstat` collects data every 10 minutes when its timer is enabled.

```bash
sar -u                        # CPU today
sar -r                        # memory
sar -d -p                     # disks with device names
sar -n DEV                    # network interfaces
sar -q                        # run queue and load
sar -u -f /var/log/sa/saDD    # a previous day (DD = day of month)
```

## Cautions

- `perf`, `strace`, and `gcore` add overhead. Use them briefly on production.
- `kill -9` skips cleanup. Data in flight can be lost.
- `echo 3 > /proc/sys/vm/drop_caches` (`CHANGE`) does not fix memory pressure; it only discards cache and slows the system while cache refills.
