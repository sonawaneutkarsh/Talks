# Talks

> Distraction-free, zero-cloud meeting capture for Apple Watch and iPhone with on-device intelligence and direct Notion synchronization.

---

## 1. Product Overview

**Talks** is an open-source, private-by-design meeting recording and synthesis system designed specifically for professors, researchers, and engineers. It captures meetings directly from your Apple Watch, safely transfers the audio to your iPhone over background channels, transcribes and structures the meeting using Apple's on-device foundation models, and creates an organized, beautifully formatted summary in your Notion workspace.

- **Zero Cloud Processing**: Audio and transcripts never touch any third-party AI or transcription servers. Everything executes 100% locally on your iPhone using Apple Silicon hardware acceleration.
- **$0 / Month Recurring Cost**: No API keys for speech-to-text or large language models. Direct integration with the free Notion API.
- **Distraction-Free**: Includes an academic "Screen Off" mode that blanks the watch face during research meetings while maintaining continuous recording.

---

## 2. System Architecture

```
┌─────────────────┐
│   Apple Watch   │
│  (TalksWatch)   │
└────────┬────────┘
         │
         │ 1. Record audio (AVAudioSession + WKExtendedRuntimeSession)
         │ 2. Distraction-free Screen Off capture
         │ 3. On Stop: Durable background file transfer (WCSession.transferFile)
         ▼
┌─────────────────┐
│     iPhone      │
│     (Talks)     │
└────────┬────────┘
         │
         │ 4. Receive audio & save atomically to disk
         │ 5. Send durable background ACK (WCSession.transferUserInfo)
         │ 6. Enqueue durable job in JobQueueManager
         │
         ├───▶ [7. On-Device Speech Transcription]
         │     • SpeechAnalyzer (iOS 18+) with streaming watchdog
         │     • Automatic SFSpeechRecognizer on-device fallback
         │
         ├───▶ [8. Apple Intelligence Structuring]
         │     • Foundation Models (System LLM)
         │     • Generates Title, Summary, Key Points, Decisions, Action Items
         │
         └───▶ [9. Direct Notion Upload]
               • Creates page under configured 'Talks' parent
               • Syncs structured blocks + collapsible raw transcript
               • Zero duplicate page protection
```

---

## 3. Key Features

- **One-Tap Apple Watch Recording**: Large, high-contrast record button with haptic feedback.
- **Screen Off Distraction-Free Mode**: Tap "Screen Off" during meetings to blank the watch display (`Color.black`) with a subtle, non-intrusive corner indicator. Safe wake-on-tap returns to controls without interrupting the recording.
- **Durable Background Transfer**: Transfers audio out-of-process via `WCSession.transferFile`. Audio on the Watch is only deleted after the iPhone sends a verified acknowledgement.
- **100% On-Device Speech Transcription**: Leverages Apple's Speech framework (`SpeechAnalyzer` with on-device asset models, backed by `SFSpeechRecognizer` fallback with cancellation-resistant watchdog isolation).
- **Apple Intelligence Structuring**: Extracts meeting titles, summaries, key takeaways, agreed decisions, and action items directly on device.
- **Direct Notion Sync**: Formats notes with native Notion callout, heading, bullet, and todo blocks. Retains full raw transcripts in an expandable toggle block.
- **Safe Local Swipe Deletion**: Swipe left on any completed or failed Talk to delete the local recording and metadata from iPhone. Active processing jobs are strictly protected, and external Notion pages are never deleted.
- **Resilient Offline Queue**: Jobs persist across app force-quits, reboots, and transient network interruptions. Failed uploads can be retried with one tap.

---

## Requirements

- **iPhone**: iOS 18.0 or later (minimum OS required to launch Talks, ingest transfers, transcribe locally via SFSpeechRecognizer, and sync with Notion).
- **Apple Watch**: watchOS 11.0 or later (Apple Watch Series 8, Ultra, or newer).
- **Xcode**: Xcode 26.0 or later (Xcode 27.0 with Swift 6 and iOS 26+ SDK required to compile FoundationModels).
- **Apple Intelligence**: Requires an Apple Intelligence-compatible device (iPhone 15 Pro, iPhone 16 series, or newer) running iOS 26.0 or later with Apple Intelligence enabled in Settings; devices running iOS 18–25 or without Apple Intelligence capture audio and transcribe on-device via SFSpeechRecognizer.
- **Notion Integration**: Free Notion Internal Integration Token and parent page ID with integration connection access.

