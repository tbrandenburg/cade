# M0 Host Milestone Report

Evidence captured for Phase 1 / Milestone M0 host readiness, per the
evidence standard in `docs/INITIAL.md` Section 3 Rule 2 and
`docs/plan/plan.md` line 88 / 595.

- **Timestamp (UTC):** 2026-08-28T10:46:24Z

## Sandbox constraint

Execution happens in a non-rebootable WSL2-based sandbox/container
(`Chassis: container`, `Virtualization: wsl`), not a real, rebootable target
host. A reboot step is therefore not applicable and is documented here as an
explicit constraint rather than silently omitted.

## Host information

Command: `uname -a`

```
Linux LUD-C-000JA 6.18.33.2-microsoft-standard-WSL2 #1 SMP PREEMPT_DYNAMIC Thu Jun 18 21:54:43 UTC 2026 x86_64 x86_64 x86_64 GNU/Linux
```

Command: `hostnamectl`

```
 Static hostname: LUD-C-000JA
       Icon name: computer-container
         Chassis: container ☐
      Machine ID: f812f5cc56e24ae986c1c57f2d78555a
         Boot ID: 5266f87c186b4cc6a88e8e8c3322e039
  Virtualization: wsl
Operating System: Ubuntu 24.04.2 LTS
          Kernel: Linux 6.18.33.2-microsoft-standard-WSL2
    Architecture: x86-64
```

Command: `hostname`

```
LUD-C-000JA
```

## Docker / Compose versions

Command: `docker --version`

```
Docker version 29.1.3, build f52814d
```

Command: `docker compose version`

```
Docker Compose version v2.40.3-desktop.1
```

## CPU

Command: `nproc`

```
16
```

## Memory

Command: `free -h`

```
               total        used        free      shared  buff/cache   available
Mem:            15Gi       2.0Gi       7.8Gi       5.3Mi       5.9Gi        13Gi
Swap:          4.0Gi          0B       4.0Gi
```

## Free disk space

Command: `df -h`

```
Filesystem                                Size  Used Avail Use% Mounted on
none                                      7.8G     0  7.8G   0% /usr/lib/modules/6.18.33.2-microsoft-standard-WSL2
none                                      7.8G  4.0K  7.8G   1% /mnt/wsl
drivers                                   952G  586G  367G  62% /usr/lib/wsl/drivers
/dev/sdd                                 1007G  228G  729G  24% /
none                                      7.8G  132K  7.8G   1% /mnt/wslg
none                                      7.8G     0  7.8G   0% /usr/lib/wsl/lib
rootfs                                    7.8G  2.8M  7.8G   1% /init
none                                      7.8G  940K  7.8G   1% /run
none                                      7.8G     0  7.8G   0% /run/lock
none                                      7.8G     0  7.8G   0% /run/shm
none                                      7.8G   80K  7.8G   1% /mnt/wslg/versions.txt
none                                      7.8G   80K  7.8G   1% /mnt/wslg/doc
C:\                                       952G  586G  367G  62% /mnt/c
snapfuse                                  128K  128K     0 100% /snap/bare/5
snapfuse                                   56M   56M     0 100% /snap/core18/2999
snapfuse                                   64M   64M     0 100% /snap/core20/2866
snapfuse                                  139M  139M     0 100% /snap/drawio/292
snapfuse                                   67M   67M     0 100% /snap/core24/1643
snapfuse                                  139M  139M     0 100% /snap/drawio/298
snapfuse                                  165M  165M     0 100% /snap/gnome-3-28-1804/198
snapfuse                                   92M   92M     0 100% /snap/gtk-common-themes/1535
snapfuse                                  615M  615M     0 100% /snap/gnome-46-2404/164
snapfuse                                  402M  402M     0 100% /snap/mesa-2404/1839
snapfuse                                   51M   51M     0 100% /snap/snapd/27591
snapfuse                                   51M   51M     0 100% /snap/snapd/27710
tmpfs                                     1.6G   36K  1.6G   1% /run/user/1000
none                                      7.8G  716K  7.8G   1% /mnt/wsl/docker-desktop/shared-sockets/host-services
/dev/sde                                  130M   66M   54M  55% /mnt/wsl/docker-desktop/docker-desktop-user-distro
/dev/loop0                                736M  736M     0 100% /mnt/wsl/docker-desktop/cli-tools
tmpfs                                     1.6G   32K  1.6G   1% /run/user/0
C:\Program Files\Docker\Docker\resources  952G  586G  367G  62% /Docker/host
```

Root filesystem (`/`) has 729G available, well above the 100 GB minimum
enforced by `make doctor`.

## `docker run --rm hello-world`

Command: `docker run --rm hello-world`

```
Hello from Docker!
This message shows that your installation appears to be working correctly.

To generate this message, Docker took the following steps:
 1. The Docker client contacted the Docker daemon.
 2. The Docker daemon pulled the "hello-world" image from the Docker Hub.
    (amd64)
 3. The Docker daemon created a new container from that image which runs the
    executable that produces the output you are currently reading.
 4. The Docker daemon streamed that output to the Docker client, which sent it
    to your terminal.

To try something more ambitious, you can run an Ubuntu container with:
 $ docker run -it ubuntu bash

Share images, automate workflows, and more with a free Docker ID:
 https://hub.docker.com/

For more examples and ideas, visit:
 https://docs.docker.com/get-started/
```

Exit code: `0`

## `make doctor`

Command: `make doctor`

```
== devenv-cloud host doctor (M0) ==

[PASS] Linux host detected (Linux)
[PASS] Architecture is x86-64 (x86_64)
[PASS] Docker CLI available (Docker version 29.1.3, build f52814d)
[PASS] Docker daemon is reachable
[PASS] Docker Compose plugin available (Docker Compose version v2.40.3-desktop.1)
[PASS] Git available (git version 2.43.0)
[PASS] curl available (curl 8.5.0 (x86_64-pc-linux-gnu) libcurl/8.5.0 OpenSSL/3.0.13 zlib/1.3 brotli/1.1.0 zstd/1.5.5 libidn2/2.3.7 libpsl/0.21.2 (+libidn2/2.3.7) libssh/0.10.6/openssl/zlib nghttp2/1.59.0 librtmp/2.3 OpenLDAP/2.6.7)
[PASS] jq available (jq-1.7)
[PASS] Disk space: 728 GB free (>= 100 GB required)
[PASS] Outbound HTTPS connectivity to github.com
[PASS] Outbound HTTPS connectivity to update.code.visualstudio.com
curl: (22) The requested URL returned error: 403
[PASS] Outbound HTTPS connectivity to vscode.download.prss.microsoft.com (HTTP 403)
[PASS] Port 7080 is available

== Summary: 13 passed, 0 failed ==
```

Exit code: `0` (13/13 checks PASS). Note: the `curl: (22)` line is stderr
noise from the connectivity probe against
`vscode.download.prss.microsoft.com`; the doctor script correctly treats an
HTTP 403 response as reachability confirmation for that host and marks the
check `PASS`, consistent with the overall `0 failed` / exit `0` result.

## Conclusion

All M0 host readiness checks pass on this host. This report satisfies the
required deliverable referenced in `docs/plan/plan.md` line 88 and line 595.
