#!/bin/bash
# ============================================================================
# streaming-check.sh — 簡單可靠的串流解鎖檢測
# ----------------------------------------------------------------------------
# 為什麼自己寫一個：
#   原版 RegionRestrictionCheck 的 Gemini 檢測是錯的 —— 它抓
#   https://gemini.google.com 的網頁原始碼，去找一串寫死的數字
#   '45631641,null,true'（Google 前端 JS 裡的內部編號）。
#   Google 每次改版那串數字就變，數字一變就回報 No，
#   明明 Gemini 正常能用。使用者天天用 Gemini Pro，腳本卻說 No，
#   就是這個原因。
#
# 這個版本的做法：
#   1. 不用任何寫死的 Cookie、Token、特徵數字
#   2. 每項檢查都印出「測試網址 + HTTP 狀態碼」，可以手動驗證
#   3. 只判斷「服務打不打得開」，不猜內部編號
#   4. Netflix 的 Originals Only 邏輯是修正過的（原版邏輯寫反了）
#
# 用法：
#   bash streaming-check.sh
# 只需要 bash + curl，不用裝其他東西。
# 在 US-1（純 IPv6）上只測 IPv6，在 CAN-1 上 IPv4/IPv6 都測。
# ============================================================================

UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
WORK="/tmp/streaming-check"
mkdir -p "$WORK"

echo "========== 串流解鎖檢測 =========="
echo "測試時間: $(date -u '+%Y-%m-%d %H:%M UTC')"
echo ""

