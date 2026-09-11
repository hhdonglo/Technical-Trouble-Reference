# Thunderbolt Point-to-Point Networking — MacBook Air ↔ MacBook Pro (2018)

Reference doc for the KEWPIE3 distributed compute cluster network link. Fully automated as of Sep 11, 2026 — no manual steps required after boot.

## Network layout

| Machine | IP | Netmask |
|---|---|---|
| MacBook Air | `10.0.0.1` | `255.255.0.0` |
| MacBook Pro (2018) | `10.0.0.2` | `255.255.0.0` |

Known dead port on the Pro: **"Thunderbolt 2"** — permanently excluded in the script.

---

## Problem statement

The two Macs are connected via a Thunderbolt cable to form a point-to-point network for KEWPIE3's distributed MPI workload. Using macOS's built-in "Thunderbolt Bridge" networking service, the link would show "Connected" in Network Settings, but pings between the machines failed consistently with "No route to host" / "Host is down" / plain timeouts, depending on the exact fault active at the time.

## Root causes (found in sequence — there were several, stacked)

1. **Malformed subnet mask.** A manually-entered mask of `255.255.0.0.0` (5 octets) broke routing outright.
2. **`bridge0` stuck in a broken STP state.** macOS's Thunderbolt Bridge virtual interface had member ports permanently stuck at `flags=3<LEARNING,DISCOVER>`, never reaching a forwarding state — blocking all traffic at layer 2, even though the physical Thunderbolt link itself was completely healthy (confirmed via `system_profiler SPThunderboltDataType`, which showed a clean 40 Gb/s connection with both machines recognizing each other).
3. **macOS auto-recreates the "Thunderbolt Bridge" service after every reboot**, even after it's been manually deleted. Its mere presence — even with an empty interface list — silently reclaims the physical port and blocks any direct traffic on it.
4. **Promiscuous mode left behind.** Attaching a physical interface to the bridge service (even briefly) puts it into promiscuous mode. Removing the bridge service afterward does not clear this flag on its own, and it continues to silently block traffic even after a correct static IP is assigned directly to the interface.
5. **Physical port numbering is not stable.** The `enX` name of the live Thunderbolt interface shifted between sessions on both Macs (Air stayed on `en2`; Pro moved between `en3` and `en4`). Hardcoding an interface name breaks the setup unpredictably.
6. **`launchd` itself was broken on the Air.** `launchctl bootstrap` / `launchctl load` failed with `Input/output error` for *any* LaunchDaemon, confirmed with a trivial test daemon that also failed identically. This persisted through an SMC reset, a `launchd.db` wipe, and a full reboot. Root cause never isolated (SIP, disk integrity, and permissions were all confirmed healthy) — LaunchDaemons were abandoned as the persistence mechanism as a result.
7. **cron's minimal `PATH` broke the script when run unattended.** `scutil` (and other tools) live in `/usr/sbin`, which is not in cron's default `PATH`. The script worked fine when run manually in Terminal but failed silently every time under cron until an explicit `PATH` was set inside the script.

## Final solution

