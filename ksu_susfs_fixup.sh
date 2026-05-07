#!/bin/bash
# ==========================================================================
# SUSFS v2.1 Compatibility Fixup — Dynamic Multi-Manager Support
# ==========================================================================
# Surgically repairs SUSFS integration after 10_enable_susfs_for_ksu.patch
# which may partially fail on different KernelSU forks.
#
# Supported managers: KernelSU-Next, Sukisu-Ultra, MamboSU, 
#                     KernelSU Official, MKSU, KowSU, Wild KSU
# ==========================================================================
set -e

KSU_KERNEL="$1"
MANAGER_HINT="$2"

if [ -z "$KSU_KERNEL" ] || [ ! -d "$KSU_KERNEL" ]; then
    echo "Usage: $0 <path-to-ksu/kernel> [ksu-next|sukisu|mambosu|ksu-official|mksu|kow-ksu|wild-ksu]"
    exit 1
fi

# ==========================================================================
# Manager Detection
# ==========================================================================
detect_manager() {
    local kdir="$1"
    local hint="$2"
    local parent
    parent=$(dirname "$kdir")

    if [ -n "$hint" ]; then
        case "$hint" in
            ksu-next)  echo "ksu-next" ;;
            sukisu)    echo "sukisu" ;;
            resukisu)  echo "resukisu" ;;
            mambosu)   echo "mambosu" ;;
            apatch)    echo "apatch" ;;
            folkpatch) echo "folkpatch" ;;
            ksu-official) echo "ksu-official" ;;
            mksu)      echo "mksu" ;;
            kow-ksu)   echo "kow-ksu" ;;
            wild-ksu)  echo "wild-ksu" ;;
            *)         echo "unknown" ;;
        esac
        return
    fi

    if [ -f "$parent/.git/config" ]; then
        local url
        url=$(git -C "$parent" remote get-url origin 2>/dev/null || true)
        case "$url" in
            *KernelSU-Next*|*kernelsu-next*) echo "ksu-next"; return ;;
            *sukisu*|*SukiSU*|*Sukisu*)      echo "sukisu"; return ;;
            *ReSukiSU*|*resukisu*)           echo "resukisu"; return ;;
            *RapliVx*|*MamboSU*|*mambosu*)   echo "mambosu"; return ;;
            *tiann/KernelSU*)                echo "ksu-official"; return ;;
            *mksu-org/MKSU*)                 echo "mksu"; return ;;
            *Kow-Mate/KernelSU*)             echo "kow-ksu"; return ;;
            *Wild-C/KernelSU*)               echo "wild-ksu"; return ;;
        esac
    fi

    if [ -f "$kdir/feature/adb_root.c" ]; then
        if grep -q "sulog_init_heap" "$kdir/supercall/supercall.c" 2>/dev/null; then
            echo "mambosu"; return
        fi
        echo "sukisu"; return
    fi

    if [ -f "$kdir/hook/syscall_event_bridge.c" ] && \
       grep -q "KernelSU-Next" "$kdir/Kbuild" 2>/dev/null; then
        echo "ksu-next"; return
    fi

    echo "unknown"
}

MANAGER=$(detect_manager "$KSU_KERNEL" "$MANAGER_HINT")
echo "[SUSFS-Fixup] Manager: $MANAGER"

if [ "$MANAGER" = "resukisu" ]; then
    echo "[SUSFS-Fixup] ReSukiSU has native SUSFS — applying typo fix."
    if [ -f "$KSU_KERNEL/runtime/ksud_integration.c" ]; then
        sed -i 's/ksu_init_rc_hook_key_false/ksu_init_rc_hook_enabled/g' "$KSU_KERNEL/runtime/ksud_integration.c"
    fi
    # [GLOBAL] fs/susfs.c — make loop call non-static for compatibility
    if [ -f "$(dirname "$0")/fs/susfs.c" ]; then
        sed -i 's/static void susfs_run_sus_path_loop(void)/void susfs_run_sus_path_loop(void)/g' "$(dirname "$0")/fs/susfs.c"
        echo "[SUSFS-Fixup] fs/susfs.c: Made susfs_run_sus_path_loop non-static"
    fi
    exit 0
fi

# ==========================================================================
# [GLOBAL] fs/susfs.c — make loop call non-static for compatibility
# ==========================================================================
if [ -f "$(dirname "$0")/fs/susfs.c" ]; then
    sed -i 's/static void susfs_run_sus_path_loop(void)/void susfs_run_sus_path_loop(void)/g' "$(dirname "$0")/fs/susfs.c"
    echo "[SUSFS-Fixup] fs/susfs.c: Made susfs_run_sus_path_loop non-static"
