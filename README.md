# HAUS Type

macOS 選單列的語音輸入工具。按一下快捷鍵講話，再按一下，整理好的文字就會打進游標所在的輸入框。LINE、Slack、Mail、瀏覽器、Claude、ChatGPT、備忘錄都能用。

<img src="icon/icon-1024.png" width="96" alt="HAUS Type 圖示">

## 會幫你做什麼

三種模式，各自可以綁快捷鍵：

| 模式 | 預設快捷鍵 | 做什麼 |
|---|---|---|
| 口述 | Fn | 講的話整理好，打進游標所在的輸入框 |
| 翻譯 | Fn＋Shift | 講中文，打出英文、日文等目標語言（最多設 3 種，選單列切換） |
| 隨便問 | Fn＋Space | 選取一段字後講「改短一點」就直接改寫，講「這段在說什麼」就在答案視窗回答；沒選取時講「幫我寫一則訊息…」直接打出來 |

- 轉寫：雲端用 OpenAI 的 gpt-transcribe；也可以改用本機的 Breeze-ASR-25，錄音不離開你的 Mac。
- 整理：交給 Claude Haiku 5.5，去掉「嗯、那個、然後然後」，講到一半改口只留後面的版本，講「第一、第二」自動排成條列，中文一律用台灣正體字與台灣用語。
- 依 app 調語氣：聊天口語、Email 正式、給 AI 的指令精準、筆記精簡。
- 改寫選取的字：選起一段字再講「改正式一點」「縮短」「翻成英文」，選取的字會直接換掉。
- 專有名詞：人名、品牌、術語加進詞彙表，聽錯也會改回正確寫法。括號可以寫常被聽成的樣子，例如「GitHub（get hub）」。
- 預先轉寫：講完停頓的時候就先送出，按下結束後通常 1 秒內貼上。
- 自動學詞：貼上後 30 秒內你改掉的專有名詞，自動加進詞彙表。
- 總覽：口述字數、省下的時間、每分鐘字數、連續天數與使用熱度圖。
- 歷史：口述、翻譯、提問分頁，可重試、另存錄音，保存期限自己設。
- 其他：選麥克風、錄音時把其他聲音靜音、顯示在 Dock、排版與標點開關、寫作風格樣本。

講完到貼上大約 2 到 3 秒。

## 安裝

1. 到 [Releases](https://github.com/hausco/haus-type/releases/latest) 下載 `HAUS-Type-版本.dmg`。
2. 打開 DMG，把 HAUS Type 拖進「應用程式」。
3. 打開 HAUS Type，照設定引導完成四步：
   - 允許麥克風。
   - 在「輔助使用」打開 HAUS Type（偵測快捷鍵與貼上文字用）。
   - 要用 Fn 鍵的話，到「系統設定 → 鍵盤」把「按下 🌐 鍵時」改成「不做任何事」。
   - 貼上 OpenRouter 金鑰。

需要 macOS 14 以上，Apple Silicon 與 Intel 都能用。

## OpenRouter 金鑰與費用

HAUS Type 透過 [OpenRouter](https://openrouter.ai) 呼叫 AI 模型，費用由你自己的 OpenRouter 帳戶支付，HAUS Type 不另外收費。

1. 到 [openrouter.ai/settings/keys](https://openrouter.ai/settings/keys) 註冊並建立金鑰（`sk-or-` 開頭）。
2. 在 OpenRouter 儲值，幾美元可以用很久：一天講 1 小時，轉寫加整理一個月約 3 到 8 美元。
3. 把金鑰貼進 HAUS Type 的設定引導或「設定 → 金鑰與模型」。HAUS Type 會先實際測一次，通過才存進 macOS 鑰匙圈。

## 使用方式

- 按一下 Fn 開始，講完再按一下結束。按住超過 1 秒再放開也會結束。
- 錄音時螢幕下方會出現聲波。點 ✕ 或按 Esc 取消；取消後 4 秒內可以按「復原」照樣送出。
- 也可以在「設定 → 一般」改用滑鼠中鍵或自訂組合鍵。
- 選單列圖示的選單有「貼上上一段」「貼上上一段原文（未整理）」「歷史紀錄」。

## 隱私

兩種辨識模式的資料流向：

| 資料 | 雲端模式（預設） | 本機模式 |
|---|---|---|
| 錄音 | 送到 OpenRouter，再轉給 OpenAI 轉寫 | 只在這台 Mac 上由 Breeze-ASR-25 轉寫，不送出 |
| 轉寫文字、游標附近的文字（前 400 字、後 200 字、選取的字）、app 名稱與視窗標題、詞彙表 | 送到 OpenRouter，再轉給 Anthropic 整理 | 同左（整理、翻譯、隨便問仍走雲端） |

- 密碼欄位不讀取；「設定 → 一般 → 隱私」清單裡的 app（預設是密碼管理類）只送 app 名稱。
- 自動學詞時，被改掉的那個詞與整句會送去判斷是不是專有名詞。
- 歷史紀錄、詞彙表、設定只存在你的 Mac：`~/.haustype/`。
- 金鑰存在 macOS 鑰匙圈，不寫進任何檔案。

## 本機辨識（選用）

需要 Apple Silicon、Python 3.12 與約 3 GB 空間：

```bash
python3 -m venv ~/.haustype/local/venv
~/.haustype/local/venv/bin/pip install mlx-whisper
# 把 Breeze-ASR-25 轉成 mlx_whisper 格式，放到 ~/.haustype/local/breeze-mlx-fp16（含 config.json 與 weights.safetensors）
```

到「設定 → 金鑰與模型 → 辨識引擎」選「本機」。模型只在 HAUS Type 開啟時載入一次（約 0.3 秒），之後每段約 0.7 秒出字。找不到模型或本機辨識失敗時，這段會自動改用雲端並提示。

## 實驗功能：與 Typeless 同步詞庫

有裝 Typeless 的話，可以在「設定 → 實驗功能」打開。HAUS Type 會讀 Typeless 在本機的字典快取，把詞併進詞彙表；HAUS Type 有、Typeless 沒有的詞會寫成 CSV，在 Typeless「字典」頁按「匯入 CSV」就能加進去。不需要 Typeless 的帳號密碼，但 Typeless 改版時可能失效。

## 從原始碼編譯

只需要 Xcode Command Line Tools，不需要 Xcode 專案。

```bash
./build.sh            # 編譯、簽章、安裝到 /Applications 並開啟
./release.sh          # 發佈：Developer ID 簽章、公證、做成 DMG（需要 Apple Developer 帳號）
```

進階設定可以直接改 `~/.haustype/` 裡的檔案：`config.json`（設定）、`vocabulary.txt`（詞彙表）、`prompt.md`（整理規則），改完不用重開。

## 授權

MIT。整理規則改寫自 [jarvis-voice](https://github.com/urusaqqrun/jarvis-voice)（MIT）。
