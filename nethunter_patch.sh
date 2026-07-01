#!/bin/bash
# ==========================================
# Kali NetHunter Kernel Config Script
# For Konoha Kernel (Linux 6.6.x GKI)
#
# This script enables NetHunter-required kernel
# configs at build time using scripts/config.
# NO kernel source files are modified.
#
# Usage: ./nethunter_patch.sh <out_dir>
# ==========================================

NETHUNTER_VERSION="1.0"

apply_nethunter_configs() {
    local OUT_DIR="$1"
    local CONFIG_FILE="$OUT_DIR/.config"

    if [ ! -f "$CONFIG_FILE" ]; then
        echo "[-] NetHunter: .config not found: $CONFIG_FILE"
        return 1
    fi

    echo "=========================================="
    echo "[+] NetHunter v${NETHUNTER_VERSION}: Applying configs..."
    echo "=========================================="

    # ==========================================
    # 1. USB HID Gadget (verify already enabled)
    # ==========================================
    echo "[*] USB HID Gadget..."
    scripts/config --file "$CONFIG_FILE" \
        -e CONFIG_USB_CONFIGFS \
        -e CONFIG_USB_CONFIGFS_F_HID \
        -e CONFIG_USB_F_HID

    # ==========================================
    # 2. USB Networking (RNDIS, CDC, EEM)
    # ==========================================
    echo "[*] USB Networking..."
    scripts/config --file "$CONFIG_FILE" \
        -e CONFIG_USB_CONFIGFS_RNDIS \
        -e CONFIG_USB_CONFIGFS_EEM \
        -e CONFIG_USB_CONFIGFS_ECM \
        -m CONFIG_USB_NET_CDC_SUBSET \
        -m CONFIG_USB_NET_RNDIS_HOST

    # ==========================================
    # 3. WiFi Framework (for external USB adapters)
    # ==========================================
    echo "[*] WiFi Framework (cfg80211/mac80211)..."
    scripts/config --file "$CONFIG_FILE" \
        -e CONFIG_WIRELESS \
        -e CONFIG_WIRELESS_EXT \
        -e CONFIG_WEXT_CORE \
        -e CONFIG_WEXT_PROC \
        -e CONFIG_WEXT_PRIV \
        -m CONFIG_CFG80211 \
        -e CONFIG_CFG80211_WEXT \
        -m CONFIG_MAC80211

    # ==========================================
    # 4. External USB WiFi Adapter Drivers
    # ==========================================
    echo "[*] External WiFi Drivers..."

    # Enable vendor menus (required for drivers to be visible to Kconfig)
    scripts/config --file "$CONFIG_FILE" \
        -e CONFIG_WLAN_VENDOR_ATH \
        -e CONFIG_WLAN_VENDOR_RALINK \
        -e CONFIG_WLAN_VENDOR_REALTEK

    # Realtek RTL8XXXU (RTL8188EU, RTL8192EU, etc.)
    scripts/config --file "$CONFIG_FILE" \
        -m CONFIG_RTL8XXXU \
        -e CONFIG_RTL8XXXU_UNTESTED

    # Ralink RT2800 USB
    scripts/config --file "$CONFIG_FILE" \
        -m CONFIG_RT2X00 \
        -m CONFIG_RT2800USB \
        -e CONFIG_RT2800USB_RT3573 \
        -e CONFIG_RT2800USB_RT53XX \
        -e CONFIG_RT2800USB_RT55XX \
        -e CONFIG_RT2800USB_UNKNOWN \
        -m CONFIG_RT2800_LIB \
        -m CONFIG_RT2X00_LIB_USB \
        -m CONFIG_RT2X00_LIB \
        -e CONFIG_RT2X00_LIB_FIRMWARE

    # Atheros AR9271 (ath9k_htc)
    scripts/config --file "$CONFIG_FILE" \
        -m CONFIG_ATH_COMMON \
        -m CONFIG_ATH9K_HW \
        -m CONFIG_ATH9K_COMMON \
        -m CONFIG_ATH9K_HTC \
        -e CONFIG_ATH9K_HTC_DEBUGFS

    # ==========================================
    # 5. Bluetooth (external USB adapters)
    # ==========================================
    echo "[*] Bluetooth USB..."
    scripts/config --file "$CONFIG_FILE" \
        -m CONFIG_BT_HCIBTUSB

    # ==========================================
    # 6. USB Serial Adapters
    # ==========================================
    echo "[*] USB Serial Adapters..."
    scripts/config --file "$CONFIG_FILE" \
        -m CONFIG_USB_SERIAL \
        -e CONFIG_USB_SERIAL_GENERIC \
        -m CONFIG_USB_SERIAL_CH341 \
        -m CONFIG_USB_SERIAL_CP210X \
        -m CONFIG_USB_SERIAL_FTDI_SIO \
        -m CONFIG_USB_SERIAL_PL2303 \
        -m CONFIG_USB_SERIAL_OPTION

    # ==========================================
    # 7. Network Filesystems
    # ==========================================
    echo "[*] Network Filesystems..."
    scripts/config --file "$CONFIG_FILE" \
        -m CONFIG_CIFS \
        -m CONFIG_NFS_FS \
        -e CONFIG_NFS_V3 \
        -e CONFIG_NFS_V4 \
        -m CONFIG_LOCKD \
        -m CONFIG_SUNRPC

    # ==========================================
    # 8. Additional NetHunter requirements
    # ==========================================
    echo "[*] Additional NetHunter configs..."
    scripts/config --file "$CONFIG_FILE" \
        -e CONFIG_BRIDGE \
        -e CONFIG_TUN \
        -e CONFIG_VETH \
        -e CONFIG_DUMMY \
        -e CONFIG_PACKET \
        -m CONFIG_PACKET_DIAG \
        -e CONFIG_USB_STORAGE \
        -e CONFIG_USB_CONFIGFS_MASS_STORAGE \
        -m CONFIG_USB_ACM

    echo ""
    echo "[+] NetHunter: All configs applied."
    echo ""
}