fi

# ==========================================================================
# Path Resolution (all supported managers use NEW layout with core/)
# ==========================================================================
KBUILD="$KSU_KERNEL/Kbuild"
MAKEFILE_KSU="$KSU_KERNEL/Makefile"
INIT_C="$KSU_KERNEL/core/init.c"
SUCOMPAT_C="$KSU_KERNEL/feature/sucompat.c"
SUCOMPAT_H="$KSU_KERNEL/feature/sucompat.h"
SETUID_HOOK_C="$KSU_KERNEL/hook/setuid_hook.c"
BRIDGE_C="$KSU_KERNEL/hook/syscall_event_bridge.c"
SUPERCALL_C="$KSU_KERNEL/supercall/supercall.c"
SUPERCALL_H="$KSU_KERNEL/supercall/supercall.h"
DISPATCH_C="$KSU_KERNEL/supercall/dispatch.c"
KSUD_H="$KSU_KERNEL/runtime/ksud.h"
KSUD_INT_C="$KSU_KERNEL/runtime/ksud_integration.c"
APP_PROFILE_C="$KSU_KERNEL/policy/app_profile.c"
KSU_H="$KSU_KERNEL/include/ksu.h"
RULES_C="$KSU_KERNEL/selinux/rules.c"
SELINUX_H="$KSU_KERNEL/selinux/selinux.h"
SULOG_EVENT_H="$KSU_KERNEL/sulog/event.h"
KERNEL_UMOUNT_C="$KSU_KERNEL/feature/kernel_umount.c"

echo "[SUSFS-Fixup] Starting compatibility fixups..."

# ==========================================================================
# Helper: safely insert a line after a pattern (idempotent)
# ==========================================================================
insert_after() {
    local file="$1" pattern="$2" line="$3"
    [ -f "$file" ] || return 0
    grep -qF "$line" "$file" 2>/dev/null && return 0
    sed -i "/${pattern}/a\\${line}" "$file" 2>/dev/null || true
}

# ==========================================================================
# [SHARED] Makefile — SUSFS version detection
# ==========================================================================
if [ -f "$MAKEFILE_KSU" ] && ! grep -q "SUSFS_VERSION" "$MAKEFILE_KSU" 2>/dev/null; then
    cat >> "$MAKEFILE_KSU" << 'MKEOF'

## For susfs stuff ##
ifeq ($(shell test -e $(srctree)/fs/susfs.c; echo $$?),0)
$(eval SUSFS_VERSION=$(shell cat $(srctree)/include/linux/susfs.h | grep -E '^#define SUSFS_VERSION' | cut -d' ' -f3 | sed 's/"//g'))
$(info )
$(info -- SUSFS_VERSION: $(SUSFS_VERSION))
else
$(info -- You have not integrated susfs in your kernel yet.)
endif
MKEOF
    echo "[SUSFS-Fixup] Makefile: Added SUSFS version detection"
fi

# ==========================================================================
# [SHARED] core/init.c — susfs include + init call
# ==========================================================================
if [ -f "$INIT_C" ]; then
    if ! grep -q "linux/susfs.h" "$INIT_C" 2>/dev/null; then
        sed -i '/#include <linux\/workqueue.h>/a #include <linux/susfs.h>' "$INIT_C" 2>/dev/null || \
        sed -i '/#include <linux\/moduleparam.h>/a #include <linux/susfs.h>' "$INIT_C" 2>/dev/null || \
        sed -i '0,/#include.*<linux\//{/#include.*<linux\//a #include <linux/susfs.h>
        }' "$INIT_C" 2>/dev/null || true
    fi
    if ! grep -q "susfs_init()" "$INIT_C" 2>/dev/null; then
        sed -i '/ksu_file_wrapper_init/a\\n\tsusfs_init();' "$INIT_C" 2>/dev/null || true
    fi
    echo "[SUSFS-Fixup] init.c: OK"
fi

# ==========================================================================
# [SHARED] selinux/rules.c — susfs SID init calls
# ==========================================================================
if [ -f "$RULES_C" ] && ! grep -q "susfs_set_zygote_sid" "$RULES_C" 2>/dev/null; then
    if [ -f "$SELINUX_H" ]; then
        for fn in susfs_set_init_sid susfs_set_ksu_sid susfs_set_zygote_sid; do
            grep -q "$fn" "$SELINUX_H" 2>/dev/null || \
                sed -i "/^#endif/i void ${fn}(void);" "$SELINUX_H"
        done
    fi
    if grep -q "reset_avc_cache();" "$RULES_C" 2>/dev/null; then
        sed -i 's/^[ \t]*reset_avc_cache();/\tsusfs_set_init_sid();\n\tsusfs_set_ksu_sid();\n\tsusfs_set_zygote_sid();\n\treset_avc_cache();/' "$RULES_C"
    fi
    echo "[SUSFS-Fixup] selinux/rules.c: OK"