Bypass `bridge0` entirely. A single self-contained shell script — identical on both Macs — scheduled via `cron` (not `launchd`, per #6 above) to run every 60 seconds. Each run:

1. Removes the "Thunderbolt Bridge" service if macOS has recreated it.
2. Detects which physical Thunderbolt port is currently active (skipping any ports marked dead for that machine), by cross-referencing `networksetup -listallhardwareports` against live interface status.
3. If no port is active on the first check (typical right after a cold boot), briefly recreates the Thunderbolt Bridge service to force macOS to negotiate the physical link, waits, rechecks, then removes the bridge again.
4. Cycles the detected interface down/up to clear any leftover promiscuous-mode flag from step 3.
5. Assigns the correct static IP directly to that physical interface.

Because the script detects its own role (which IP to use, from the computer's name) and which port is actually live, the exact same file deploys unmodified to both machines and survives interface renumbering, cable replugging, and reboots without edits.

---

## The script

Save as `/usr/local/bin/thunderbolt-ip.sh` on **both** Macs — identical file, no per-machine edits needed.

```bash
#!/bin/bash
# thunderbolt-ip.sh
# Auto-detects the active Thunderbolt port on this Mac and assigns the
# correct static point-to-point IP for the Air<->Pro link.
#
# Deploy the SAME copy to both Macs. It figures out its own IP from the
# computer name, and figures out which physical port to use by checking
# which Thunderbolt hardware port is actually active right now.
#
# After a cold boot, the physical Thunderbolt link sometimes doesn't
# fully negotiate until the "Thunderbolt Bridge" network service exists.
# If no port is active on first check, this script briefly creates that
# service to nudge the link up, waits, rechecks, then removes it again
# before assigning the IP directly to the physical interface.

export PATH="/usr/sbin:/sbin:/usr/bin:/bin:$PATH"

NETMASK="255.255.0.0"

# --- Remove the "Thunderbolt Bridge" service if present ---
# Even with an empty interface list, this service can claim the physical
# port and block direct traffic, so it must not be left in place.
remove_bridge_service() {
    if networksetup -listallnetworkservices 2>/dev/null | grep -qx "Thunderbolt Bridge"; then
        networksetup -removenetworkservice "Thunderbolt Bridge" >/dev/null 2>&1
        echo "$(date): Removed 'Thunderbolt Bridge' service"
    fi
}

# --- Determine which IP this Mac should use, and which ports to skip ---
HOSTNAME=$(scutil --get ComputerName)

case "$HOSTNAME" in
  *Air*|*AIR*)
    MY_IP="10.0.0.1"
    DEAD_PORTS=()
    ;;
  *Pro*|*PRO*)
    MY_IP="10.0.0.2"
    # "Thunderbolt 2" is a known-dead port on this specific Pro.
    DEAD_PORTS=("Thunderbolt 2")
    ;;
  *)
    echo "$(date): Unrecognized computer name '$HOSTNAME', cannot determine IP. Edit the case statement in this script to add it." >&2
    exit 1
    ;;
esac

is_dead_port() {
    local name="$1"
    for dead in "${DEAD_PORTS[@]}"; do
        [[ "$name" == "$dead" ]] && return 0
    done
    return 1
}

# --- Scan for the active Thunderbolt interface, skipping dead ports ---
find_active_iface() {
    local iface="" port_name="" device=""
    while IFS= read -r line; do
        if [[ "$line" == "Hardware Port: "* ]]; then
            port_name="${line#Hardware Port: }"
        elif [[ "$line" == "Device: "* ]]; then
            device="${line#Device: }"
            if [[ "$port_name" == Thunderbolt\ [0-9]* ]]; then
                if is_dead_port "$port_name"; then
                    continue
                fi
                local status
                status=$(ifconfig "$device" 2>/dev/null | awk -F': ' '/status:/{print $2}')
                if [[ "$status" == "active" ]]; then
                    echo "${device}|${port_name}"
                    return 0
                fi
            fi
        fi
    done < <(networksetup -listallhardwareports)
    return 1
}

# --- Main ---
remove_bridge_service

RESULT=$(find_active_iface)

if [[ -z "$RESULT" ]]; then
    echo "$(date): No active Thunderbolt port found on first check. Nudging link up via temporary bridge service..."

    # Create the bridge service momentarily to trigger macOS to fully
    # negotiate the Thunderbolt link (needed after a cold boot).
    networksetup -createnetworkservice "Thunderbolt Bridge" bridge0 >/dev/null 2>&1
    sleep 6

    RESULT=$(find_active_iface)

    # Whether or not it worked, remove the bridge service again so it
    # doesn't sit there blocking direct traffic.
    remove_bridge_service
fi

if [[ -z "$RESULT" ]]; then
    echo "$(date): FAILED - no active Thunderbolt port found even after nudge (excluding dead ports: ${DEAD_PORTS[*]})" >&2
    exit 1
fi

ACTIVE_IFACE="${RESULT%%|*}"
ACTIVE_PORT_NAME="${RESULT##*|}"

# Cycle the interface down/up first. Attaching it to the "Thunderbolt
# Bridge" service (even briefly) can leave it stuck in promiscuous mode
# after the service is removed, which silently blocks direct traffic
# even though the IP assignment below succeeds. A down/up cycle clears it.
/sbin/ifconfig "$ACTIVE_IFACE" down
/sbin/ifconfig "$ACTIVE_IFACE" up

/sbin/ifconfig "$ACTIVE_IFACE" inet "$MY_IP" netmask "$NETMASK" up

if [[ $? -eq 0 ]]; then
    echo "$(date): OK - assigned $MY_IP to $ACTIVE_IFACE ($ACTIVE_PORT_NAME) on $HOSTNAME"
else
    echo "$(date): FAILED to assign $MY_IP to $ACTIVE_IFACE" >&2
    exit 1
fi
```

---

## Deployment (run once per Mac)

```bash
sudo mv ~/Downloads/thunderbolt-ip.sh /usr/local/bin/thunderbolt-ip.sh
sudo chmod 755 /usr/local/bin/thunderbolt-ip.sh
```

Schedule it with cron:

```bash
sudo crontab -e
```

Add this line:

```
* * * * * /usr/local/bin/thunderbolt-ip.sh >> /var/log/thunderbolt-ip.log 2>&1
```

Save and confirm it's there:

```bash
sudo crontab -l
```

## Verification (after initial setup, or anytime)

```bash
sudo /usr/local/bin/thunderbolt-ip.sh
ifconfig en2        # or whichever interface the script reports — check for
                     # inet <ip>, status: active, and no PROMISC in flags
ping -c 5 10.0.0.2   # from the Air; use 10.0.0.1 from the Pro
```

Expect 0% packet loss, ~1 ms round-trip latency.

## After every reboot — fully automatic, no action needed

Within about 90 seconds of login, cron fires the script on its own minute-by-minute schedule. It clears any auto-recreated bridge, re-negotiates the physical link if needed, and reassigns the correct IP. Just wait ~90 seconds after logging in before expecting connectivity — no commands to run.

---

## If something breaks again — troubleshooting checklist

1. **Check the log:** `cat /var/log/thunderbolt-ip.log`
2. **Run it manually and read the output directly:** `sudo /usr/local/bin/thunderbolt-ip.sh`
3. **Confirm cron is still scheduled:** `sudo crontab -l`
4. **Check the interface:** `ifconfig en2` (or whatever the log says) — look for a correct `inet` address, `status: active`, and no `PROMISC` in the flags
5. **Check for a lingering bridge service:** `networksetup -listallnetworkservices` — "Thunderbolt Bridge" should not be listed
6. **Check the physical link health:** `system_profiler SPThunderboltDataType` — should show "Device connected" at 40 Gb/s with the other Mac listed underneath
7. **If the port number shifted** (e.g. Pro now on `en4` instead of `en3`) — no action needed, the script re-detects this automatically every run
8. **If a *new* port goes bad** on either Mac, add its exact `"Thunderbolt N"` label to the `DEAD_PORTS` array in that machine's case block in the script

---

## Abandoned approaches (for reference — don't repeat these)

- **LaunchDaemons.** The textbook-correct way to persist an `ifconfig` command across reboot. Abandoned because `launchd` itself was in a broken, non-bootstrappable state on the Air — confirmed with a trivial test daemon that failed identically to the real one. This survived an SMC reset and a full `launchd.db` wipe + reboot; root cause never isolated even after ruling out SIP, disk corruption, and file/directory permissions.
- **`networksetup -createnetworkservice` as a permanent native service.** Cleaner in principle than raw `ifconfig`, since it's managed by `configd` the same way Wi-Fi is. Abandoned because it failed with a persistent `"Unable to access the System Configuration database"` error on the Air that survived a `configd` restart and a full reboot. Root cause never isolated.
