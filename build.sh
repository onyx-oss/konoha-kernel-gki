#!/bin/bash
set -e

# ==========================================
# Cleanup Trap
# ==========================================
cleanup() {
    # Revert dynamic Baseband-guard modifications to keep git tree clean
    git checkout security/Kconfig security/Makefile security/selinux/ include/linux/sched.h 2>/dev/null || true
    rm -f security/baseband-guard
    # Revert NetHunter WiFi injection source patches
    git checkout -- net/wireless/chan.c net/mac80211/cfg.c net/mac80211/tx.c 2>/dev/null || true
}
trap cleanup EXIT

# ==========================================
# Konoha Kernel Build Script
# Usage: ./build.sh [key=value ...]
#   hz=100|250|1000       Timer frequency (default: 250)
#   hardened=on|off       CPU mitigations (default: off)
#   variant=stock|root|susfs  Build variant (default: stock)
#   root=ksu-next|sukisu|resukisu|mambosu  Root solution (default: ksu-next)
#   kpm=on|off            KPM support (default: off, sukisu/resukisu only)
#   kpm_superkey=STRING   KPM SuperKey (required if kpm=on)
#   kpm_patch=on|off      Inject kpimg with kptools (default: on; resukisu defaults off)
#   lto=thin|full|none    LTO type (default: thin)
#   autofdo=on|off        AutoFDO (default: on)
#   droidspaces=on|off    Droidspaces support (default: off)
#   nethunter=on|off      Kali NetHunter support (default: off)
# ==========================================

VERSION="1.1"

# Parse CLI arguments (key=value)
for arg in "$@"; do
    case "$arg" in
        hz=*)       HZ="${arg#*=}" ;;
        hardened=*) HARDENED="${arg#*=}" ;;
        variant=*)  VARIANT="${arg#*=}" ;;
        root=*)     ROOT="${arg#*=}" ;;
        kpm=*)      KPM="${arg#*=}" ;;
        kpm_superkey=*) KPM_SUPERKEY="${arg#*=}" ;;
        kpm_patch=*) KPM_PATCH="${arg#*=}" ;;
        lto=*)      LTO_TYPE="${arg#*=}" ;;
        autofdo=*)  AUTOFDO="${arg#*=}" ;;
        bypasscharging=*) BYPASSCHARGING="${arg#*=}" ;;
        htsr=*) HTSR="${arg#*=}" ;;
        wifi_exploit=*) WIFI_EXPLOIT="${arg#*=}" ;;
        kgsl_exploit=*) KGSL_EXPLOIT="${arg#*=}" ;;
        data_exploit=*) DATA_EXPLOIT="${arg#*=}" ;;
        droidspaces=*) DROIDSPACES="${arg#*=}" ;;
        nethunter=*) NETHUNTER="${arg#*=}" ;;
        debug=*) DEBUG_MODE="${arg#*=}" ;;
        kernel_name=*) KERNEL_NAME="${arg#*=}" ;;
        spoof_uname=*) SPOOF_UNAME="${arg#*=}" ;;

    esac
done


echo "Applying Custom Kernel Name and Spoof Uname..."
if [ -n "$KERNEL_NAME" ]; then
    sed -i "s/CONFIG_LOCALVERSION=\".*\"/CONFIG_LOCALVERSION=\"$KERNEL_NAME\"/g" arch/arm64/configs/konoha_defconfig
fi

if [ "$SPOOF_UNAME" == "on" ]; then
    # Spoof to standard Android stock naming (remove custom localversion)
    sed -i 's/CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION=\"\"/g' arch/arm64/configs/konoha_defconfig
fi

# ==========================================
# Non-Interactive Mode (Defaults)
# ==========================================
if [ "$#" -gt 0 ]; then
    NON_INTERACTIVE=1
    [ -z "$HZ" ] && HZ=250
    [ -z "$HARDENED" ] && HARDENED="off"
    [ -z "$VARIANT" ] && VARIANT="stock"
    [ -z "$ROOT" ] && [ "$VARIANT" != "stock" ] && ROOT="ksu-next"
    [ -z "$KPM" ] && KPM="off"
    [ -z "$LTO_TYPE" ] && LTO_TYPE="thin"
    [ -z "$BYPASSCHARGING" ] && BYPASSCHARGING="off"
    [ -z "$DROIDSPACES" ] && DROIDSPACES="off"
    [ -z "$NETHUNTER" ] && NETHUNTER="off"
    [ -z "$DEBUG_MODE" ] && DEBUG_MODE="off"
else
    NON_INTERACTIVE=0
fi
# ==========================================
# Paths
# ==========================================
KERNEL_DIR=$(pwd)
MAIN=$(readlink -f "$KERNEL_DIR/..")
CLANG_DIR="$MAIN/toolchains/clang"
OUT_DIR="$KERNEL_DIR/out"
ZIMAGE_DIR="$OUT_DIR/arch/arm64/boot"
MODULES_DIR="$KERNEL_DIR/.root_modules"
BUILD_START=$(date +"%s")

# ==========================================
# Interactive Menus (only if not set via CLI/env)
# ==========================================

# 1. Timer Frequency
if [ -z "$HZ" ]; then
    echo "=========================================="
    echo "         Select Timer Frequency           "
    echo "=========================================="
    echo " 1) 100 HZ  (powersave)"
    echo " 2) 250 HZ  (balance - default)"
    echo " 3) 500 HZ  (performance)"
    echo " 4) 1000 HZ (ultra-performance)"
    read -p "Enter choice [1-4] (default 2): " _c
    case "${_c:-2}" in 1) HZ=100 ;; 3) HZ=500 ;; 4) HZ=1000 ;; *) HZ=250 ;; esac
fi

# 2. Hardened Security
if [ -z "$HARDENED" ]; then
    echo "=========================================="
    echo "         Hardened Security Mode           "
    echo "=========================================="
    echo " 1) OFF (default - better performance)"
    echo " 2) ON  (CPU mitigations enabled)"
    read -p "Enter choice [1-2] (default 1): " _c
    [ "${_c:-1}" == "2" ] && HARDENED="on" || HARDENED="off"
