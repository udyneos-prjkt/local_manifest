#!/bin/bash

set -o pipefail -o errtrace
source .env 2>/dev/null || { echo "❌ .env not found"; exit 1; }

# ========== CONFIG ==========
ROM="EvolutionX-10.x"; DEV="lancelot"; TYPE="userdebug"; VER="bp1a"; MAIN="mnrdnn"
OUT="out/target/product/${DEVICE:-$DEV}"; LOG="build.log"; START=$(date +%s)
JOBS=$(nproc); export TZ="Asia/Jakarta"

# ========== COLORS ==========
C='\033[0;36m'; G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'

# ========== TELEGRAM ==========
tg() { curl -s -X POST "https://api.telegram.org/bot${TT}/sendMessage" -d "chat_id=${CI}" -d "parse_mode=HTML" --data-urlencode "text=$1" >/dev/null; }
tg_edit() { curl -s -X POST "https://api.telegram.org/bot${TT}/editMessageText" -d "chat_id=${CI}" -d "message_id=$1" --data-urlencode "text=$2" >/dev/null; }
tg_doc() { curl -s -X POST "https://api.telegram.org/bot${TT}/sendDocument" -F "chat_id=${CI}" -F "document=@$1" -F "caption=$2" >/dev/null; }

# ========== UPLOAD ==========
pd_upload() { 
    [ ! -f "$1" ] && echo "NOT_FOUND" && return
    ID=$(curl -sS -T "$1" -u :$PD https://pixeldrain.com/api/file/ | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
    [ -n "$ID" ] && echo "https://pixeldrain.com/u/$ID" || echo "FAILED"
}
gf_upload() {
    for s in store2 store3 store4 store5; do
        URL=$(curl -s -F "file=@$1" "https://${s}.gofile.io/uploadFile" | grep -oP '(?<=downloadPage":")[^"]+')
        [ -n "$URL" ] && echo "$URL" && return
    done; echo "FAILED"
}

# ========== BUILD ==========
echo -e "${C}🕒 Starting build at $(date)${N}"
tg "Build started
${ROM}
Device: ${DEV}-${TYPE}
by: ${MAIN}
🌏 $(date +'%d %b %Y %H:%M')"

# Clean
clean(){
echo -e "${Y}🧹 Cleaning...${N}"
rm -rf .repo/local_manifests prebuilts/clang/host/linux-x86 $OUT \
       device/xiaomi/$DEV vendor/xiaomi/$DEV device/xiaomi/mt6768-common \
       kernel/xiaomi/mt6768 vendor/xiaomi/mt6768-common \
       device/mediatek/sepolicy_vndr hardware/mediatek hardware/xiaomi
}
# Init & Sync
repo_sync(){
echo -e "${Y}📦 Syncing repos...${N}"
repo init -u https://github.com/Evolution-X/manifest -b vic --git-lfs
}
clone(){
echo -e "${Y}📦 Clone repo...${N}"
# Clone trees
git clone https://github.com/udyneos-prjkt/device_xiaomi_lancelot device/xiaomi/$DEV -b vic --depth=1
git clone https://github.com/udyneos-prjkt/device_xiaomi_mt6768-common device/xiaomi/mt6768-common -b vic --depth=1
git clone https://github.com/udyneos-prjkt/proprietary_vendor_xiaomi_lancelot vendor/xiaomi/$DEV -b vic --depth=1
git clone https://github.com/udyneos-prjkt/proprietary_vendor_xiaomi_mt6768-common.git vendor/xiaomi/mt6768-common -b vic --depth=1
git clone https://github.com/udyneos-prjkt/android_kernel_xiaomi_mt6768.git kernel/xiaomi/mt6768 --depth=1 -b kernel-tree
# hardware/xiaomi
git clone https://github.com/LineageOS/android_hardware_xiaomi -b lineage-22.2 hardware/xiaomi
# hardware/mediatek
git clone https://github.com/LineageOS/android_hardware_mediatek -b lineage-22.2 hardware/mediatek
# Sepolicy Tree
git clone https://github.com/LineageOS/android_device_mediatek_sepolicy_vndr -b lineage-22.2 device/mediatek/sepolicy_vndr
# Sync

if [ -f /opt/crave/resync.sh ]; then
    /opt/crave/resync.sh
else
    repo sync -c --no-clone-bundle --no-tags --optimized-fetch --prune --force-sync -j$(nproc --all)
fi
}

setup(){
# Setup
echo -e "${Y}⚙️ Setting up environment...${N}"
. build/envsetup.sh
export BUILD_USERNAME=$MAIN
export BUILD_HOSTNAME=crave

# Setup keys
lunch lineage_${DEV}-${VER}-${TYPE}

# Monitor
MSG=$(curl -s -X POST "https://api.telegram.org/bot${TT}/sendMessage" -d "chat_id=${CI}" -d "text=⚙️ Compiling..." -d "parse_mode=HTML")
MID=$(echo "$MSG" | sed -n 's/.*"message_id":\([0-9]*\).*/\1/p')

# Live monitor
( while true; do
    sleep 30
    STATUS=$(tail -n 30 "$LOG" 2>/dev/null | grep -E '\[[0-9]+%\]|[0-9]+%' | tail -1)
    [ -z "$STATUS" ] && STATUS=$(tail -1 "$LOG" 2>/dev/null | cut -c1-60)
    [ -n "$STATUS" ] && tg_edit "$MID" "⏳ Building...
${STATUS:0:100}
Last update: $(date +'%H:%M')"
done ) &
MON_PID=$!
}
# Build
build(){
echo -e "${G}🔨 Building...${N}"
m evolution -j$JOBS 2>&1 | tee "$LOG"
if [ ${PIPESTATUS[0]} -ne 0 ]; then 
    kill $MON_PID 2>/dev/null
    tg "Build failed!
Device: ${DEV}
Build log: $(gf_upload "$LOG")"
    exit 1
fi
kill $MON_PID 2>/dev/null
}
clean
repo_sync
clone
setup
build
# ========== UPLOAD ==========
DUR=$(($(date +%s)-START))
ZIP=$(ls -t $OUT/*.zip 2>/dev/null | head -1)

if [ -n "$ZIP" ]; then
    FINAL="${ROM}-${DEV}-$(date +%Y%m%d).zip"
    mv "$ZIP" "$FINAL"
    SIZE=$(du -h "$FINAL" | awk '{print $1}')
    PD_URL=$(pd_upload "$FINAL")
    
    tg "Build complete!
Device: ${DEV} | ${TYPE}
Size: ${SIZE}
Build took: $((DUR/3600))h $(((DUR%3600)/60))m
Download: ${PD_URL}
"
    
    # Upload images
    for img in boot dtbo recovery ; do
        [ -f "$OUT/${img}.img" ] && tg "🧩 ${img}.img: $(gf_upload "$OUT/${img}.img")"
    done
    
    # Upload OTA
    [ -f "$OUT/${DEV}.json" ] && tg "📑 OTA: $(pd_upload "$OUT/${DEV}.json")"
fi

# Upload log
LOG_SIZE=$(stat -c%s "$LOG" 2>/dev/null || stat -f%z "$LOG" 2>/dev/null)
[ -f "$LOG" ] && [ "$LOG_SIZE" -le 52428800 ] && tg_doc "$LOG" "Build Log - ${DEV}"
echo -e "${G}✅ Done! Time: $((DUR/60)) minutes${N}"