---

## 5. Setup & Installation

### Step 1: Clone the Repository
```bash
git clone https://github.com/your-username/talks.git
cd talks
```

### Step 2: Configure Notion Integration
1. Go to [Notion Developers](https://www.notion.so/my-integrations) and create a **New integration**.
2. Give it a name (e.g. `Talks Assistant`) and copy the **Internal Integration Secret** (`secret_...`).
3. Open Notion in your browser, create or navigate to a page where you want meeting notes stored (e.g., `Research Notes` or `Meetings`).
4. Click the `...` menu in the upper-right corner of the parent page, select **Connections**, and connect your integration.
5. Copy the parent page link or page ID (the 32-character hexadecimal string in the page URL).

### Step 3: Build & Deploy via Xcode
1. Open `Talks.xcodeproj` in Xcode.
2. Select the `Talks` scheme and choose your physical iPhone as the run destination.
3. Configure your Apple Developer signing certificate under **Signing & Capabilities** for both `Talks` and `TalksWatch`.
4. Press **Cmd + R** to install and run Talks on your iPhone.
5. In the iPhone Talks app, open **Settings (gear icon)**:
   - Paste your Notion Integration Token into **Notion Integration Token**.
   - Paste your Parent Page URL or ID into **Parent Notion Page**.
   - Tap **Save Credentials to Keychain**.
   - Tap **Test Connection & Sync 'Talks' Page** to verify setup.
6. Switch schemes to `TalksWatch`, select your physical Apple Watch, and build & run.

---

## 6. Physical Device Troubleshooting Guide

### WatchConnectivity Pairing & File Delivery
- **Watch App Installed check**: Ensure `TalksWatch.app` is embedded inside `Talks.app` (configured automatically in `project.yml`).
- **Transfer Timing**: `WCSession.transferFile` runs out-of-process via Apple's `wcd` daemon. Audio transfers in the background within 10–30 seconds after tapping Stop, depending on Bluetooth/Wi-Fi signal.
- **Durable Local Retention**: Recordings remain stored locally in `Documents/WatchRecordings/` on Apple Watch until the phone sends a verified ACK (`transferUserInfo`). If you walk out of range before transfer finishes, the transfer resumes automatically once back in range.

### Speech Model Assets
- Speech recognition models download once over Wi-Fi when first required by iOS. Check **Settings → Processing** to confirm transcription readiness.
- A built-in watchdog prevents speech analyzer hangs: if processing exceeds timeout boundaries, Talks automatically falls back to secondary on-device recognition engines without losing meeting audio.

### Notion Connection
- If connection fails, confirm your Notion integration is added to the parent page via **Page Menu (...) → Add connections**.
- Notion tokens are stored securely in the iOS Keychain and are never logged or exported.

---

## 7. Architecture & Design Decisions

### Why 100% On-Device?
- **Academic & Research Confidentiality**: Meeting discussions with collaborators, students, and industry partners often involve unpublished data, intellectual property, or confidential disclosures. Zero third-party cloud audio processing guarantees absolute privacy.
- **Zero API Bills**: Cloud LLM and STT APIs charge per minute and per token. By running transcription and formatting on device, Talks is completely free forever.

### Why Background Transfers vs. Live Streaming?
- Live streaming audio over Bluetooth during a 90-minute lecture drains watch battery and is prone to packet loss if you step away from your phone.
- Recording locally to high-efficiency AAC (`.m4a`) and performing atomic file transfers over `wcd` guarantees zero dropped frames and rock-solid battery efficiency.

### Crash & Force-Quit Resilience
- State transitions are recorded in a persistent, atomic JSON job queue (`Documents/job_queue.json`).
- If iOS terminates the app in the background, the queue resumes uncompleted jobs upon the next launch or background processing trigger.
- Duplicate prevention hashes each recording ID and checks Notion for existing pages before creating new entries.

---

## 8. Privacy & Recording Consent

- **Local Processing**: Audio recordings and transcripts remain entirely on your personal devices and are never transmitted to third-party AI or speech servers. The only external network communication is direct synchronization to your private Notion workspace via your configured integration credentials.
- **Recording Consent**: Please ensure you comply with all applicable local, state, and institutional recording consent laws and regulations before recording lectures, advising sessions, or meetings with collaborators.

---

## 9. License

MIT License. See [LICENSE](LICENSE) for details.