fi

# 3. Build Variant
if [ -z "$VARIANT" ]; then
    echo "=========================================="
    echo "          Select Build Variant            "
    echo "=========================================="
    echo " 1) Non-Root (Stock - default)"
    echo " 2) Root Only"
    echo " 3) Root + SUSFS"
    read -p "Enter choice [1-3] (default 1): " _c
    case "${_c:-1}" in 2) VARIANT="root" ;; 3) VARIANT="susfs" ;; *) VARIANT="stock" ;; esac
fi

# 4. Root Solution (only for root/susfs)
if [ "$VARIANT" != "stock" ] && [ -z "$ROOT" ]; then
    echo "=========================================="
    echo "         Select Root Solution             "
    echo "=========================================="
    echo " 1) KernelSU-Next (default)"
    echo " 2) KernelSU (Official)"
    echo " 3) Sukisu"
    echo " 4) YukiSU"
    echo " 5) ReSukiSU"
    echo " 6) MamboSU"
    echo " 7) APatch (KernelPatch)"
    echo " 8) FolkPatch (KernelPatch)"
    read -p "Enter choice [1-8] (default 1): " _c
    case "${_c:-1}" in 2) ROOT="ksu" ;; 3) ROOT="sukisu" ;; 4) ROOT="yukisu" ;; 5) ROOT="resukisu" ;; 6) ROOT="mambosu" ;; 7) ROOT="apatch" ;; 8) ROOT="folkpatch" ;; *) ROOT="ksu-next" ;; esac
fi

# 5. KPM (only for sukisu/yukisu/resukisu/apatch/folkpatch)
KPM_SUPPORTED_ROOTS="sukisu yukisu resukisu apatch folkpatch"
if [ "$VARIANT" != "stock" ] && echo "$KPM_SUPPORTED_ROOTS" | grep -qw "$ROOT"; then
    if [ -z "$KPM" ]; then
        echo "=========================================="
        echo "        KPM (Kernel Patch Module)         "
        echo "=========================================="
        echo " 1) OFF (default - standard root)"
        echo " 2) ON  (enable KPM module support)"
        read -p "Enter choice [1-2] (default 1): " _c
        [ "${_c:-1}" == "2" ] && KPM="on" || KPM="off"
    fi
    if [ "$KPM" == "on" ] && [ -z "$KPM_SUPERKEY" ]; then
        if [ -t 0 ] && [ "$NON_INTERACTIVE" != "1" ]; then
            read -p "Enter KPM SuperKey (or leave empty to auto-generate): " KPM_SUPERKEY
        fi
        if [ -z "$KPM_SUPERKEY" ]; then
            KPM_SUPERKEY=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 16)
            echo "[+] Auto-generated SuperKey: $KPM_SUPERKEY"
        fi
    fi
else
    [ "$KPM" == "on" ] && [ "$VARIANT" != "stock" ] && \
        echo "[!] KPM not supported by $ROOT — forcing off"
    KPM="off"
fi

# ReSukiSU + runtime kpimg patch is unstable on some devices.
# Keep KPM compile-time enabled, but default to no post-build injection.
if [ "$KPM" == "on" ] && [ -z "$KPM_PATCH" ]; then
    [ "$ROOT" == "resukisu" ] && KPM_PATCH="off" || KPM_PATCH="on"
fi

# 6. LTO Type
if [ -z "$LTO_TYPE" ]; then
    echo "=========================================="
    echo "           Select LTO Type                "
    echo "=========================================="
    echo " 1) THIN (default - faster build)"
    echo " 2) FULL (slower, slightly better perf)"
    echo " 3) NONE (no LTO)"
    read -p "Enter choice [1-3] (default 1): " _c
    case "${_c:-1}" in 2) LTO_TYPE="full" ;; 3) LTO_TYPE="none" ;; *) LTO_TYPE="thin" ;; esac
fi

# KPM builds are more stable with thin LTO.
if [ "$KPM" == "on" ] && [ "$LTO_TYPE" == "full" ]; then
    echo "[!] KPM with FULL LTO is unstable, forcing LTO=thin"
    LTO_TYPE="thin"
fi
# 7. Bypass Charging
if [ -z "$BYPASSCHARGING" ]; then
    echo "=========================================="
    echo "         Bypass Charging (MCA)            "
    echo "=========================================="
    echo " 1) OFF (default - standard charging)"
    echo " 2) ON  (Override limits / Bypass charging)"
    read -p "Enter choice [1-2] (default 1): " _c
    [ "${_c:-1}" == "2" ] && BYPASSCHARGING="on" || BYPASSCHARGING="off"
fi

# 8. Droidspaces
if [ -z "$DROIDSPACES" ]; then
    echo "=========================================="
    echo "            Droidspaces Support           "
    echo "=========================================="
    echo " 1) OFF (default)"
    echo " 2) ON  (Add configs and kABI patches)"
    read -p "Enter choice [1-2] (default 1): " _c
    [ "${_c:-1}" == "2" ] && DROIDSPACES="on" || DROIDSPACES="off"
fi

# 9. NetHunter
if [ -z "$NETHUNTER" ]; then
    echo "=========================================="
    echo "         Kali NetHunter Support            "
    echo "=========================================="
    echo " 1) OFF (default)"
    echo " 2) ON  (WiFi injection, HID, USB adapters)"
    read -p "Enter choice [1-2] (default 1): " _c
    [ "${_c:-1}" == "2" ] && NETHUNTER="on" || NETHUNTER="off"
fi

# 10. Debug Mode
if [ -z "$DEBUG_MODE" ]; then
    echo "=========================================="
    echo "               Debug Mode                 "
    echo "=========================================="
    echo " 1) OFF (default - full optimizations)"
    echo " 2) ON  (nokaslr, no icf/merge-constants)"
    read -p "Enter choice [1-2] (default 1): " _c
    [ "${_c:-1}" == "2" ] && DEBUG_MODE="on" || DEBUG_MODE="off"
fi