apply_nethunter_source_patches() {
    echo "=========================================="
    echo "[+] NetHunter: Applying WiFi injection source patches..."
    echo "=========================================="
    echo "[!] These patches will be reverted after build by git checkout."

    # ==========================================
    # 1. net/wireless/chan.c
    #    Remove cfg80211_has_monitors_only restriction
    #    Allows monitor channel change even with other interfaces
    # ==========================================
    echo "[*] Patching net/wireless/chan.c..."
    sed -i 's/if (!cfg80211_has_monitors_only(rdev))/\/\* NetHunter: allow monitor channel change \*\/\n\tif (0 \&\& !cfg80211_has_monitors_only(rdev))/' net/wireless/chan.c

    # ==========================================
    # 2. net/mac80211/cfg.c
    #    Allow channel change even when non-monitor interfaces exist
    # ==========================================
    echo "[*] Patching net/mac80211/cfg.c..."
    sed -i 's/if (local->open_count == local->monitors) {/\/* NetHunter: allow channel change with other ifaces *\/\n\t\tif (local->open_count == local->monitors || true) {/' net/mac80211/cfg.c

    # ==========================================
    # 3. net/mac80211/tx.c (injection sequence + NO_ACK)
    #    Replace monitor mode check with injection-aware check
    # ==========================================
    echo "[*] Patching net/mac80211/tx.c (injection)..."

    # Patch 3a: Sequence number handler — use CTL_INJECTED instead of IFTYPE_MONITOR
    sed -i '/Packet injection may want to control the sequence/{
N;N;N;N;N
s/\* number, if we have no matching interface then we\n\t \* neither assign one ourselves nor ask the driver to.\n\t \*\/\n\tif (unlikely(info->control.vif->type == NL80211_IFTYPE_MONITOR))\n\t\treturn TX_CONTINUE;/\* number, so if an injected packet is found, skip\n\t * renumbering it. Also make the packet NO_ACK to avoid\n\t * excessive retries (ACKing and retrying should be\n\t * handled by the injecting application).\n\t *\/\n\tif (unlikely((info->flags \& IEEE80211_TX_CTL_INJECTED) \&\&\n\t   !(tx->sdata->u.mntr.flags \& MONITOR_FLAG_COOK_FRAMES))) {\n\t\tif (!ieee80211_has_morefrags(hdr->frame_control))\n\t\t\tinfo->flags |= IEEE80211_TX_CTL_NO_ACK;\n\t\treturn TX_CONTINUE;\n\t}/
}' net/mac80211/tx.c

    # Patch 3b: Don't overwrite QoS header in monitor mode
    sed -i 's/^\tieee80211_set_qos_hdr(sdata, skb);$/\t\/* NetHunter: skip QoS rewrite in monitor mode *\/\n\tif (likely(info->control.vif->type != NL80211_IFTYPE_MONITOR))\n\t\tieee80211_set_qos_hdr(sdata, skb);/' net/mac80211/tx.c

    echo "[+] NetHunter: Source patches applied."
    echo ""
}

revert_nethunter_source_patches() {
    echo "[*] NetHunter: Reverting source patches..."
    git checkout -- net/wireless/chan.c net/mac80211/cfg.c net/mac80211/tx.c 2>/dev/null
    echo "[+] NetHunter: Source patches reverted."
}

# Main
if [ -z "$1" ]; then
    echo "Usage: $0 <out_dir>"
    exit 1
fi

apply_nethunter_configs "$1"
apply_nethunter_source_patches
