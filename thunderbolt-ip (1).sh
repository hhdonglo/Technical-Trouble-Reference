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