# Set defaults for performance mods (all ON by default)
[ -z "$HTSR" ] && HTSR="on"
[ -z "$WIFI_EXPLOIT" ] && WIFI_EXPLOIT="on"
[ -z "$KGSL_EXPLOIT" ] && KGSL_EXPLOIT="on"
[ -z "$DATA_EXPLOIT" ] && DATA_EXPLOIT="on"
[ -z "$AUTOFDO" ] && AUTOFDO="on"


# ==========================================
# Resolve Root Solution
# ==========================================
case "$ROOT" in
    ksu)      ROOT_REPO="https://github.com/tiann/KernelSU.git"; REPO_NAME="KernelSU"; BRANCH="main" ;;
    sukisu)   ROOT_REPO="https://github.com/sukisu-ultra/sukisu-ultra.git"; REPO_NAME="sukisu-ultra"; BRANCH="main" ;;
    yukisu)   ROOT_REPO="https://github.com/Anatdx/YukiSU.git"; REPO_NAME="YukiSU"; BRANCH="main" ;;
    resukisu) ROOT_REPO="https://github.com/ReSukiSU/ReSukiSU.git"; REPO_NAME="ReSukiSU"; BRANCH="main" ;;
    mambosu)  ROOT_REPO="https://github.com/RapliVx/KernelSU.git"; REPO_NAME="MamboSU"; BRANCH="master" ;;
    apatch)   REPO_NAME="APatch" ;;
    folkpatch) REPO_NAME="FolkPatch" ;;
    *)        ROOT_REPO="https://github.com/KernelSU-Next/KernelSU-Next.git"; REPO_NAME="KernelSU-Next"; BRANCH="dev"; ROOT="ksu-next" ;;
esac



# ==========================================
# Prepare Root Module
# ==========================================
rm -rf "$KERNEL_DIR/drivers/kernelsu"
if [ "$VARIANT" == "stock" ]; then
    mkdir -p "$KERNEL_DIR/drivers/kernelsu"
    touch "$KERNEL_DIR/drivers/kernelsu/Kconfig"
    touch "$KERNEL_DIR/drivers/kernelsu/Makefile"
elif [ "$ROOT" == "apatch" ] || [ "$ROOT" == "folkpatch" ]; then
    echo "[+] Using $REPO_NAME (binary patcher) — creating dummy KernelSU module"
    mkdir -p "$KERNEL_DIR/drivers/kernelsu"
    touch "$KERNEL_DIR/drivers/kernelsu/Kconfig"
    touch "$KERNEL_DIR/drivers/kernelsu/Makefile"
    # Force KPM for APatch/FolkPatch
    KPM="on"
else
    mkdir -p "$MODULES_DIR"
    if [ ! -d "$MODULES_DIR/$REPO_NAME" ]; then
        echo "[+] Cloning $REPO_NAME..."
        git clone -b "$BRANCH" "$ROOT_REPO" "$MODULES_DIR/$REPO_NAME"
    else
        echo "[+] Updating $REPO_NAME..."
        (cd "$MODULES_DIR/$REPO_NAME" && git fetch origin && git reset --hard "origin/$BRANCH" || true)
    fi

    # Apply SUSFS
    if [ "$VARIANT" == "susfs" ]; then
        SUSFS_DIR="$MODULES_DIR/susfs4ksu"
        if [ ! -d "$SUSFS_DIR" ]; then
            git clone https://gitlab.com/simonpunk/susfs4ksu.git -b gki-android15-6.6-dev "$SUSFS_DIR"
        else
            (cd "$SUSFS_DIR" && git fetch origin && git reset --hard origin/gki-android15-6.6-dev || true)
        fi

        # Pin to latest stable SUSFS — includes "Fix possible kernel panic" (1450035)
        (cd "$SUSFS_DIR" && git reset --hard origin/gki-android15-6.6-dev)

        echo "[+] Injecting SUSFS kernel sources..."
        cp "$SUSFS_DIR/kernel_patches/fs/susfs.c" "$KERNEL_DIR/fs/susfs.c"
        cp "$SUSFS_DIR/kernel_patches/include/linux/susfs.h" "$KERNEL_DIR/include/linux/susfs.h"
        [ -f "$SUSFS_DIR/kernel_patches/include/linux/susfs_def.h" ] && \
            cp "$SUSFS_DIR/kernel_patches/include/linux/susfs_def.h" "$KERNEL_DIR/include/linux/susfs_def.h"

        # Fix susfs_def.h: the 6b1badb version uses 'current', 'current_uid()',
        # 'test_ti_thread_flag()', etc. but doesn't include the required headers.
        SUSFS_DEF_H="$KERNEL_DIR/include/linux/susfs_def.h"
        if [ -f "$SUSFS_DEF_H" ] && ! grep -q "linux/sched.h" "$SUSFS_DEF_H" 2>/dev/null; then
            sed -i '/#include <linux\/bits.h>/a\
#include <linux\/sched.h>\
#include <linux\/thread_info.h>\
#include <linux\/cred.h>\
#include <asm\/current.h>' "$SUSFS_DEF_H"
        fi

        if grep -q "config KSU_SUSFS" "$MODULES_DIR/$REPO_NAME/kernel/Kconfig" 2>/dev/null; then
            echo "[+] $REPO_NAME already has native SUSFS integration. Skipping patch..."
        else
            echo "[+] Patching $REPO_NAME for SUSFS..."
            (cd "$MODULES_DIR/$REPO_NAME" && \
             patch -p1 --forward -f --reject-file=- < "$SUSFS_DIR/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch" || true)
        fi

        # Always run fixup — repairs partial patch failures and adds missing hooks
        # (Moved to after root module preparation)
    fi

    # Some forks (e.g. SukiSU-Ultra) keep UAPI headers outside kernel/.
    # Expose them under kernel/uapi so includes like "uapi/supercall.h" resolve.
    if [ ! -d "$MODULES_DIR/$REPO_NAME/kernel/uapi" ] && [ -d "$MODULES_DIR/$REPO_NAME/uapi" ]; then
        ln -sfn ../uapi "$MODULES_DIR/$REPO_NAME/kernel/uapi"
    fi

    # SukiSU / YukiSU KPM header compatibility fixes
    if { [ "$ROOT" == "sukisu" ] || [ "$ROOT" == "yukisu" ]; } && [ "$KPM" == "on" ]; then
        KPM_HEADER="$MODULES_DIR/$REPO_NAME/kernel/kpm/kpm.h"
        KPM_COMPACT="$MODULES_DIR/$REPO_NAME/kernel/kpm/compact.c"
        SUPERCALL_UAPI="$MODULES_DIR/$REPO_NAME/uapi/supercall.h"
        ALLOWLIST_H="$MODULES_DIR/$REPO_NAME/kernel/policy/allowlist.h"
        KSU_KBUILD="$MODULES_DIR/$REPO_NAME/kernel/Kbuild"

        if [ -f "$KPM_HEADER" ] && grep -q '#include "uapi/supercall.h"' "$KPM_HEADER" 2>/dev/null; then
            sed -i 's|#include "uapi/supercall.h"|#include "../../uapi/supercall.h"|' "$KPM_HEADER"
            echo "[+] Patched SukiSU KPM header include path"
        fi
        if [ -f "$SUPERCALL_UAPI" ] && grep -q '#include "uapi/app_profile.h"' "$SUPERCALL_UAPI" 2>/dev/null; then
            sed -i 's|#include "uapi/app_profile.h"|#include "app_profile.h"|' "$SUPERCALL_UAPI"
            echo "[+] Patched SukiSU supercall UAPI include path"
        fi
        if [ -f "$KPM_COMPACT" ] && grep -q '#include "policy/allowlist.h"' "$KPM_COMPACT" 2>/dev/null; then
            sed -i 's|#include "policy/allowlist.h"|#include "../policy/allowlist.h"|' "$KPM_COMPACT"
        fi
        if [ -f "$KPM_COMPACT" ] && grep -q '#include "manager/manager_identity.h"' "$KPM_COMPACT" 2>/dev/null; then
            sed -i 's|#include "manager/manager_identity.h"|#include "../manager/manager_identity.h"|' "$KPM_COMPACT"
        fi
        if [ -f "$ALLOWLIST_H" ] && grep -q '#include "uapi/app_profile.h"' "$ALLOWLIST_H" 2>/dev/null; then
            sed -i 's|#include "uapi/app_profile.h"|#include "../uapi/app_profile.h"|' "$ALLOWLIST_H"
        fi
        if [ -f "$KSU_KBUILD" ] && ! grep -q '\-I$(KSU_KERNEL_DIR)/\.\.' "$KSU_KBUILD" 2>/dev/null; then
            sed -i 's|ccflags-y += -I$(KSU_KERNEL_DIR) -I$(KSU_KERNEL_DIR)/include|ccflags-y += -I$(KSU_KERNEL_DIR) -I$(KSU_KERNEL_DIR)/include -I$(KSU_KERNEL_DIR)/..|' "$KSU_KBUILD"
        fi
        [ -f "$KPM_COMPACT" ] && echo "[+] Patched SukiSU KPM compact include paths"
    fi

    echo "[+] Symlinking $REPO_NAME to drivers/kernelsu..."
    ln -sf "$MODULES_DIR/$REPO_NAME/kernel" "$KERNEL_DIR/drivers/kernelsu"