# ---------- 偵測出口 IP ----------
echo "---------- 出口 IP ----------"
IP4=$(curl -4 -s -m 8 https://ifconfig.me 2>/dev/null)
IP6=$(curl -6 -s -m 8 https://ifconfig.me 2>/dev/null)
[ -n "$IP4" ] && echo "IPv4: $IP4" || echo "IPv4: 不支援"
[ -n "$IP6" ] && echo "IPv6: $IP6" || echo "IPv6: 不支援"
echo ""

STACKS=""
[ -n "$IP4" ] && STACKS="$STACKS 4"
[ -n "$IP6" ] && STACKS="$STACKS 6"
if [ -z "$STACKS" ]; then
    echo "沒有可用網路，結束。"
    exit 1
fi

# ---------- 通用工具 ----------
# fetch < -4|-6 > <網址> <存檔> ：下載網頁，印出 HTTP 狀態碼
fetch() {
    curl "$1" -s -L -m 20 --connect-timeout 10 -A "$UA" -o "$3" -w "%{http_code}" "$2" 2>/dev/null || echo "000"
}
# fetch_url < -4|-6 > <網址> <存檔> ：下載網頁，印出「狀態碼 最終網址」
fetch_url() {
    curl "$1" -s -L -m 20 --connect-timeout 10 -A "$UA" -o "$3" -w "%{http_code} %{url_effective}" "$2" 2>/dev/null || echo "000 -"
}

# ---------- 1. Netflix ----------
# 方法：抓兩部片的頁面
#   81280792 = Netflix 自製劇（只要 Netflix 能用就一定打得開）
#   70143836 = Breaking Bad（授權劇，只有完整解鎖才打得開）
# 正確邏輯：
#   自製劇開 + 授權劇被擋 = 僅自製劇（Originals Only）
#   兩部都開            = 完整解鎖
#   兩部都被擋          = 被封鎖
# （原版邏輯寫反：兩部都被擋它也報 Originals Only）
check_netflix() {
    local f="$1" tag="$2"
    local u1="https://www.netflix.com/title/81280792"
    local u2="https://www.netflix.com/title/70143836"
    local c1 c2 e1=0 e2=0
    c1=$(fetch "$f" "$u1" "$WORK/nf1.html")
    c2=$(fetch "$f" "$u2" "$WORK/nf2.html")
    grep -qi "Oh no!\|unblocker or proxy" "$WORK/nf1.html" 2>/dev/null && e1=1
    grep -qi "Oh no!\|unblocker or proxy" "$WORK/nf2.html" 2>/dev/null && e2=1
    local res
    if [ "$c1" = "000" ] || [ "$c2" = "000" ]; then
        res="連線失敗"
    elif [ "$e1" -eq 0 ] && [ "$e2" -eq 1 ]; then
        res="僅自製劇 (Originals Only)"
    elif [ "$e1" -eq 0 ] && [ "$e2" -eq 0 ]; then
        res="完整解鎖 (Full)"
    elif [ "$e1" -eq 1 ] && [ "$e2" -eq 1 ]; then
        res="被封鎖 (兩部片都打不開)"
    else
        res="結果異常，請手動開網址確認"
    fi
    echo "[$tag] Netflix: $res"
    echo "      自製劇: $u1 HTTP $c1 | 授權劇: $u2 HTTP $c2"
}

# ---------- 2. Disney+ ----------
# 方法：直接抓首頁。被地區封鎖會回 403，或頁面寫 "not available in your region"。
# 注意：這是首頁層級的檢查，不是播放測試；原版在 IPv6 下直接跳過不測，
# 這個版本 IPv6 也照測。
check_disney() {
    local f="$1" tag="$2"
    local url="https://www.disneyplus.com/"
    local out code final
    out=$(fetch_url "$f" "$url" "$WORK/dp.html")
    code="${out%% *}"; final="${out#* }"
    local res
    if [ "$code" = "000" ]; then
        res="連線失敗"
    elif grep -qi "not available in your region\|forbidden-location\|is not currently available in your country" "$WORK/dp.html" 2>/dev/null; then
        res="被封鎖 (地區不支援)"
    elif [ "$code" = "403" ]; then
        res="被封鎖 (HTTP 403)"
    elif [ "$code" = "200" ]; then
        res="可用 (首頁可打開)"
    else
        res="不確定 (HTTP $code)"
    fi
    echo "[$tag] Disney+: $res"
    echo "      測試: $url HTTP $code 最終網址: $final"
}

# ---------- 3. YouTube Premium ----------
# 方法：抓 https://www.youtube.com/premium，找地區碼 INNERTUBE_CONTEXT_GL。
# 出現 "Premium is not available in your country" = 該地區不提供。
check_ytpremium() {
    local f="$1" tag="$2"
    local url="https://www.youtube.com/premium"
    local code region
    code=$(fetch "$f" "$url" "$WORK/yt.html")
    region=$(grep -o '"INNERTUBE_CONTEXT_GL":"[A-Z]*"' "$WORK/yt.html" 2>/dev/null | head -1 | cut -d'"' -f4)
    local res
    if [ "$code" = "000" ]; then
        res="連線失敗"
    elif grep -qi "Premium is not available in your country" "$WORK/yt.html" 2>/dev/null; then
        res="不提供 (該地區無 Premium)"
    elif [ -n "$region" ]; then
        res="可用 (地區: $region)"
    elif [ "$code" = "200" ]; then
        res="可用 (地區未知)"
    else
        res="不確定 (HTTP $code)"
    fi
    echo "[$tag] YouTube Premium: $res"
    echo "      測試: $url HTTP $code"
}

# ---------- 4. ChatGPT ----------
# 方法：查 OpenAI 公開的合規端點有沒有 unsupported_country，
# 再加 chatgpt.com 首頁能不能開。兩個都沒擋 = 可用。
check_chatgpt() {
    local f="$1" tag="$2"
    local code1 code2 out final
    code1=$(fetch "$f" "https://api.openai.com/compliance/cookie_requirements" "$WORK/gpt1.json")
    out=$(fetch_url "$f" "https://chatgpt.com/" "$WORK/gpt2.html")
    code2="${out%% *}"; final="${out#* }"
    local blocked=0
    grep -qi "unsupported_country" "$WORK/gpt1.json" 2>/dev/null && blocked=1
    grep -qi "not available in your country\|blocked" "$WORK/gpt2.html" 2>/dev/null && blocked=1
    local res
    if [ "$code1" = "000" ] && [ "$code2" = "000" ]; then
        res="連線失敗"
    elif [ "$blocked" -eq 1 ]; then
        res="被封鎖"
    elif [ "$code2" = "200" ]; then
        res="可用"
    else
        res="不確定 (HTTP $code2)"
    fi
    echo "[$tag] ChatGPT: $res"
    echo "      測試: api.openai.com/compliance/cookie_requirements HTTP $code1 | chatgpt.com HTTP $code2"
}

# ---------- 5. Claude ----------
# 方法：抓 https://claude.ai/，看最後停在哪個網址。
# 停在 claude.ai = 可用；被轉到 app-unavailable-in-region = 地區不支援。
check_claude() {
    local f="$1" tag="$2"
    local out code final
    out=$(fetch_url "$f" "https://claude.ai/" "$WORK/claude.html")
    code="${out%% *}"; final="${out#* }"
    local res
    if [ "$code" = "000" ]; then
        res="連線失敗"
    elif [[ "$final" == *"app-unavailable-in-region"* ]]; then
        res="被封鎖 (地區不支援)"
    elif [[ "$final" == "https://claude.ai"* ]]; then
        res="可用"
    else
        res="不確定 (最終網址: $final)"
    fi
    echo "[$tag] Claude: $res"
    echo "      測試: https://claude.ai/ HTTP $code 最終網址: $final"
}

# ---------- 6. Gemini（重點修正） ----------
# 原版錯在：抓 gemini.google.com 的原始碼，去找一串寫死的數字
# '45631641,null,true'（Google 前端 JS 裡的內部編號），
# Google 一改版數字就變，數字一變就報 No，明明服務正常。
# 這個版本只判斷：首頁回 HTTP 200 且頁面有 Gemini 字樣、
# 且沒有地區封鎖提示 = 可用。不猜任何內部編號。
check_gemini() {
    local f="$1" tag="$2"
    local url="https://gemini.google.com/"
    local code
    code=$(fetch "$f" "$url" "$WORK/gem.html")
    local res
    if [ "$code" = "000" ]; then
        res="連線失敗"
    elif grep -qi "not available in your country\|isn't available in your country\|unavailable in your region" "$WORK/gem.html" 2>/dev/null; then
        res="被封鎖 (地區不支援)"
    elif [ "$code" = "200" ] && grep -qi "Gemini" "$WORK/gem.html" 2>/dev/null; then
        res="可用"
    elif [ "$code" = "200" ]; then
        res="可用 (首頁 HTTP 200)"
    else
        res="不確定 (HTTP $code)"
    fi
    echo "[$tag] Gemini: $res"
    echo "      測試: $url HTTP $code"
}

# ---------- 7. HBO Max ----------
# 方法：抓 https://www.max.com/，找頁面裡的 countryCode=XX。
check_hbomax() {
    local f="$1" tag="$2"
    local url="https://www.max.com/"
    local code region
    code=$(fetch "$f" "$url" "$WORK/hbo.html")
    region=$(grep -o 'countryCode=[A-Z][A-Z]' "$WORK/hbo.html" 2>/dev/null | head -1 | cut -d= -f2)
    local res
    if [ "$code" = "000" ]; then
        res="連線失敗"
    elif [ -n "$region" ]; then
        res="可用 (地區: $region)"
    elif [ "$code" = "200" ]; then
        res="首頁可打開 (地區未知)"
    else
        res="不確定 (HTTP $code)"
    fi
    echo "[$tag] HBO Max: $res"
    echo "      測試: $url HTTP $code"
}

# ---------- 8. Paramount+ ----------
# 方法：抓首頁，看最後跳轉到的網址裡的地區段；跳到 /intl = 不支援。
check_paramount() {
    local f="$1" tag="$2"
    local url="https://www.paramountplus.com/"
    local out code final region
    out=$(fetch_url "$f" "$url" "$WORK/pp.html")
    code="${out%% *}"; final="${out#* }"
    region=$(echo "$final" | cut -d/ -f4 | tr 'a-z' 'A-Z')
    local res
    if [ "$code" = "000" ]; then
        res="連線失敗"
    elif [ "$region" = "INTL" ]; then
        res="不支援 (跳到國際版)"
    elif [ "$code" = "200" ]; then
        [ -z "$region" ] && region="US"
        res="可用 (地區: $region)"
    else
        res="不確定 (HTTP $code)"
    fi
    echo "[$tag] Paramount+: $res"
    echo "      測試: $url HTTP $code 最終網址: $final"
}

# ---------- 執行 ----------
for stack in $STACKS; do
    if [ "$stack" = "4" ]; then
        echo "========== IPv4 檢測 =========="
        FLAG="-4"; TAG="IPv4"
    else
        echo "========== IPv6 檢測 =========="
        FLAG="-6"; TAG="IPv6"
    fi
    check_netflix   "$FLAG" "$TAG"
    check_disney    "$FLAG" "$TAG"
    check_ytpremium "$FLAG" "$TAG"
    check_chatgpt   "$FLAG" "$TAG"
    check_claude    "$FLAG" "$TAG"
    check_gemini    "$FLAG" "$TAG"
    check_hbomax    "$FLAG" "$TAG"
    check_paramount "$FLAG" "$TAG"
    echo ""
done

echo "========== 檢測完成 =========="
echo "說明：每項都印了測試網址和 HTTP 狀態碼，"
echo "懷疑哪項不準，可以直接用瀏覽器或 curl 開那個網址對照。"