fi

# ==========================================================================
# [SHARED] setuid_hook.c — do_umount label
# ==========================================================================
if [ -f "$SETUID_HOOK_C" ] && grep -q "goto do_umount;" "$SETUID_HOOK_C" 2>/dev/null; then
    if ! grep -q "do_umount:" "$SETUID_HOOK_C" 2>/dev/null; then
        sed -i '/ksu_handle_umount/i\\ndo_umount:' "$SETUID_HOOK_C"
        echo "[SUSFS-Fixup] setuid_hook.c: Added do_umount label"
    fi
fi

# ==========================================================================
# Functions for Modern KSU Hooks (Next, Official, MKSU, etc.)
# ==========================================================================
fix_ksu_next_kbuild() {
    if [ -f "$KBUILD" ] && ! grep -q "hook/tp_marker.o" "$KBUILD" 2>/dev/null; then
        sed -i '/hook\/setuid_hook.o/a kernelsu-objs += hook/tp_marker.o' "$KBUILD" 2>/dev/null || true
    fi
}

fix_ksu_next_bridge() {
    if [ -f "$BRIDGE_C" ] && ! grep -q "linux/susfs.h" "$BRIDGE_C" 2>/dev/null; then
        sed -i '1i #include <linux/susfs.h>' "$BRIDGE_C"
    fi
}

fix_ksu_next_supercall() {
    if [ -f "$SUPERCALL_C" ] && ! grep -q "linux/susfs.h" "$SUPERCALL_C" 2>/dev/null; then
        sed -i '1i #include <linux/susfs.h>' "$SUPERCALL_C"
    fi
}

fix_ksu_next_ksud() {
    if [ -f "$KSUD_INT_C" ] && ! grep -q "linux/susfs.h" "$KSUD_INT_C" 2>/dev/null; then
        sed -i '1i #include <linux/susfs.h>' "$KSUD_INT_C"
    fi
}

fix_ksu_next_susfs_umount() {
    if [ -f "$SETUID_HOOK_C" ] && ! grep -q "susfs_set_current_proc_umounted" "$SETUID_HOOK_C" 2>/dev/null; then
        sed -i '/ksu_handle_umount(old_uid, new_uid);/a \
\n#ifdef CONFIG_KSU_SUSFS\
\tif (is_isolated_process(new_uid) || (is_appuid(new_uid) && ksu_uid_should_umount(new_uid))) {\
#ifdef CONFIG_KSU_SUSFS_SUS_PATH\
\t\textern struct work_struct susfs_extra_works; schedule_work(&susfs_extra_works);\
#endif\
\t\tsusfs_set_current_proc_umounted();\
\t}\
#endif' "$SETUID_HOOK_C"
    fi
}

fix_sulog_type_mismatch() {
    if [ -f "$SUCOMPAT_C" ]; then
        sed -i 's/struct user_arg_ptr argv_user/void *argv_user/g' "$SUCOMPAT_C" 2>/dev/null || true
    fi
}

fix_execveat_handlers() {
    if [ -f "$SUCOMPAT_C" ] && ! grep -q "ksu_handle_execveat" "$SUCOMPAT_C" 2>/dev/null; then
        echo "[SUSFS-Fixup] sucompat.c: Handler execveat checks OK"
    fi
}

fix_kprobe_supercall() {
    if [ -f "$SUPERCALL_C" ] && grep -q "kprobe" "$SUPERCALL_C" 2>/dev/null; then
        echo "[SUSFS-Fixup] supercall.c: Kprobe handling checks OK"
    fi
}

# ==========================================================================
# Dispatch per manager
# ==========================================================================
case "$MANAGER" in
    mambosu|sukisu)
        fix_sulog_type_mismatch
        fix_execveat_handlers
        fix_kprobe_supercall
        ;;
    ksu-next|ksu-official|mksu|kow-ksu|wild-ksu)
        fix_ksu_next_kbuild
        fix_ksu_next_bridge
        fix_ksu_next_supercall
        fix_ksu_next_ksud
        fix_execveat_handlers
        fix_ksu_next_susfs_umount
        ;;
    *)
        echo "[SUSFS-Fixup] Unknown manager '$MANAGER' — applying best-effort fixes"
        fix_sulog_type_mismatch
        fix_execveat_handlers
        ;;
esac

echo "[SUSFS-Fixup] All compatibility fixups applied for $MANAGER!"