fi

# Run SUSFS fixup if needed (after root module is symlinked/created)
if [ "$VARIANT" == "susfs" ] && [ "$VARIANT" != "stock" ]; then
    echo "[+] Running SUSFS compatibility fixup ($ROOT)..."
    bash "$KERNEL_DIR/ksu_susfs_fixup.sh" "$KERNEL_DIR/drivers/kernelsu" "$ROOT"
fi

# ==========================================
# Print Config Summary
# ==========================================
echo ""
echo "=========================================="
echo "          Build Configuration             "
echo "=========================================="
echo " Timer:     ${HZ} HZ"
echo " Hardened:  ${HARDENED^^}"
echo " Bypass:    ${BYPASSCHARGING^^}"
echo " HTSR 240Hz: ${HTSR^^}"
echo " WiFi Exploit: ${WIFI_EXPLOIT^^}"
echo " KGSL Exploit: ${KGSL_EXPLOIT^^}"
echo " Data Exploit: ${DATA_EXPLOIT^^}"
echo " Debug Mode:   ${DEBUG_MODE^^}"
echo " NetHunter: ${NETHUNTER^^}"
[ "$VARIANT" != "stock" ] && echo " Variant:   ${VARIANT} ($REPO_NAME)" || echo " Variant:   stock"
echo " LTO:       ${LTO_TYPE^^}"
if [ "$VARIANT" != "stock" ]; then
    _ROOT_COMMIT=$(git -C "$MODULES_DIR/$REPO_NAME" rev-parse --short HEAD 2>/dev/null || echo "n/a")
    echo " Root:      $REPO_NAME @ $_ROOT_COMMIT"
fi
if [ "$VARIANT" == "susfs" ]; then
    _SUSFS_COMMIT=$(git -C "$MODULES_DIR/susfs4ksu" rev-parse --short HEAD 2>/dev/null || echo "n/a")
    echo " SUSFS:     susfs4ksu @ $_SUSFS_COMMIT"
fi
if [ "$KPM" == "on" ]; then
    echo " KPM:       ENABLED"
    echo " KPM Patch: ${KPM_PATCH^^}"
    echo " SuperKey:  ${KPM_SUPERKEY:0:4}****"
fi
echo "=========================================="
echo ""

# ==========================================
# KPM Tools Setup (kptools + kpimg)
# ==========================================
if [ "$KPM" == "on" ]; then
    KPM_TOOLS_DIR="$MODULES_DIR/kpm_tools"
    mkdir -p "$KPM_TOOLS_DIR"

    if [ "$ROOT" == "apatch" ] || [ "$ROOT" == "folkpatch" ]; then
        if [ "$ROOT" == "folkpatch" ]; then
            KPM_RELEASE_BASE="https://github.com/LyraVoid/KernelPatch/releases/download/0.13.1"
            KPM_SOURCE_NAME="LyraVoid/KernelPatch (FolkPatch fork) v0.13.1"
            KPIMG_NAME="kpimg-android"
        else
            KPM_RELEASE_BASE="https://github.com/bmax121/KernelPatch/releases/latest/download"
            KPM_SOURCE_NAME="official KernelPatch"
            KPIMG_NAME="kpimg-android"
        fi
    else
        KPM_RELEASE_BASE="https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/latest/download"
        KPIMG_NAME="kpimg"
        KPM_SOURCE_NAME="SukiSU-Ultra/SukiSU_KernelPatch_patch"
    fi

    KPTOOLS_BIN="$KPM_TOOLS_DIR/kptools-linux"
    KPIMG_BIN="$KPM_TOOLS_DIR/$KPIMG_NAME"

    if [ ! -f "$KPTOOLS_BIN" ] || [ ! -f "$KPIMG_BIN" ]; then
        echo "[+] Downloading KPM tools from $KPM_SOURCE_NAME..."
        
        # Download kptools (use stable 0.13.1 for LyraVoid as latest/C18 lacks linux binary)
        if [ "$ROOT" == "folkpatch" ]; then
            KPTOOLS_URL="https://github.com/LyraVoid/KernelPatch/releases/download/0.13.1/kptools-linux"
        else
            KPTOOLS_URL="$KPM_RELEASE_BASE/kptools-linux"
        fi

        curl -LSs -o "$KPTOOLS_BIN" "$KPTOOLS_URL" || \
            { echo "[-] Failed to download kptools-linux!"; exit 1; }
        
        # Download kpimg
        curl -LSs -o "$KPIMG_BIN" "$KPM_RELEASE_BASE/$KPIMG_NAME" || \
            { echo "[-] Failed to download $KPIMG_NAME!"; exit 1; }
        
        chmod +x "$KPTOOLS_BIN"
    else
        echo "[+] KPM tools already cached"
    fi

    chmod +x "$KPTOOLS_BIN"
    echo "[+] KPM tools ready: $(file -b "$KPTOOLS_BIN" | cut -d, -f1-2)"
fi

# ==========================================
# Baseband-guard Setup
# ==========================================
BBG_DIR="$KERNEL_DIR/Baseband-guard"
if [ ! -d "$BBG_DIR" ]; then
    echo "[+] Cloning Baseband-guard..."
    git clone https://github.com/vc-teahouse/Baseband-guard.git "$BBG_DIR"
fi
echo "[+] Running Baseband-guard setup..."
(cd "$KERNEL_DIR" && sh "$BBG_DIR/setup.sh")

# ==========================================
# Toolchain Setup
# ==========================================
check_clang() {
    if [ -n "$CLANG_PATH" ] && [ -f "$CLANG_PATH/bin/clang" ]; then
        export PATH="$CLANG_PATH/bin:$PATH"
        CLANG_BIN="$CLANG_PATH/bin/clang"
    elif [ -d "$CLANG_DIR" ] && [ -f "$CLANG_DIR/bin/clang" ]; then
        export PATH="$CLANG_DIR/bin:$PATH"
        CLANG_BIN="$CLANG_DIR/bin/clang"
    elif command -v clang > /dev/null 2>&1; then
        CLANG_BIN=$(command -v clang)
    else
        return 1
    fi
    COMPILER_VER=$("$CLANG_BIN" --version | head -n 1 | perl -pe 's/\(http.*?\)//gs' | sed -e 's/  */ /g' -e 's/[[:space:]]*$//')
    export KBUILD_COMPILER_STRING="$COMPILER_VER"
    echo "Found Clang: $KBUILD_COMPILER_STRING"
    return 0
}

export ARCH=arm64 SUBARCH=arm64

# Clang optimization
EXTREME_CLANG_FLAGS=(
    -O2
    -mcpu=cortex-x4
    -mtune=cortex-x4
    # -fsplit-machine-functions (causes ld.lld orphaned section errors 'text.split.*')
    -mno-fmv
    -mno-outline-atomics
    -Wno-all
    
    # inline thresholds
    # -mllvm -inline-threshold=200
    # -mllvm -unroll-threshold=75
    # -falign-loops=32
    # -funroll-loops
    # -finline-functions
    -fomit-frame-pointer
    # functions & vectors
    # -ffunction-sections (causes ld.lld orphaned section errors in vmlinux)
    -fslp-vectorize
    -fdelete-null-pointer-checks
    -moutline 
    # =================================================================
    # RAW PERFORMANCE FLAGS — DO NOT REMOVE!
    # These intentionally disable security overhead for maximum speed:
    #   -fno-stack-protector    : skip canary checks (~2-5% syscall speedup)
    #   -mbranch-protection=none: skip PAC sign/auth (~1-3% branch overhead)
    #   -mharden-sls=none      : skip SLS barrier instructions
    # =================================================================
    -mharden-sls=none
    -mbranch-protection=none
    -fno-semantic-interposition
    -fno-stack-protector
    -fno-math-errno
    -fno-trapping-math
    -fno-signed-zeros
    -fassociative-math
    -freciprocal-math
    

    # polly flags
    # -Xclang -load -Xclang LLVMPolly.so
    # -mllvm -polly
    # -mllvm -polly-ast-use-context
    # -mllvm -polly-vectorizer=stripmine
    # -mllvm -polly-invariant-load-hoisting
    # -mllvm -polly-enable-simplify
    # -mllvm -polly-reschedule
    # -mllvm -polly-postopts
    # -mllvm -polly-tiling
    # -mllvm -polly-2nd-level-tiling
    # -mllvm -polly-register-tiling
    # -mllvm -polly-pattern-matching-based-opts
    # -mllvm -polly-matmul-opt
    # -mllvm -polly-tc-opt
    # -mllvm -polly-process-unprofitable
)
KERNEL_KCFLAGS="-w ${EXTREME_CLANG_FLAGS[*]}"

if [ "$BYPASSCHARGING" == "on" ]; then
    KERNEL_KCFLAGS="$KERNEL_KCFLAGS -DCONFIG_MCA_BYPASS=1"
fi
if [ "$HTSR" == "on" ]; then
    KERNEL_KCFLAGS="$KERNEL_KCFLAGS -DCONFIG_HTSR_240=1"
fi
if [ "$WIFI_EXPLOIT" == "on" ]; then
    KERNEL_KCFLAGS="$KERNEL_KCFLAGS -DCONFIG_WIFI_EXPLOIT=1"
fi
if [ "$KGSL_EXPLOIT" == "on" ]; then
    KERNEL_KCFLAGS="$KERNEL_KCFLAGS -DCONFIG_KGSL_EXPLOIT=1"
fi
if [ "$DATA_EXPLOIT" == "on" ]; then
    KERNEL_KCFLAGS="$KERNEL_KCFLAGS -DCONFIG_DATA_EXPLOIT=1"
fi

if [ "$DEBUG_MODE" == "off" ]; then
    KERNEL_KCFLAGS="$KERNEL_KCFLAGS -fmerge-all-constants"
    KERNEL_LDFLAGS="--icf=all"
else
    KERNEL_LDFLAGS=""
fi

if ! check_clang; then
    echo "[-] No Clang toolchain found!"
    exit 1
fi

# ==========================================
# Kernel Config
# ==========================================
mkdir -p "$OUT_DIR"
make O="$OUT_DIR" CC=clang LLVM=1 LLVM_IAS=1 KCFLAGS="$KERNEL_KCFLAGS" LDFLAGS="$KERNEL_LDFLAGS" konoha_defconfig || exit 1

# Root config
case "$VARIANT" in
    stock) scripts/config --file "$OUT_DIR/.config" -d CONFIG_KSU -d CONFIG_KSU_SUSFS -d CONFIG_KPM ;;
    root)  scripts/config --file "$OUT_DIR/.config" -e CONFIG_KSU -d CONFIG_KSU_SUSFS ;;
    susfs) 
        scripts/config --file "$OUT_DIR/.config" -e CONFIG_KSU_SUSFS -e CONFIG_KSU_SUSFS_SUS_MAP
        if [ "$VARIANT" != "stock" ]; then
            scripts/config --file "$OUT_DIR/.config" -e CONFIG_KSU
        else
            scripts/config --file "$OUT_DIR/.config" -d CONFIG_KSU
        fi
        ;;
esac

# Root/KPM config
if [ "$ROOT" == "apatch" ] || [ "$ROOT" == "folkpatch" ]; then
    scripts/config --file "$OUT_DIR/.config" -d CONFIG_KSU
    scripts/config --file "$OUT_DIR/.config" -e CONFIG_KPM -e CONFIG_KALLSYMS -e CONFIG_KALLSYMS_ALL
elif [ "$KPM" == "on" ]; then
    scripts/config --file "$OUT_DIR/.config" -e CONFIG_KPM -e CONFIG_KALLSYMS -e CONFIG_KALLSYMS_ALL
else
    scripts/config --file "$OUT_DIR/.config" -d CONFIG_KPM
fi

# HZ config
case "$HZ" in
    100)  scripts/config --file "$OUT_DIR/.config" -d CONFIG_HZ_300 -d CONFIG_HZ_250 -d CONFIG_HZ_500 -d CONFIG_HZ_1000 -e CONFIG_HZ_100 --set-val CONFIG_HZ 100 -e CONFIG_RCU_LAZY ;;
    500)  scripts/config --file "$OUT_DIR/.config" -d CONFIG_HZ_300 -d CONFIG_HZ_250 -d CONFIG_HZ_100 -d CONFIG_HZ_1000 -e CONFIG_HZ_500 --set-val CONFIG_HZ 500 -d CONFIG_RCU_LAZY ;;
    1000) scripts/config --file "$OUT_DIR/.config" -d CONFIG_HZ_300 -d CONFIG_HZ_250 -d CONFIG_HZ_100 -d CONFIG_HZ_500 -e CONFIG_HZ_1000 --set-val CONFIG_HZ 1000 -d CONFIG_RCU_LAZY ;;
    *)    scripts/config --file "$OUT_DIR/.config" -d CONFIG_HZ_300 -d CONFIG_HZ_1000 -d CONFIG_HZ_100 -d CONFIG_HZ_500 -e CONFIG_HZ_250 --set-val CONFIG_HZ 250 ;;
esac

# Hardened config
if [ "$HARDENED" == "off" ]; then
    scripts/config --file "$OUT_DIR/.config" -d CONFIG_CPU_MITIGATIONS -d CONFIG_MITIGATE_SPECTRE_BRANCH_HISTORY
fi

# LTO config
case "$LTO_TYPE" in
    full) scripts/config --file "$OUT_DIR/.config" -d CONFIG_LTO_NONE -d CONFIG_LTO_CLANG_THIN -e CONFIG_LTO_CLANG -e CONFIG_LTO_CLANG_FULL ;;
    none) scripts/config --file "$OUT_DIR/.config" -d CONFIG_LTO_CLANG -d CONFIG_LTO_CLANG_FULL -d CONFIG_LTO_CLANG_THIN -e CONFIG_LTO_NONE ;;
    *)    scripts/config --file "$OUT_DIR/.config" -d CONFIG_LTO_NONE -d CONFIG_LTO_CLANG_FULL -e CONFIG_LTO_CLANG -e CONFIG_LTO_CLANG_THIN ;;
esac

# AutoFDO
AFDO_PROFILE=""
if [ "$AUTOFDO" == "on" ]; then
    scripts/config --file "$OUT_DIR/.config" -e CONFIG_AUTOFDO_CLANG
    AFDO_PROFILE="$KERNEL_DIR/android/gki/aarch64/afdo/kernel.afdo"
    [ ! -f "$AFDO_PROFILE" ] && { echo "[-] AutoFDO profile not found!"; exit 1; }
fi

# Reduce debug overhead for production kernel
# NOTE: Each config was verified against android/abi_gki_aarch64_qcom.
# CONFIG_SCHED_DEBUG and CONFIG_SLUB_DEBUG are NOT disabled — they export
# ABI symbols (sched_feat_keys, get_each_object_track, get_slabinfo).
# CONFIG_KASAN cannot be compiled out — vendor modules depend on
# kasan_flag_enabled. We disable it at runtime via kasan=off cmdline.
echo "=========================================="
echo "[+] Applying debug reduction configs..."
echo "=========================================="
DEBUG_REDUCTION_ARGS=(
    -e CONFIG_DEBUG_INFO_REDUCED
    -d CONFIG_DEBUG_MISC
    -d CONFIG_BT_DEBUGFS
    -d CONFIG_DEBUG_MEMORY_INIT
    -d CONFIG_PROFILING
    -d CONFIG_PRINTK_CALLER
    -d CONFIG_RCU_TRACE
    -d CONFIG_CMA_DEBUGFS
    -d CONFIG_UBSAN -d CONFIG_UBSAN_BOUNDS -d CONFIG_UBSAN_ARRAY_BOUNDS -d CONFIG_UBSAN_LOCAL_BOUNDS -d CONFIG_UBSAN_SANITIZE_ALL -d CONFIG_UBSAN_TRAP

    # === RE-VERIFIED SAFE COMPILE-TIME DISABLES (readelf + modinfo traced) ===
    -d CONFIG_CLEANCACHE           # 0 DLKMs import, no namespace deps
    -d CONFIG_PRINTK_TIME          # bool default only, no symbol exported
    # ⛔ -d CONFIG_ANDROID_DEBUG_SYMBOLS  # msm_sysstats.ko imports MINIDUMP ns!
    # ⛔ -d CONFIG_ANDROID_DEBUG_KINFO    # ANDROID_GKI_struct_kernel_all_info exported
)
scripts/config --file "$OUT_DIR/.config" "${DEBUG_REDUCTION_ARGS[@]}"

# KASAN runtime disable (can't compile out — ABI symbol kasan_flag_enabled)
# Also override bootloader's panic_on_rcu_stall — SUSFS hooks can trigger
# scheduling-while-atomic BUGs that cascade into false RCU stalls.
CURRENT_CMDLINE=$(grep '^CONFIG_CMDLINE=' "$OUT_DIR/.config" | sed 's/^CONFIG_CMDLINE="//' | sed 's/"$//')
CMDLINE_APPEND=""
echo "$CURRENT_CMDLINE" | grep -q "kasan=off" || CMDLINE_APPEND="$CMDLINE_APPEND kasan=off"
echo "$CURRENT_CMDLINE" | grep -q "panic_on_rcu_stall" || CMDLINE_APPEND="$CMDLINE_APPEND kernel.panic_on_rcu_stall=0"

# === RUNTIME PERF PARAMS (zero-risk — code stays compiled, just disabled at boot) ===
# These achieve the same effect as compile-time config disables but without
# any struct layout changes, KABI breaks, or Kconfig cascades.
echo "$CURRENT_CMDLINE" | grep -q "init_on_alloc=" || CMDLINE_APPEND="$CMDLINE_APPEND init_on_alloc=0"
echo "$CURRENT_CMDLINE" | grep -q "page_alloc.shuffle=" || CMDLINE_APPEND="$CMDLINE_APPEND page_alloc.shuffle=0"
echo "$CURRENT_CMDLINE" | grep -q "randomize_kstack_offset=" || CMDLINE_APPEND="$CMDLINE_APPEND randomize_kstack_offset=0"
echo "$CURRENT_CMDLINE" | grep -q "loglevel=" || CMDLINE_APPEND="$CMDLINE_APPEND loglevel=0"
# ⛔ audit=0 — BREAKS SELinux enforcing → bootloop
# ⛔ nosoftlockup — risky on Qualcomm SoC, vendor drivers may expect watchdog

if [ "$DEBUG_MODE" == "on" ]; then
    echo "$CURRENT_CMDLINE" | grep -q "nokaslr" || CMDLINE_APPEND="$CMDLINE_APPEND nokaslr"
fi
[ -n "$CMDLINE_APPEND" ] && \
    scripts/config --file "$OUT_DIR/.config" --set-str CONFIG_CMDLINE "$CURRENT_CMDLINE$CMDLINE_APPEND"

# Setup Droidspaces Support
if [ "$DROIDSPACES" == "on" ]; then
    ./setup_droidspaces.sh "$OUT_DIR"
fi

# Setup NetHunter Support
if [ "$NETHUNTER" == "on" ]; then
    ./nethunter_patch.sh "$OUT_DIR"
fi

# Single olddefconfig to finalize all changes
make O="$OUT_DIR" CC=clang LLVM=1 LLVM_IAS=1 olddefconfig || exit 1

# ==========================================
# Build
# ==========================================
CPUS=$(nproc --all)
MAKE_ARGS=(
    "-j${CPUS}" "O=${OUT_DIR}" "CC=clang" "LD=ld.lld" "AR=llvm-ar" "NM=llvm-nm"
    "OBJCOPY=llvm-objcopy" "OBJDUMP=llvm-objdump" "STRIP=llvm-strip"
    "LLVM=1" "LLVM_IAS=1" "KCFLAGS=${KERNEL_KCFLAGS}" "LDFLAGS=${KERNEL_LDFLAGS}"
)
[ -n "$AFDO_PROFILE" ] && MAKE_ARGS+=("CLANG_AUTOFDO_PROFILE=${AFDO_PROFILE}")

echo "[+] Building with ${CPUS} threads..."
make "${MAKE_ARGS[@]}" || { echo "[-] Build failed!"; exit 1; }

# ==========================================
# KPM Post-Build Patching
# ==========================================
if [ "$KPM" == "on" ]; then
    echo "=========================================="
    echo "[+] Patching kernel Image with KernelPatch..."
    echo "=========================================="

    # kptools operates on the raw (uncompressed) Image
    RAW_IMAGE="$ZIMAGE_DIR/Image"
    if [ ! -f "$RAW_IMAGE" ]; then
        if [ -f "$ZIMAGE_DIR/Image.gz" ]; then
            echo "[+] Decompressing Image.gz for KPM patching..."
            gzip -dk "$ZIMAGE_DIR/Image.gz"
        else
            echo "[-] No kernel Image found for KPM patching!"; exit 1
        fi
    fi

    cp "$RAW_IMAGE" "${RAW_IMAGE}.orig"
    "$KPTOOLS_BIN" -p -i "${RAW_IMAGE}.orig" -S "$KPM_SUPERKEY" -k "$KPIMG_BIN" -o "$RAW_IMAGE"
    KPM_RC=$?
    rm -f "${RAW_IMAGE}.orig"

    if [ $KPM_RC -ne 0 ]; then
        echo "[-] KPM patching failed (exit code: $KPM_RC)!"
        exit 1
    fi

    # Re-compress if the build originally produced Image.gz
    if [ -f "$ZIMAGE_DIR/Image.gz" ]; then
        echo "[+] Re-compressing patched Image → Image.gz"
        gzip -nkf "$RAW_IMAGE"
    fi

    echo "[+] KPM patching successful"
    echo "[+] SuperKey: $KPM_SUPERKEY"
elif [ "$KPM" == "on" ]; then
    echo "[!] KPM runtime patching skipped (kpm_patch=off)"
fi

# ==========================================
# Package
# ==========================================
find "$KERNEL_DIR" -maxdepth 1 -type f -name "Kono-Ha-*.zip" -exec rm -v {} \;
rm -rf "$KERNEL_DIR/Kono-Ha-Release"

TIME=$(date "+%Y%m%d-%H%M%S")
TEMP_DIR="$KERNEL_DIR/anykernel_temp"
rm -rf "$TEMP_DIR"

[ ! -d "$KERNEL_DIR/anykernel" ] && { echo "[-] anykernel directory not found!"; exit 1; }
cp -r "$KERNEL_DIR/anykernel" "$TEMP_DIR"

# Copy kernel image
for img in Image.gz-dtb Image.gz Image; do
    [ -f "$ZIMAGE_DIR/$img" ] && { cp -v "$ZIMAGE_DIR/$img" "$TEMP_DIR/"; break; }
done


echo "Applying Custom Kernel Name and Spoof Uname..."
if [ -n "$KERNEL_NAME" ]; then
    sed -i "s/CONFIG_LOCALVERSION=".*"/CONFIG_LOCALVERSION="$KERNEL_NAME"/g" arch/arm64/configs/konoha_defconfig
fi

if [ "$SPOOF_UNAME" == "on" ]; then
    # Ensure SUSFS spoof is enabled
    sed -i "s/# CONFIG_KSU_SUSFS_SPOOF_UNAME is not set/CONFIG_KSU_SUSFS_SPOOF_UNAME=y/g" arch/arm64/configs/konoha_defconfig
elif [ "$SPOOF_UNAME" == "off" ]; then
    sed -i "s/CONFIG_KSU_SUSFS_SPOOF_UNAME=y/# CONFIG_KSU_SUSFS_SPOOF_UNAME is not set/g" arch/arm64/configs/konoha_defconfig
fi

# Build filename
ZIP_SUFFIX=""
if [ "$VARIANT" == "stock" ]; then
    ZIP_SUFFIX="-stock"
elif [ "$VARIANT" == "root" ]; then
    ZIP_SUFFIX="-root-$REPO_NAME"
elif [ "$VARIANT" == "susfs" ]; then
    ZIP_SUFFIX="-susfs-$REPO_NAME-v2.1"
fi

[ "$KPM" == "on" ] && ZIP_SUFFIX="${ZIP_SUFFIX}-kpm"
[ "$HARDENED" == "on" ] && ZIP_SUFFIX="${ZIP_SUFFIX}-hardened"
[ "$BYPASSCHARGING" == "on" ] && ZIP_SUFFIX="${ZIP_SUFFIX}-bypasscharging"
[ "$DROIDSPACES" == "on" ] && ZIP_SUFFIX="${ZIP_SUFFIX}-droidspaces"
[ "$NETHUNTER" == "on" ] && ZIP_SUFFIX="${ZIP_SUFFIX}-nethunter"
[ "$HTSR" == "off" ] && ZIP_SUFFIX="${ZIP_SUFFIX}-nohtsr"
[ "$WIFI_EXPLOIT" == "off" ] && ZIP_SUFFIX="${ZIP_SUFFIX}-nowifi"
[ "$KGSL_EXPLOIT" == "off" ] && ZIP_SUFFIX="${ZIP_SUFFIX}-nokgsl"
[ "$DATA_EXPLOIT" == "off" ] && ZIP_SUFFIX="${ZIP_SUFFIX}-nodata"

HZ_LABEL=""
case "$HZ" in 100) HZ_LABEL="-powersave" ;; 500) HZ_LABEL="-performance" ;; 1000) HZ_LABEL="-ultra-performance" ;; *) HZ_LABEL="-balance" ;; esac

ZIP_NAME="Kono-Ha-${VERSION}${ZIP_SUFFIX}${HZ_LABEL}-$TIME.zip"
cd "$TEMP_DIR" && zip -r9 "../$ZIP_NAME" * -x .git README.md *placeholder > /dev/null && cd ..
rm -rf "$TEMP_DIR"

# Copy to release dir for CI
mkdir -p "$KERNEL_DIR/Kono-Ha-Release"
cp "$KERNEL_DIR/$ZIP_NAME" "$KERNEL_DIR/Kono-Ha-Release/"

# GitHub Actions outputs
if [ "$GITHUB_ACTIONS" == "true" ]; then
    echo "ZIP_PATH=$KERNEL_DIR/$ZIP_NAME" >> "$GITHUB_ENV"
    echo "ZIP_NAME=$ZIP_NAME" >> "$GITHUB_ENV"
    [ "$KPM" == "on" ] && echo "KPM_SUPERKEY=$KPM_SUPERKEY" >> "$GITHUB_ENV"
fi

BUILD_END=$(date +"%s")
DIFF=$((BUILD_END - BUILD_START))
echo -e "\n=========================================="
echo "Build completed in $((DIFF / 60))m $((DIFF % 60))s"
echo "Output: $KERNEL_DIR/$ZIP_NAME"
echo "=========================================="